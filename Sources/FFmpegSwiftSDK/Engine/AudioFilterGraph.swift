// AudioFilterGraph.swift
// FFmpegSwiftSDK
//
// 封装 FFmpeg avfilter 图，提供 loudnorm（响度标准化）、atempo（变速不变调）、
// volume（音量控制）三种实时音频滤镜。
//
// 滤镜链: abuffer → volume → atempo → loudnorm → aformat → abuffersink

import Foundation
import CFFmpeg

/// FFmpeg avfilter 音频滤镜图，支持实时参数调整。
///
/// 内部维护一个 AVFilterGraph，按需重建滤镜链。
/// 线程安全：所有参数修改和处理都通过 NSLock 保护。
final class AudioFilterGraph {

    // MARK: - 属性

    private let lock = NSLock()

    /// 当前滤镜参数
    private(set) var volumeDB: Float = 0.0        // 0 = 不变
    private(set) var tempo: Float = 1.0            // 1.0 = 原速
    private(set) var loudnormEnabled: Bool = false  // 响度标准化

    /// loudnorm 参数
    private(set) var loudnormTarget: Float = -14.0  // LUFS
    private(set) var loudnormLRA: Float = 11.0      // LRA
    private(set) var loudnormTP: Float = -1.0       // True Peak

    /// 低音增益（dB），通过 FFmpeg bass 滤镜实现
    private(set) var bassGain: Float = 0.0
    /// 高音增益（dB），通过 FFmpeg treble 滤镜实现
    private(set) var trebleGain: Float = 0.0
    /// 环绕强度（0~1），通过 FFmpeg extrastereo 滤镜实现
    private(set) var surroundLevel: Float = 0.0
    /// 混响强度（0~1），通过 FFmpeg aecho 滤镜实现
    private(set) var reverbLevel: Float = 0.0

    /// 当前音频格式
    private var sampleRate: Int = 0
    private var channelCount: Int = 0

    /// FFmpeg 滤镜图组件
    private var filterGraph: UnsafeMutablePointer<AVFilterGraph>?
    private var bufferSrcCtx: UnsafeMutablePointer<AVFilterContext>?
    private var bufferSinkCtx: UnsafeMutablePointer<AVFilterContext>?

    /// 滤镜图是否需要重建
    private var needsRebuild: Bool = true

    /// 是否有任何滤镜处于激活状态
    var isActive: Bool {
        lock.lock()
        let active = volumeDB != 0.0 || tempo != 1.0 || loudnormEnabled || bassGain != 0.0 || trebleGain != 0.0 || surroundLevel > 0.0 || reverbLevel > 0.0
        lock.unlock()
        return active
    }

    // MARK: - 初始化

    init() {}

    deinit {
        destroyGraph()
    }

    // MARK: - 参数设置

    /// 设置音量增益（dB）。0 = 不变，正值增大，负值减小。
    func setVolume(_ db: Float) {
        lock.lock()
        if volumeDB != db {
            volumeDB = db
            needsRebuild = true
        }
        lock.unlock()
    }

    /// 设置播放速度倍率。范围 [0.5, 4.0]，1.0 = 原速。
    /// atempo 滤镜限制单级 [0.5, 2.0]，超出范围会级联多个 atempo。
    func setTempo(_ rate: Float) {
        let clamped = min(max(rate, 0.5), 4.0)
        lock.lock()
        if tempo != clamped {
            tempo = clamped
            needsRebuild = true
        }
        lock.unlock()
    }

    /// 启用/禁用响度标准化（EBU R128 / loudnorm）。
    func setLoudnormEnabled(_ enabled: Bool) {
        lock.lock()
        if loudnormEnabled != enabled {
            loudnormEnabled = enabled
            needsRebuild = true
        }
        lock.unlock()
    }

    /// 设置 loudnorm 参数。
    func setLoudnormParams(targetLUFS: Float = -14.0, lra: Float = 11.0, truePeak: Float = -1.0) {
        lock.lock()
        loudnormTarget = targetLUFS
        loudnormLRA = lra
        loudnormTP = truePeak
        if loudnormEnabled { needsRebuild = true }
        lock.unlock()
    }

    /// 设置低音增益（dB）。通过 FFmpeg bass 滤镜实现。
    /// - Parameter db: 增益值，范围 [-12, +12]。0 = 不变。
    func setBassGain(_ db: Float) {
        let clamped = min(max(db, -12), 12)
        lock.lock()
        if bassGain != clamped {
            bassGain = clamped
            needsRebuild = true
        }
        lock.unlock()
    }

    /// 设置高音增益（dB）。通过 FFmpeg treble 滤镜实现。
    /// - Parameter db: 增益值，范围 [-12, +12]。0 = 不变。
    func setTrebleGain(_ db: Float) {
        let clamped = min(max(db, -12), 12)
        lock.lock()
        if trebleGain != clamped {
            trebleGain = clamped
            needsRebuild = true
        }
        lock.unlock()
    }

    /// 设置环绕强度。通过 FFmpeg extrastereo 滤镜实现。
    /// - Parameter level: 强度 0~1。0 = 关闭，1 = 最大环绕。
    ///   内部映射到 extrastereo 的 m 参数（1.0~4.0）。
    func setSurroundLevel(_ level: Float) {
        let clamped = min(max(level, 0), 1)
        lock.lock()
        if surroundLevel != clamped {
            surroundLevel = clamped
            needsRebuild = true
        }
        lock.unlock()
    }

    /// 设置混响强度。通过 FFmpeg aecho 滤镜实现。
    /// - Parameter level: 强度 0~1。0 = 关闭，1 = 最大混响。
    ///   内部映射 aecho 的 decay 参数（0.1~0.6）。
    func setReverbLevel(_ level: Float) {
        let clamped = min(max(level, 0), 1)
        lock.lock()
        if reverbLevel != clamped {
            reverbLevel = clamped
            needsRebuild = true
        }
        lock.unlock()
    }

    /// 重置所有滤镜到默认值。
    func reset() {
        lock.lock()
        volumeDB = 0.0
        tempo = 1.0
        loudnormEnabled = false
        loudnormTarget = -14.0
        loudnormLRA = 11.0
        loudnormTP = -1.0
        bassGain = 0.0
        trebleGain = 0.0
        surroundLevel = 0.0
        reverbLevel = 0.0
        needsRebuild = true
        lock.unlock()
        destroyGraph()
    }

    // MARK: - 处理

    /// 处理一个音频 buffer，返回滤镜处理后的结果。
    /// 如果没有激活的滤镜，直接返回原 buffer（零拷贝）。
    func process(_ buffer: AudioBuffer) -> AudioBuffer {
        lock.lock()
        let active = volumeDB != 0.0 || tempo != 1.0 || loudnormEnabled || bassGain != 0.0 || trebleGain != 0.0 || surroundLevel > 0.0 || reverbLevel > 0.0
        lock.unlock()

        guard active else { return buffer }

        lock.lock()

        // 格式变化或参数变化时重建滤镜图
        if needsRebuild || sampleRate != buffer.sampleRate || channelCount != buffer.channelCount {
            sampleRate = buffer.sampleRate
            channelCount = buffer.channelCount
            rebuildGraph()
            needsRebuild = false
        }

        guard filterGraph != nil, let srcCtx = bufferSrcCtx, let sinkCtx = bufferSinkCtx else {
            lock.unlock()
            return buffer
        }

        // 创建输入 AVFrame
        guard let frame = av_frame_alloc() else {
            lock.unlock()
            return buffer
        }

        frame.pointee.format = AV_SAMPLE_FMT_FLT.rawValue
        frame.pointee.sample_rate = Int32(buffer.sampleRate)
        frame.pointee.nb_samples = Int32(buffer.frameCount)
        av_channel_layout_default(&frame.pointee.ch_layout, Int32(buffer.channelCount))

        // 分配 frame 数据缓冲区
        let ret = av_frame_get_buffer(frame, 0)
        guard ret >= 0 else {
            var fp: UnsafeMutablePointer<AVFrame>? = frame
            av_frame_free(&fp)
            lock.unlock()
            return buffer
        }

        // 拷贝 interleaved Float32 数据到 frame
        let totalBytes = buffer.frameCount * buffer.channelCount * MemoryLayout<Float>.size
        if let dst = frame.pointee.data.0 {
            memcpy(dst, buffer.data, totalBytes)
        }

        // 送入滤镜图
        let addRet = av_buffersrc_add_frame(srcCtx, frame)
        var fp: UnsafeMutablePointer<AVFrame>? = frame
        av_frame_free(&fp)

        guard addRet >= 0 else {
            lock.unlock()
            return buffer
        }

        // 从 sink 取出处理后的数据
        guard let outFrame = av_frame_alloc() else {
            lock.unlock()
            return buffer
        }

        let getResult = av_buffersink_get_frame(sinkCtx, outFrame)
        lock.unlock()

        guard getResult >= 0 else {
            var ofp: UnsafeMutablePointer<AVFrame>? = outFrame
            av_frame_free(&ofp)
            return buffer
        }

        // 转换输出 frame 为 AudioBuffer
        let outFrameCount = Int(outFrame.pointee.nb_samples)
        let outChannels = Int(outFrame.pointee.ch_layout.nb_channels)
        let outSamples = outFrameCount * outChannels
        let outData = UnsafeMutablePointer<Float>.allocate(capacity: outSamples)

        if let src = outFrame.pointee.data.0 {
            memcpy(outData, src, outSamples * MemoryLayout<Float>.size)
        }

        let outRate = Int(outFrame.pointee.sample_rate)
        var ofp2: UnsafeMutablePointer<AVFrame>? = outFrame
        av_frame_free(&ofp2)

        return AudioBuffer(
            data: outData,
            frameCount: outFrameCount,
            channelCount: outChannels,
            sampleRate: outRate
        )
    }

    // MARK: - 滤镜图构建

    /// 重建 FFmpeg avfilter 图。在 lock 内调用。
    private func rebuildGraph() {
        destroyGraphUnsafe()

        filterGraph = avfilter_graph_alloc()
        guard let graph = filterGraph else { return }

        // abuffer（输入源）
        guard let abuffer = avfilter_get_by_name("abuffer") else { return }
        let srcArgs = "sample_rate=\(sampleRate):sample_fmt=flt:channel_layout=\(channelCount == 1 ? "mono" : "stereo")"
        var srcCtx: UnsafeMutablePointer<AVFilterContext>?
        guard avfilter_graph_create_filter(&srcCtx, abuffer, "src", srcArgs, nil, graph) >= 0,
              let src = srcCtx else {
            destroyGraphUnsafe()
            return
        }
        bufferSrcCtx = src

        // abuffersink（输出）
        guard let abuffersink = avfilter_get_by_name("abuffersink") else {
            destroyGraphUnsafe()
            return
        }
        var sinkCtx: UnsafeMutablePointer<AVFilterContext>?
        guard avfilter_graph_create_filter(&sinkCtx, abuffersink, "sink", nil, nil, graph) >= 0,
              let sink = sinkCtx else {
            destroyGraphUnsafe()
            return
        }
        bufferSinkCtx = sink

        // 设置 sink 输出格式为 Float32 interleaved
        var sampleFmts: [Int32] = [AV_SAMPLE_FMT_FLT.rawValue, -1]
        av_opt_set_int_list_flt(sink, "sample_fmts", &sampleFmts)

        var sampleRates: [Int32] = [Int32(sampleRate), -1]
        av_opt_set_int_list_int(sink, "sample_rates", &sampleRates)

        // 构建滤镜链：src → [volume] → [atempo...] → [loudnorm] → aformat → sink
        var lastCtx = src

        // volume 滤镜
        if volumeDB != 0.0 {
            if let ctx = createFilter(graph: graph, name: "volume", label: "vol",
                                       args: "volume=\(String(format: "%.1f", volumeDB))dB") {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // bass 滤镜（低音增强/衰减，中心频率 100Hz）
        if bassGain != 0.0 {
            if let ctx = createFilter(graph: graph, name: "bass", label: "bass",
                                       args: "gain=\(String(format: "%.1f", bassGain)):frequency=100:width_type=o:width=0.5") {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // treble 滤镜（高音增强/衰减，中心频率 3000Hz）
        if trebleGain != 0.0 {
            if let ctx = createFilter(graph: graph, name: "treble", label: "treble",
                                       args: "gain=\(String(format: "%.1f", trebleGain)):frequency=3000:width_type=o:width=0.5") {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // extrastereo 滤镜（环绕/立体声增强）
        // m=1.0 为原始，m>1 增强立体声分离度，最大 4.0
        if surroundLevel > 0.0 {
            let m = 1.0 + surroundLevel * 3.0 // 映射 0~1 → 1.0~4.0
            if let ctx = createFilter(graph: graph, name: "extrastereo", label: "surround",
                                       args: "m=\(String(format: "%.2f", m))") {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // aecho 滤镜（混响效果）
        // 使用多次短延迟模拟房间混响
        // in_gain=0.8, out_gain=0.9, delays=60|120, decays=动态
        if reverbLevel > 0.0 {
            let decay = 0.1 + reverbLevel * 0.5 // 映射 0~1 → 0.1~0.6
            let args = "in_gain=0.8:out_gain=0.9:delays=60|120:decays=\(String(format: "%.2f", decay))|\(String(format: "%.2f", decay * 0.7))"
            if let ctx = createFilter(graph: graph, name: "aecho", label: "reverb", args: args) {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // atempo 滤镜（级联支持 > 2.0x）
        if tempo != 1.0 {
            var remaining = tempo
            var atempoIndex = 0
            while remaining != 1.0 {
                let factor: Float
                if remaining > 2.0 {
                    factor = 2.0
                    remaining /= 2.0
                } else if remaining < 0.5 {
                    factor = 0.5
                    remaining /= 0.5
                } else {
                    factor = remaining
                    remaining = 1.0
                }
                if let ctx = createFilter(graph: graph, name: "atempo", label: "atempo\(atempoIndex)",
                                           args: "tempo=\(String(format: "%.4f", factor))") {
                    guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                    lastCtx = ctx
                    atempoIndex += 1
                }
            }
        }

        // loudnorm 滤镜
        if loudnormEnabled {
            let args = "I=\(String(format: "%.1f", loudnormTarget)):LRA=\(String(format: "%.1f", loudnormLRA)):TP=\(String(format: "%.1f", loudnormTP))"
            if let ctx = createFilter(graph: graph, name: "loudnorm", label: "loudnorm", args: args) {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // aformat（确保输出格式）
        let aformatArgs = "sample_fmts=flt:sample_rates=\(sampleRate):channel_layouts=\(channelCount == 1 ? "mono" : "stereo")"
        if let ctx = createFilter(graph: graph, name: "aformat", label: "aformat", args: aformatArgs) {
            guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
            lastCtx = ctx
        }

        // 连接到 sink
        guard avfilter_link(lastCtx, 0, sink, 0) >= 0 else {
            destroyGraphUnsafe()
            return
        }

        // 配置图
        guard avfilter_graph_config(graph, nil) >= 0 else {
            destroyGraphUnsafe()
            return
        }
    }

    /// 创建单个滤镜节点
    private func createFilter(graph: UnsafeMutablePointer<AVFilterGraph>, name: String, label: String, args: String) -> UnsafeMutablePointer<AVFilterContext>? {
        guard let filter = avfilter_get_by_name(name) else { return nil }
        var ctx: UnsafeMutablePointer<AVFilterContext>?
        guard avfilter_graph_create_filter(&ctx, filter, label, args, nil, graph) >= 0 else { return nil }
        return ctx
    }

    /// 销毁滤镜图（线程安全）
    private func destroyGraph() {
        lock.lock()
        destroyGraphUnsafe()
        lock.unlock()
    }

    /// 销毁滤镜图（在 lock 内调用）
    private func destroyGraphUnsafe() {
        if filterGraph != nil {
            avfilter_graph_free(&filterGraph)
        }
        filterGraph = nil
        bufferSrcCtx = nil
        bufferSinkCtx = nil
    }
}

// MARK: - av_opt_set_int_list 辅助（Swift 无法直接调用 C 宏）

private func av_opt_set_int_list_flt(_ obj: UnsafeMutablePointer<AVFilterContext>, _ name: String, _ list: UnsafeMutablePointer<Int32>) {
    var count = 0
    while list[count] != -1 { count += 1 }
    count += 1 // 包含终止符
    av_opt_set_bin(obj, name, UnsafeRawPointer(list).assumingMemoryBound(to: UInt8.self),
                   Int32(count * MemoryLayout<Int32>.size), AV_OPT_SEARCH_CHILDREN)
}

private func av_opt_set_int_list_int(_ obj: UnsafeMutablePointer<AVFilterContext>, _ name: String, _ list: UnsafeMutablePointer<Int32>) {
    var count = 0
    while list[count] != -1 { count += 1 }
    count += 1
    av_opt_set_bin(obj, name, UnsafeRawPointer(list).assumingMemoryBound(to: UInt8.self),
                   Int32(count * MemoryLayout<Int32>.size), AV_OPT_SEARCH_CHILDREN)
}
