// AudioFilterGraph.swift
// FFmpegSwiftSDK
//
// 封装 FFmpeg avfilter 图，提供音频滤镜处理。
// 优化：减少滤镜图重建频率，使用 pts 时间戳保证连续性。

import Foundation
import CFFmpeg

/// FFmpeg avfilter 音频滤镜图，支持实时参数调整。
final class AudioFilterGraph {

    // MARK: - 属性

    private let lock = NSLock()

    /// 当前滤镜参数
    private(set) var volumeDB: Float = 0.0
    private(set) var tempo: Float = 1.0
    private(set) var loudnormEnabled: Bool = false

    /// loudnorm 参数
    private(set) var loudnormTarget: Float = -14.0
    private(set) var loudnormLRA: Float = 11.0
    private(set) var loudnormTP: Float = -1.0

    /// 低音增益（dB）
    private(set) var bassGain: Float = 0.0
    /// 高音增益（dB）
    private(set) var trebleGain: Float = 0.0
    /// 环绕强度（0~1）
    private(set) var surroundLevel: Float = 0.0
    /// 混响强度（0~1）
    private(set) var reverbLevel: Float = 0.0
    /// 变调（半音数）
    private(set) var pitchSemitones: Float = 0.0

    /// 淡入淡出
    private(set) var fadeInDuration: Float = 0.0
    private(set) var fadeOutDuration: Float = 0.0
    private(set) var fadeOutStartTime: Float = 0.0
    private var processedSamples: Int64 = 0

    /// 当前音频格式
    private var sampleRate: Int = 0
    private var channelCount: Int = 0

    /// FFmpeg 滤镜图组件
    private var filterGraph: UnsafeMutablePointer<AVFilterGraph>?
    private var bufferSrcCtx: UnsafeMutablePointer<AVFilterContext>?
    private var bufferSinkCtx: UnsafeMutablePointer<AVFilterContext>?

    /// 滤镜图是否需要重建
    private var needsRebuild: Bool = true
    
    /// 当前 pts 计数器（保证音频连续性）
    private var currentPts: Int64 = 0
    
    /// 上一次的滤镜配置快照（用于判断是否需要重建）
    private var lastFilterConfig: FilterConfig?
    
    /// 滤镜配置快照
    private struct FilterConfig: Equatable {
        let volumeDB: Float
        let tempo: Float
        let loudnormEnabled: Bool
        let bassGain: Float
        let trebleGain: Float
        let surroundLevel: Float
        let reverbLevel: Float
        let pitchSemitones: Float
        let fadeInDuration: Float
        let fadeOutDuration: Float
        let sampleRate: Int
        let channelCount: Int
    }

    /// 是否有任何滤镜处于激活状态
    var isActive: Bool {
        lock.lock()
        let active = volumeDB != 0.0 || tempo != 1.0 || loudnormEnabled || 
                     bassGain != 0.0 || trebleGain != 0.0 || surroundLevel > 0.0 || 
                     reverbLevel > 0.0 || pitchSemitones != 0.0 || 
                     fadeInDuration > 0.0 || fadeOutDuration > 0.0
        lock.unlock()
        return active
    }

    // MARK: - 初始化

    init() {}

    deinit {
        destroyGraph()
    }

    // MARK: - 参数设置（不立即重建滤镜图，延迟到 process 时）

    func setVolume(_ db: Float) {
        lock.lock()
        if volumeDB != db {
            volumeDB = db
            needsRebuild = true
        }
        lock.unlock()
    }

    func setTempo(_ rate: Float) {
        let clamped = min(max(rate, 0.5), 4.0)
        lock.lock()
        if tempo != clamped {
            tempo = clamped
            needsRebuild = true
        }
        lock.unlock()
    }

    func setLoudnormEnabled(_ enabled: Bool) {
        lock.lock()
        if loudnormEnabled != enabled {
            loudnormEnabled = enabled
            needsRebuild = true
        }
        lock.unlock()
    }

    func setLoudnormParams(targetLUFS: Float = -14.0, lra: Float = 11.0, truePeak: Float = -1.0) {
        lock.lock()
        loudnormTarget = targetLUFS
        loudnormLRA = lra
        loudnormTP = truePeak
        if loudnormEnabled { needsRebuild = true }
        lock.unlock()
    }

    func setBassGain(_ db: Float) {
        let clamped = min(max(db, -12), 12)
        lock.lock()
        if bassGain != clamped {
            bassGain = clamped
            needsRebuild = true
        }
        lock.unlock()
    }

    func setTrebleGain(_ db: Float) {
        let clamped = min(max(db, -12), 12)
        lock.lock()
        if trebleGain != clamped {
            trebleGain = clamped
            needsRebuild = true
        }
        lock.unlock()
    }

    func setSurroundLevel(_ level: Float) {
        let clamped = min(max(level, 0), 1)
        lock.lock()
        if surroundLevel != clamped {
            surroundLevel = clamped
            needsRebuild = true
        }
        lock.unlock()
    }

    func setReverbLevel(_ level: Float) {
        let clamped = min(max(level, 0), 1)
        lock.lock()
        if reverbLevel != clamped {
            reverbLevel = clamped
            needsRebuild = true
        }
        lock.unlock()
    }

    func setPitchSemitones(_ semitones: Float) {
        let clamped = min(max(semitones, -12), 12)
        lock.lock()
        if pitchSemitones != clamped {
            pitchSemitones = clamped
            needsRebuild = true
        }
        lock.unlock()
    }

    func setFadeIn(duration: Float) {
        lock.lock()
        if fadeInDuration != duration {
            fadeInDuration = max(duration, 0)
            needsRebuild = true
        }
        lock.unlock()
    }

    func setFadeOut(duration: Float, startTime: Float) {
        lock.lock()
        if fadeOutDuration != duration || fadeOutStartTime != startTime {
            fadeOutDuration = max(duration, 0)
            fadeOutStartTime = max(startTime, 0)
            needsRebuild = true
        }
        lock.unlock()
    }

    func resetProcessedSamples() {
        lock.lock()
        processedSamples = 0
        currentPts = 0
        lock.unlock()
    }

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
        pitchSemitones = 0.0
        fadeInDuration = 0.0
        fadeOutDuration = 0.0
        fadeOutStartTime = 0.0
        processedSamples = 0
        currentPts = 0
        needsRebuild = true
        lastFilterConfig = nil
        lock.unlock()
        destroyGraph()
    }

    // MARK: - 处理

    func process(_ buffer: AudioBuffer) -> AudioBuffer {
        lock.lock()
        let active = volumeDB != 0.0 || tempo != 1.0 || loudnormEnabled || 
                     bassGain != 0.0 || trebleGain != 0.0 || surroundLevel > 0.0 || 
                     reverbLevel > 0.0 || pitchSemitones != 0.0 || 
                     fadeInDuration > 0.0 || fadeOutDuration > 0.0
        lock.unlock()

        guard active else { return buffer }

        lock.lock()

        processedSamples += Int64(buffer.frameCount)

        // 检查是否真的需要重建滤镜图
        let currentConfig = FilterConfig(
            volumeDB: volumeDB,
            tempo: tempo,
            loudnormEnabled: loudnormEnabled,
            bassGain: bassGain,
            trebleGain: trebleGain,
            surroundLevel: surroundLevel,
            reverbLevel: reverbLevel,
            pitchSemitones: pitchSemitones,
            fadeInDuration: fadeInDuration,
            fadeOutDuration: fadeOutDuration,
            sampleRate: buffer.sampleRate,
            channelCount: buffer.channelCount
        )
        
        let configChanged = lastFilterConfig != currentConfig
        
        if needsRebuild || configChanged || filterGraph == nil {
            sampleRate = buffer.sampleRate
            channelCount = buffer.channelCount
            
            // 只有在配置真正改变时才重建
            if configChanged || filterGraph == nil {
                rebuildGraph()
                lastFilterConfig = currentConfig
            }
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
        // 设置 pts 保证音频连续性
        frame.pointee.pts = currentPts
        currentPts += Int64(buffer.frameCount)
        
        av_channel_layout_default(&frame.pointee.ch_layout, Int32(buffer.channelCount))

        let ret = av_frame_get_buffer(frame, 0)
        guard ret >= 0 else {
            var fp: UnsafeMutablePointer<AVFrame>? = frame
            av_frame_free(&fp)
            lock.unlock()
            return buffer
        }

        // 确保 frame 可写
        let makeWritable = av_frame_make_writable(frame)
        guard makeWritable >= 0 else {
            var fp: UnsafeMutablePointer<AVFrame>? = frame
            av_frame_free(&fp)
            lock.unlock()
            return buffer
        }

        let totalBytes = buffer.frameCount * buffer.channelCount * MemoryLayout<Float>.size
        if let dst = frame.pointee.data.0 {
            memcpy(dst, buffer.data, totalBytes)
        }

        let addRet = av_buffersrc_add_frame_flags(srcCtx, frame, Int32(AV_BUFFERSRC_FLAG_KEEP_REF))
        var fp: UnsafeMutablePointer<AVFrame>? = frame
        av_frame_free(&fp)

        guard addRet >= 0 else {
            lock.unlock()
            return buffer
        }

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

    private func rebuildGraph() {
        destroyGraphUnsafe()

        filterGraph = avfilter_graph_alloc()
        guard let graph = filterGraph else { return }
        
        // 设置线程数，提高处理效率
        graph.pointee.nb_threads = 1

        // abuffer（输入源）
        guard let abuffer = avfilter_get_by_name("abuffer") else { return }
        let srcArgs = "sample_rate=\(sampleRate):sample_fmt=flt:channel_layout=\(channelCount == 1 ? "mono" : "stereo"):time_base=1/\(sampleRate)"
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

        var sampleFmts: [Int32] = [AV_SAMPLE_FMT_FLT.rawValue, -1]
        av_opt_set_int_list_flt(sink, "sample_fmts", &sampleFmts)

        var sampleRates: [Int32] = [Int32(sampleRate), -1]
        av_opt_set_int_list_int(sink, "sample_rates", &sampleRates)

        var lastCtx = src

        // volume 滤镜
        if volumeDB != 0.0 {
            if let ctx = createFilter(graph: graph, name: "volume", label: "vol",
                                       args: "volume=\(String(format: "%.2f", volumeDB))dB") {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // bass 滤镜 - 使用更宽的 Q 值减少伪影
        if bassGain != 0.0 {
            // width_type=q, width=1.0 提供更平滑的频率响应
            if let ctx = createFilter(graph: graph, name: "bass", label: "bass",
                                       args: "gain=\(String(format: "%.2f", bassGain)):frequency=100:width_type=q:width=1.0") {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // treble 滤镜 - 使用更宽的 Q 值
        if trebleGain != 0.0 {
            if let ctx = createFilter(graph: graph, name: "treble", label: "treble",
                                       args: "gain=\(String(format: "%.2f", trebleGain)):frequency=3000:width_type=q:width=1.0") {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // extrastereo 滤镜
        if surroundLevel > 0.0 {
            let m = 1.0 + surroundLevel * 2.0 // 映射 0~1 → 1.0~3.0（降低最大值减少失真）
            if let ctx = createFilter(graph: graph, name: "extrastereo", label: "surround",
                                       args: "m=\(String(format: "%.2f", m)):c=1") {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // aecho 滤镜 - 优化参数减少电流声
        if reverbLevel > 0.0 {
            let decay = 0.2 + reverbLevel * 0.3 // 映射 0~1 → 0.2~0.5
            // 使用更长的延迟和更低的衰减，减少金属感
            let args = "in_gain=0.6:out_gain=0.8:delays=80|160|240:decays=\(String(format: "%.2f", decay))|\(String(format: "%.2f", decay * 0.6))|\(String(format: "%.2f", decay * 0.3))"
            if let ctx = createFilter(graph: graph, name: "aecho", label: "reverb", args: args) {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // 变调实现
        let effectiveTempo: Float
        if pitchSemitones != 0.0 {
            let pitchRatio = powf(2.0, pitchSemitones / 12.0)
            let newRate = Int(Float(sampleRate) * pitchRatio)
            
            // asetrate 改变采样率
            if let ctx = createFilter(graph: graph, name: "asetrate", label: "pitch",
                                       args: "r=\(newRate)") {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
            
            // 使用 aresample 进行高质量重采样
            // soxr 重采样器提供最佳音质
            // precision=28 是最高精度
            // dither_method=none 避免抖动噪声
            if let ctx = createFilter(graph: graph, name: "aresample", label: "resample",
                                       args: "resampler=soxr:precision=28:dither_method=none:osr=\(sampleRate)") {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
            
            effectiveTempo = tempo
        } else {
            effectiveTempo = tempo
        }

        // atempo 滤镜
        if effectiveTempo != 1.0 {
            var remaining = effectiveTempo
            var atempoIndex = 0
            while abs(remaining - 1.0) > 0.001 {
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
                                           args: "tempo=\(String(format: "%.6f", factor))") {
                    guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                    lastCtx = ctx
                    atempoIndex += 1
                }
            }
        }

        // loudnorm 滤镜
        if loudnormEnabled {
            let args = "I=\(String(format: "%.1f", loudnormTarget)):LRA=\(String(format: "%.1f", loudnormLRA)):TP=\(String(format: "%.1f", loudnormTP)):print_format=none"
            if let ctx = createFilter(graph: graph, name: "loudnorm", label: "loudnorm", args: args) {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // afade 淡入
        if fadeInDuration > 0.0 {
            let samples = Int(fadeInDuration * Float(sampleRate))
            if let ctx = createFilter(graph: graph, name: "afade", label: "fadein",
                                       args: "type=in:start_sample=0:nb_samples=\(samples):curve=tri") {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // afade 淡出
        if fadeOutDuration > 0.0 {
            let startSample = Int(fadeOutStartTime * Float(sampleRate))
            let nbSamples = Int(fadeOutDuration * Float(sampleRate))
            if let ctx = createFilter(graph: graph, name: "afade", label: "fadeout",
                                       args: "type=out:start_sample=\(startSample):nb_samples=\(nbSamples):curve=tri") {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // aformat 确保输出格式
        let aformatArgs = "sample_fmts=flt:sample_rates=\(sampleRate):channel_layouts=\(channelCount == 1 ? "mono" : "stereo")"
        if let ctx = createFilter(graph: graph, name: "aformat", label: "aformat", args: aformatArgs) {
            guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
            lastCtx = ctx
        }

        guard avfilter_link(lastCtx, 0, sink, 0) >= 0 else {
            destroyGraphUnsafe()
            return
        }

        guard avfilter_graph_config(graph, nil) >= 0 else {
            destroyGraphUnsafe()
            return
        }
    }

    private func createFilter(graph: UnsafeMutablePointer<AVFilterGraph>, name: String, label: String, args: String) -> UnsafeMutablePointer<AVFilterContext>? {
        guard let filter = avfilter_get_by_name(name) else { return nil }
        var ctx: UnsafeMutablePointer<AVFilterContext>?
        guard avfilter_graph_create_filter(&ctx, filter, label, args, nil, graph) >= 0 else { return nil }
        return ctx
    }

    private func destroyGraph() {
        lock.lock()
        destroyGraphUnsafe()
        lock.unlock()
    }

    private func destroyGraphUnsafe() {
        if filterGraph != nil {
            avfilter_graph_free(&filterGraph)
        }
        filterGraph = nil
        bufferSrcCtx = nil
        bufferSinkCtx = nil
    }
}

// MARK: - av_opt_set_int_list 辅助

private func av_opt_set_int_list_flt(_ obj: UnsafeMutablePointer<AVFilterContext>, _ name: String, _ list: UnsafeMutablePointer<Int32>) {
    var count = 0
    while list[count] != -1 { count += 1 }
    count += 1
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
