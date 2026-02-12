// SuperEQFilterGraph.swift
// FFmpegSwiftSDK
//
// 封装 FFmpeg superequalizer 滤镜，提供 18 段高精度均衡器引擎。
// 滤镜链: abuffer → superequalizer → aformat → abuffersink
//
// superequalizer 使用 16383 阶 FIR 滤波器 + FFT，
// 频段之间几乎无重叠和滚降，精度远高于传统 biquad IIR 均衡器。

import Foundation
import CFFmpeg

/// FFmpeg superequalizer 滤镜图引擎。
///
/// 内部维护一个 AVFilterGraph，参数变化时重建滤镜链。
/// 线程安全：所有参数修改和处理都通过 NSLock 保护。
final class SuperEQFilterGraph {

    // MARK: - 属性

    private let lock = NSLock()

    /// 是否启用
    private(set) var isEnabled: Bool = false

    /// 每个频段的增益（dB），范围 [-12, +12]
    private var gains: [Float] = Array(repeating: 0.0, count: 18)

    /// 当前音频格式
    private var sampleRate: Int = 0
    private var channelCount: Int = 0

    /// FFmpeg 滤镜图组件
    private var filterGraph: UnsafeMutablePointer<AVFilterGraph>?
    private var bufferSrcCtx: UnsafeMutablePointer<AVFilterContext>?
    private var bufferSinkCtx: UnsafeMutablePointer<AVFilterContext>?

    /// 滤镜图是否需要重建
    private var needsRebuild: Bool = true

    // MARK: - 初始化

    init() {}

    deinit {
        destroyGraph()
    }

    // MARK: - 启用/禁用

    func setEnabled(_ enabled: Bool) {
        lock.lock()
        if isEnabled != enabled {
            isEnabled = enabled
            needsRebuild = true
        }
        lock.unlock()
    }

    // MARK: - 增益控制

    /// 设置指定频段的增益（dB）。
    /// - Parameters:
    ///   - gainDB: 增益值，范围 [-12, +12] dB，超出会被 clamp。
    ///   - band: 目标频段。
    func setGain(_ gainDB: Float, for band: SuperEQBand) {
        let clamped = min(max(gainDB, -12.0), 12.0)
        lock.lock()
        if gains[band.rawValue] != clamped {
            gains[band.rawValue] = clamped
            if isEnabled { needsRebuild = true }
        }
        lock.unlock()
    }

    /// 获取指定频段的当前增益（dB）。
    func gain(for band: SuperEQBand) -> Float {
        lock.lock()
        let g = gains[band.rawValue]
        lock.unlock()
        return g
    }

    /// 批量设置增益。未包含的频段保持不变。
    func setGains(_ newGains: [SuperEQBand: Float]) {
        lock.lock()
        var changed = false
        for (band, db) in newGains {
            let clamped = min(max(db, -12.0), 12.0)
            if gains[band.rawValue] != clamped {
                gains[band.rawValue] = clamped
                changed = true
            }
        }
        if changed && isEnabled { needsRebuild = true }
        lock.unlock()
    }

    /// 获取所有频段的当前增益。
    func allGains() -> [SuperEQBand: Float] {
        lock.lock()
        var result: [SuperEQBand: Float] = [:]
        for band in SuperEQBand.allCases {
            result[band] = gains[band.rawValue]
        }
        lock.unlock()
        return result
    }

    /// 重置所有频段到 0 dB。
    func reset() {
        lock.lock()
        for i in 0..<18 { gains[i] = 0.0 }
        needsRebuild = true
        lock.unlock()
        destroyGraph()
    }

    // MARK: - 处理

    /// 处理一个音频 buffer，返回 superequalizer 处理后的结果。
    /// 如果未启用或所有增益为 0，直接返回原 buffer（零拷贝）。
    func process(_ buffer: AudioBuffer) -> AudioBuffer {
        lock.lock()
        let active = isEnabled && gains.contains(where: { $0 != 0.0 })
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
    /// 滤镜链: abuffer → superequalizer → aformat → abuffersink
    private func rebuildGraph() {
        destroyGraphUnsafe()

        filterGraph = avfilter_graph_alloc()
        guard let graph = filterGraph else { return }

        // abuffer（输入源）
        guard let abuffer = avfilter_get_by_name("abuffer") else {
            destroyGraphUnsafe()
            return
        }
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
        _ = sampleFmts.withUnsafeMutableBytes { ptr in
            av_opt_set_bin(sink, "sample_fmts",
                           ptr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                           Int32(ptr.count),
                           AV_OPT_SEARCH_CHILDREN)
        }

        var sampleRates: [Int32] = [Int32(sampleRate), -1]
        _ = sampleRates.withUnsafeMutableBytes { ptr in
            av_opt_set_bin(sink, "sample_rates",
                           ptr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                           Int32(ptr.count),
                           AV_OPT_SEARCH_CHILDREN)
        }

        // superequalizer 滤镜
        // 参数: 1b ~ 18b，线性增益 0-20（1.0 = 0dB）
        // dB 转线性: linearGain = pow(10, dB/20)
        let eqArgs = buildSuperEQArgs()
        guard let eqFilter = avfilter_get_by_name("superequalizer") else {
            destroyGraphUnsafe()
            return
        }
        var eqCtx: UnsafeMutablePointer<AVFilterContext>?
        guard avfilter_graph_create_filter(&eqCtx, eqFilter, "supereq", eqArgs, nil, graph) >= 0,
              let eq = eqCtx else {
            destroyGraphUnsafe()
            return
        }

        // aformat（确保输出格式）
        let aformatArgs = "sample_fmts=flt:sample_rates=\(sampleRate):channel_layouts=\(channelCount == 1 ? "mono" : "stereo")"
        guard let aformatFilter = avfilter_get_by_name("aformat") else {
            destroyGraphUnsafe()
            return
        }
        var afmtCtx: UnsafeMutablePointer<AVFilterContext>?
        guard avfilter_graph_create_filter(&afmtCtx, aformatFilter, "aformat", aformatArgs, nil, graph) >= 0,
              let afmt = afmtCtx else {
            destroyGraphUnsafe()
            return
        }

        // 连接: src → superequalizer → aformat → sink
        guard avfilter_link(src, 0, eq, 0) >= 0,
              avfilter_link(eq, 0, afmt, 0) >= 0,
              avfilter_link(afmt, 0, sink, 0) >= 0 else {
            destroyGraphUnsafe()
            return
        }

        // 配置图
        guard avfilter_graph_config(graph, nil) >= 0 else {
            destroyGraphUnsafe()
            return
        }
    }

    /// 构建 superequalizer 参数字符串。
    /// 格式: "1b=1.0:2b=1.0:...:18b=1.0"
    /// dB 转线性增益: linearGain = pow(10, dB/20)
    /// 0 dB → 1.0, +12 dB → 3.98, -12 dB → 0.25
    private func buildSuperEQArgs() -> String {
        var parts: [String] = []
        for i in 0..<18 {
            let linearGain = powf(10.0, gains[i] / 20.0)
            parts.append("\(i + 1)b=\(String(format: "%.4f", linearGain))")
        }
        return parts.joined(separator: ":")
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
