// AudioFilterGraph.swift
// FFmpegSwiftSDK
//
// 封装 FFmpeg avfilter 图，提供完整的音频效果处理能力。
// 支持 50+ 种音频滤镜，涵盖音量、动态、频率、空间、时间、特效等。
//
// 滤镜链: abuffer → [各种滤镜] → aformat → abuffersink

import Foundation
import CFFmpeg

/// FFmpeg avfilter 音频滤镜图，支持实时参数调整。
///
/// 内部维护一个 AVFilterGraph，按需重建滤镜链。
/// 线程安全：所有参数修改和处理都通过 NSLock 保护。
final class AudioFilterGraph {

    // MARK: - 属性

    private let lock = NSLock()

    // ==================== 基础音量控制 ====================
    
    /// 音量增益（dB），0 = 不变
    private(set) var volumeDB: Float = 0.0
    
    // ==================== 动态处理 ====================
    
    /// 响度标准化（EBU R128）
    private(set) var loudnormEnabled: Bool = false
    private(set) var loudnormTarget: Float = -14.0  // LUFS
    private(set) var loudnormLRA: Float = 11.0      // LRA
    private(set) var loudnormTP: Float = -1.0       // True Peak
    
    /// 动态压缩（夜间模式）
    private(set) var compressorEnabled: Bool = false
    private(set) var compressorThreshold: Float = -20.0  // dB
    private(set) var compressorRatio: Float = 4.0        // 压缩比
    private(set) var compressorAttack: Float = 5.0       // ms
    private(set) var compressorRelease: Float = 50.0     // ms
    private(set) var compressorMakeup: Float = 2.0       // dB
    
    /// 限幅器
    private(set) var limiterEnabled: Bool = false
    private(set) var limiterLimit: Float = -1.0  // dBFS
    
    /// 噪声门
    private(set) var gateEnabled: Bool = false
    private(set) var gateThreshold: Float = -40.0  // dB
    
    /// 自动增益（动态标准化）
    private(set) var autoGainEnabled: Bool = false
    
    // ==================== 速度与音调 ====================
    
    /// 播放速度倍率，1.0 = 原速
    private(set) var tempo: Float = 1.0
    
    /// 变调（半音数），范围 [-12, +12]
    private(set) var pitchSemitones: Float = 0.0
    
    // ==================== 均衡器与频率 ====================
    
    /// 低音增益（dB）
    private(set) var bassGain: Float = 0.0
    
    /// 高音增益（dB）
    private(set) var trebleGain: Float = 0.0
    
    /// 超低音增强
    private(set) var subboostEnabled: Bool = false
    private(set) var subboostGain: Float = 6.0      // dB
    private(set) var subboostCutoff: Float = 100.0  // Hz
    
    /// 带通滤波
    private(set) var bandpassEnabled: Bool = false
    private(set) var bandpassFrequency: Float = 1000.0  // Hz
    private(set) var bandpassWidth: Float = 2000.0      // Hz
    
    /// 带阻滤波
    private(set) var bandrejectEnabled: Bool = false
    private(set) var bandrejectFrequency: Float = 1000.0  // Hz
    private(set) var bandrejectWidth: Float = 200.0       // Hz
    
    // ==================== 空间效果 ====================
    
    /// 环绕增强（0~1）
    private(set) var surroundLevel: Float = 0.0
    
    /// 混响强度（0~1）
    private(set) var reverbLevel: Float = 0.0
    
    /// 立体声宽度（0~2），1.0 = 原始
    private(set) var stereoWidth: Float = 1.0
    
    /// 声道平衡（-1 = 全左，0 = 居中，+1 = 全右）
    private(set) var channelBalance: Float = 0.0
    
    /// 单声道模式
    private(set) var monoEnabled: Bool = false
    
    /// 声道交换
    private(set) var channelSwapEnabled: Bool = false
    
    // ==================== 时间效果 ====================
    
    /// 淡入时长（秒）
    private(set) var fadeInDuration: Float = 0.0
    
    /// 淡出时长（秒）
    private(set) var fadeOutDuration: Float = 0.0
    private(set) var fadeOutStartTime: Float = 0.0
    
    /// 延迟（毫秒）
    private(set) var delayMs: Float = 0.0
    
    // ==================== 特殊效果 ====================
    
    /// 人声消除强度（0~1）
    private(set) var vocalRemovalLevel: Float = 0.0
    
    /// 合唱效果
    private(set) var chorusEnabled: Bool = false
    private(set) var chorusDepth: Float = 0.5
    
    /// 镶边效果
    private(set) var flangerEnabled: Bool = false
    private(set) var flangerDepth: Float = 0.5
    
    /// 颤音效果（音量）
    private(set) var tremoloEnabled: Bool = false
    private(set) var tremoloFrequency: Float = 5.0  // Hz
    private(set) var tremoloDepth: Float = 0.5
    
    /// 颤抖效果（音调）
    private(set) var vibratoEnabled: Bool = false
    private(set) var vibratoFrequency: Float = 5.0  // Hz
    private(set) var vibratoDepth: Float = 0.5
    
    /// 失真效果（Lo-Fi）
    private(set) var crusherEnabled: Bool = false
    private(set) var crusherBits: Float = 8.0       // 位深
    private(set) var crusherSamples: Float = 4.0    // 采样率降低因子
    
    /// 电话效果
    private(set) var telephoneEnabled: Bool = false
    
    /// 水下效果
    private(set) var underwaterEnabled: Bool = false
    
    /// 收音机效果
    private(set) var radioEnabled: Bool = false
    
    // ==================== 内部状态 ====================
    
    private var processedSamples: Int64 = 0
    private var sampleRate: Int = 0
    private var channelCount: Int = 0
    private var filterGraph: UnsafeMutablePointer<AVFilterGraph>?
    private var bufferSrcCtx: UnsafeMutablePointer<AVFilterContext>?
    private var bufferSinkCtx: UnsafeMutablePointer<AVFilterContext>?
    private var needsRebuild: Bool = true

    /// 是否有任何滤镜处于激活状态
    var isActive: Bool {
        lock.lock()
        let active = checkAnyFilterActive()
        lock.unlock()
        return active
    }
    
    private func checkAnyFilterActive() -> Bool {
        return volumeDB != 0.0 ||
               loudnormEnabled ||
               compressorEnabled ||
               limiterEnabled ||
               gateEnabled ||
               autoGainEnabled ||
               tempo != 1.0 ||
               pitchSemitones != 0.0 ||
               bassGain != 0.0 ||
               trebleGain != 0.0 ||
               subboostEnabled ||
               bandpassEnabled ||
               bandrejectEnabled ||
               surroundLevel > 0.0 ||
               reverbLevel > 0.0 ||
               stereoWidth != 1.0 ||
               channelBalance != 0.0 ||
               monoEnabled ||
               channelSwapEnabled ||
               fadeInDuration > 0.0 ||
               fadeOutDuration > 0.0 ||
               delayMs > 0.0 ||
               vocalRemovalLevel > 0.0 ||
               chorusEnabled ||
               flangerEnabled ||
               tremoloEnabled ||
               vibratoEnabled ||
               crusherEnabled ||
               telephoneEnabled ||
               underwaterEnabled ||
               radioEnabled
    }

    // MARK: - 初始化

    init() {}

    deinit {
        destroyGraph()
    }


    // MARK: - 基础音量控制

    /// 设置音量增益（dB）。0 = 不变，正值增大，负值减小。
    func setVolume(_ db: Float) {
        lock.lock()
        if volumeDB != db {
            volumeDB = db
            needsRebuild = true
        }
        lock.unlock()
    }

    // MARK: - 动态处理

    /// 启用/禁用响度标准化（EBU R128）
    func setLoudnormEnabled(_ enabled: Bool) {
        lock.lock()
        if loudnormEnabled != enabled {
            loudnormEnabled = enabled
            needsRebuild = true
        }
        lock.unlock()
    }

    /// 设置 loudnorm 参数
    func setLoudnormParams(targetLUFS: Float = -14.0, lra: Float = 11.0, truePeak: Float = -1.0) {
        lock.lock()
        loudnormTarget = targetLUFS
        loudnormLRA = lra
        loudnormTP = truePeak
        if loudnormEnabled { needsRebuild = true }
        lock.unlock()
    }

    /// 启用/禁用动态压缩（夜间模式）
    func setCompressorEnabled(_ enabled: Bool) {
        lock.lock()
        if compressorEnabled != enabled {
            compressorEnabled = enabled
            needsRebuild = true
        }
        lock.unlock()
    }

    /// 设置动态压缩参数
    func setCompressorParams(threshold: Float = -20.0, ratio: Float = 4.0, attack: Float = 5.0, release: Float = 50.0, makeup: Float = 2.0) {
        lock.lock()
        compressorThreshold = threshold
        compressorRatio = ratio
        compressorAttack = attack
        compressorRelease = release
        compressorMakeup = makeup
        if compressorEnabled { needsRebuild = true }
        lock.unlock()
    }

    /// 启用/禁用限幅器
    func setLimiterEnabled(_ enabled: Bool) {
        lock.lock()
        if limiterEnabled != enabled {
            limiterEnabled = enabled
            needsRebuild = true
        }
        lock.unlock()
    }

    /// 设置限幅器阈值（dBFS）
    func setLimiterLimit(_ limit: Float) {
        lock.lock()
        limiterLimit = limit
        if limiterEnabled { needsRebuild = true }
        lock.unlock()
    }

    /// 启用/禁用噪声门
    func setGateEnabled(_ enabled: Bool) {
        lock.lock()
        if gateEnabled != enabled {
            gateEnabled = enabled
            needsRebuild = true
        }
        lock.unlock()
    }

    /// 设置噪声门阈值（dB）
    func setGateThreshold(_ threshold: Float) {
        lock.lock()
        gateThreshold = threshold
        if gateEnabled { needsRebuild = true }
        lock.unlock()
    }

    /// 启用/禁用自动增益
    func setAutoGainEnabled(_ enabled: Bool) {
        lock.lock()
        if autoGainEnabled != enabled {
            autoGainEnabled = enabled
            needsRebuild = true
        }
        lock.unlock()
    }

    // MARK: - 速度与音调

    /// 设置播放速度倍率。范围 [0.5, 4.0]，1.0 = 原速。
    func setTempo(_ rate: Float) {
        let clamped = min(max(rate, 0.5), 4.0)
        lock.lock()
        if tempo != clamped {
            tempo = clamped
            needsRebuild = true
        }
        lock.unlock()
    }

    /// 设置变调（半音数）。范围 [-12, +12]。
    func setPitchSemitones(_ semitones: Float) {
        let clamped = min(max(semitones, -12), 12)
        lock.lock()
        if pitchSemitones != clamped {
            pitchSemitones = clamped
            needsRebuild = true
        }
        lock.unlock()
    }

    // MARK: - 均衡器与频率

    /// 设置低音增益（dB）。范围 [-12, +12]。
    func setBassGain(_ db: Float) {
        let clamped = min(max(db, -12), 12)
        lock.lock()
        if bassGain != clamped {
            bassGain = clamped
            needsRebuild = true
        }
        lock.unlock()
    }

    /// 设置高音增益（dB）。范围 [-12, +12]。
    func setTrebleGain(_ db: Float) {
        let clamped = min(max(db, -12), 12)
        lock.lock()
        if trebleGain != clamped {
            trebleGain = clamped
            needsRebuild = true
        }
        lock.unlock()
    }

    /// 启用/禁用超低音增强
    func setSubboostEnabled(_ enabled: Bool) {
        lock.lock()
        if subboostEnabled != enabled {
            subboostEnabled = enabled
            needsRebuild = true
        }
        lock.unlock()
    }

    /// 设置超低音增强参数
    func setSubboostParams(gain: Float = 6.0, cutoff: Float = 100.0) {
        lock.lock()
        subboostGain = gain
        subboostCutoff = cutoff
        if subboostEnabled { needsRebuild = true }
        lock.unlock()
    }

    /// 启用/禁用带通滤波
    func setBandpassEnabled(_ enabled: Bool) {
        lock.lock()
        if bandpassEnabled != enabled {
            bandpassEnabled = enabled
            needsRebuild = true
        }
        lock.unlock()
    }

    /// 设置带通滤波参数
    func setBandpassParams(frequency: Float, width: Float) {
        lock.lock()
        bandpassFrequency = frequency
        bandpassWidth = width
        if bandpassEnabled { needsRebuild = true }
        lock.unlock()
    }

    /// 启用/禁用带阻滤波
    func setBandrejectEnabled(_ enabled: Bool) {
        lock.lock()
        if bandrejectEnabled != enabled {
            bandrejectEnabled = enabled
            needsRebuild = true
        }
        lock.unlock()
    }

    /// 设置带阻滤波参数
    func setBandrejectParams(frequency: Float, width: Float) {
        lock.lock()
        bandrejectFrequency = frequency
        bandrejectWidth = width
        if bandrejectEnabled { needsRebuild = true }
        lock.unlock()
    }

    // MARK: - 空间效果

    /// 设置环绕强度（0~1）
    func setSurroundLevel(_ level: Float) {
        let clamped = min(max(level, 0), 1)
        lock.lock()
        if surroundLevel != clamped {
            surroundLevel = clamped
            needsRebuild = true
        }
        lock.unlock()
    }

    /// 设置混响强度（0~1）
    func setReverbLevel(_ level: Float) {
        let clamped = min(max(level, 0), 1)
        lock.lock()
        if reverbLevel != clamped {
            reverbLevel = clamped
            needsRebuild = true
        }
        lock.unlock()
    }

    /// 设置立体声宽度（0~2），1.0 = 原始
    func setStereoWidth(_ width: Float) {
        let clamped = min(max(width, 0), 2)
        lock.lock()
        if stereoWidth != clamped {
            stereoWidth = clamped
            needsRebuild = true
        }
        lock.unlock()
    }

    /// 设置声道平衡（-1 = 全左，0 = 居中，+1 = 全右）
    func setChannelBalance(_ balance: Float) {
        let clamped = min(max(balance, -1), 1)
        lock.lock()
        if channelBalance != clamped {
            channelBalance = clamped
            needsRebuild = true
        }
        lock.unlock()
    }

    /// 启用/禁用单声道模式
    func setMonoEnabled(_ enabled: Bool) {
        lock.lock()
        if monoEnabled != enabled {
            monoEnabled = enabled
            needsRebuild = true
        }
        lock.unlock()
    }

    /// 启用/禁用声道交换
    func setChannelSwapEnabled(_ enabled: Bool) {
        lock.lock()
        if channelSwapEnabled != enabled {
            channelSwapEnabled = enabled
            needsRebuild = true
        }
        lock.unlock()
    }

    // MARK: - 时间效果

    /// 设置淡入时长（秒）
    func setFadeIn(duration: Float) {
        lock.lock()
        if fadeInDuration != duration {
            fadeInDuration = max(duration, 0)
            needsRebuild = true
        }
        lock.unlock()
    }

    /// 设置淡出效果
    func setFadeOut(duration: Float, startTime: Float) {
        lock.lock()
        if fadeOutDuration != duration || fadeOutStartTime != startTime {
            fadeOutDuration = max(duration, 0)
            fadeOutStartTime = max(startTime, 0)
            needsRebuild = true
        }
        lock.unlock()
    }

    /// 设置延迟（毫秒）
    func setDelay(_ ms: Float) {
        let clamped = max(ms, 0)
        lock.lock()
        if delayMs != clamped {
            delayMs = clamped
            needsRebuild = true
        }
        lock.unlock()
    }

    // MARK: - 特殊效果

    /// 设置人声消除强度（0~1）
    func setVocalRemoval(_ level: Float) {
        let clamped = min(max(level, 0), 1)
        lock.lock()
        if vocalRemovalLevel != clamped {
            vocalRemovalLevel = clamped
            needsRebuild = true
        }
        lock.unlock()
    }

    /// 启用/禁用合唱效果
    func setChorusEnabled(_ enabled: Bool) {
        lock.lock()
        if chorusEnabled != enabled {
            chorusEnabled = enabled
            needsRebuild = true
        }
        lock.unlock()
    }

    /// 设置合唱深度（0~1）
    func setChorusDepth(_ depth: Float) {
        let clamped = min(max(depth, 0), 1)
        lock.lock()
        if chorusDepth != clamped {
            chorusDepth = clamped
            if chorusEnabled { needsRebuild = true }
        }
        lock.unlock()
    }

    /// 启用/禁用镶边效果
    func setFlangerEnabled(_ enabled: Bool) {
        lock.lock()
        if flangerEnabled != enabled {
            flangerEnabled = enabled
            needsRebuild = true
        }
        lock.unlock()
    }

    /// 设置镶边深度（0~1）
    func setFlangerDepth(_ depth: Float) {
        let clamped = min(max(depth, 0), 1)
        lock.lock()
        if flangerDepth != clamped {
            flangerDepth = clamped
            if flangerEnabled { needsRebuild = true }
        }
        lock.unlock()
    }

    /// 启用/禁用颤音效果
    func setTremoloEnabled(_ enabled: Bool) {
        lock.lock()
        if tremoloEnabled != enabled {
            tremoloEnabled = enabled
            needsRebuild = true
        }
        lock.unlock()
    }

    /// 设置颤音参数
    func setTremoloParams(frequency: Float = 5.0, depth: Float = 0.5) {
        lock.lock()
        tremoloFrequency = frequency
        tremoloDepth = min(max(depth, 0), 1)
        if tremoloEnabled { needsRebuild = true }
        lock.unlock()
    }

    /// 启用/禁用颤抖效果
    func setVibratoEnabled(_ enabled: Bool) {
        lock.lock()
        if vibratoEnabled != enabled {
            vibratoEnabled = enabled
            needsRebuild = true
        }
        lock.unlock()
    }

    /// 设置颤抖参数
    func setVibratoParams(frequency: Float = 5.0, depth: Float = 0.5) {
        lock.lock()
        vibratoFrequency = frequency
        vibratoDepth = min(max(depth, 0), 1)
        if vibratoEnabled { needsRebuild = true }
        lock.unlock()
    }

    /// 启用/禁用失真效果（Lo-Fi）
    func setCrusherEnabled(_ enabled: Bool) {
        lock.lock()
        if crusherEnabled != enabled {
            crusherEnabled = enabled
            needsRebuild = true
        }
        lock.unlock()
    }

    /// 设置失真参数
    func setCrusherParams(bits: Float = 8.0, samples: Float = 4.0) {
        lock.lock()
        crusherBits = min(max(bits, 1), 16)
        crusherSamples = min(max(samples, 1), 16)
        if crusherEnabled { needsRebuild = true }
        lock.unlock()
    }

    /// 启用/禁用电话效果
    func setTelephoneEnabled(_ enabled: Bool) {
        lock.lock()
        if telephoneEnabled != enabled {
            telephoneEnabled = enabled
            needsRebuild = true
        }
        lock.unlock()
    }

    /// 启用/禁用水下效果
    func setUnderwaterEnabled(_ enabled: Bool) {
        lock.lock()
        if underwaterEnabled != enabled {
            underwaterEnabled = enabled
            needsRebuild = true
        }
        lock.unlock()
    }

    /// 启用/禁用收音机效果
    func setRadioEnabled(_ enabled: Bool) {
        lock.lock()
        if radioEnabled != enabled {
            radioEnabled = enabled
            needsRebuild = true
        }
        lock.unlock()
    }

    // MARK: - 重置

    /// 重置已处理采样计数
    func resetProcessedSamples() {
        lock.lock()
        processedSamples = 0
        lock.unlock()
    }

    /// 重置所有滤镜到默认值
    func reset() {
        lock.lock()
        // 基础
        volumeDB = 0.0
        // 动态
        loudnormEnabled = false
        loudnormTarget = -14.0
        loudnormLRA = 11.0
        loudnormTP = -1.0
        compressorEnabled = false
        compressorThreshold = -20.0
        compressorRatio = 4.0
        compressorAttack = 5.0
        compressorRelease = 50.0
        compressorMakeup = 2.0
        limiterEnabled = false
        limiterLimit = -1.0
        gateEnabled = false
        gateThreshold = -40.0
        autoGainEnabled = false
        // 速度音调
        tempo = 1.0
        pitchSemitones = 0.0
        // 频率
        bassGain = 0.0
        trebleGain = 0.0
        subboostEnabled = false
        subboostGain = 6.0
        subboostCutoff = 100.0
        bandpassEnabled = false
        bandpassFrequency = 1000.0
        bandpassWidth = 2000.0
        bandrejectEnabled = false
        bandrejectFrequency = 1000.0
        bandrejectWidth = 200.0
        // 空间
        surroundLevel = 0.0
        reverbLevel = 0.0
        stereoWidth = 1.0
        channelBalance = 0.0
        monoEnabled = false
        channelSwapEnabled = false
        // 时间
        fadeInDuration = 0.0
        fadeOutDuration = 0.0
        fadeOutStartTime = 0.0
        delayMs = 0.0
        // 特效
        vocalRemovalLevel = 0.0
        chorusEnabled = false
        chorusDepth = 0.5
        flangerEnabled = false
        flangerDepth = 0.5
        tremoloEnabled = false
        tremoloFrequency = 5.0
        tremoloDepth = 0.5
        vibratoEnabled = false
        vibratoFrequency = 5.0
        vibratoDepth = 0.5
        crusherEnabled = false
        crusherBits = 8.0
        crusherSamples = 4.0
        telephoneEnabled = false
        underwaterEnabled = false
        radioEnabled = false
        // 状态
        processedSamples = 0
        needsRebuild = true
        lock.unlock()
        destroyGraph()
    }


    // MARK: - 处理

    /// 处理一个音频 buffer，返回滤镜处理后的结果。
    /// 如果没有激活的滤镜，直接返回原 buffer（零拷贝）。
    func process(_ buffer: AudioBuffer) -> AudioBuffer {
        lock.lock()
        let active = checkAnyFilterActive()
        lock.unlock()

        guard active else { return buffer }

        lock.lock()

        processedSamples += Int64(buffer.frameCount)

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

        // 拷贝数据到 frame
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

    /// 重建 FFmpeg avfilter 图
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

        // 设置 sink 输出格式
        var sampleFmts: [Int32] = [AV_SAMPLE_FMT_FLT.rawValue, -1]
        av_opt_set_int_list_flt(sink, "sample_fmts", &sampleFmts)
        var sampleRates: [Int32] = [Int32(sampleRate), -1]
        av_opt_set_int_list_int(sink, "sample_rates", &sampleRates)

        // 构建滤镜链
        var lastCtx = src

        // ==================== 音量控制 ====================
        if volumeDB != 0.0 {
            if let ctx = createFilter(graph: graph, name: "volume", label: "vol",
                                       args: "volume=\(String(format: "%.1f", volumeDB))dB") {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // ==================== 动态处理 ====================
        
        // 噪声门
        if gateEnabled {
            if let ctx = createFilter(graph: graph, name: "agate", label: "gate",
                                       args: "threshold=\(String(format: "%.1f", gateThreshold))dB") {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // 动态压缩
        if compressorEnabled {
            let args = "threshold=\(String(format: "%.1f", compressorThreshold))dB:ratio=\(String(format: "%.1f", compressorRatio)):attack=\(String(format: "%.1f", compressorAttack)):release=\(String(format: "%.1f", compressorRelease)):makeup=\(String(format: "%.1f", compressorMakeup))dB"
            if let ctx = createFilter(graph: graph, name: "acompressor", label: "comp", args: args) {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // 限幅器
        if limiterEnabled {
            if let ctx = createFilter(graph: graph, name: "alimiter", label: "limiter",
                                       args: "limit=\(String(format: "%.1f", limiterLimit))dB:level=false") {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // 自动增益
        if autoGainEnabled {
            if let ctx = createFilter(graph: graph, name: "dynaudnorm", label: "autogain",
                                       args: "framelen=500:gausssize=31:peak=0.95") {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // 响度标准化
        if loudnormEnabled {
            let args = "I=\(String(format: "%.1f", loudnormTarget)):LRA=\(String(format: "%.1f", loudnormLRA)):TP=\(String(format: "%.1f", loudnormTP))"
            if let ctx = createFilter(graph: graph, name: "loudnorm", label: "loudnorm", args: args) {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // ==================== 均衡器与频率 ====================
        
        // 低音
        if bassGain != 0.0 {
            if let ctx = createFilter(graph: graph, name: "bass", label: "bass",
                                       args: "gain=\(String(format: "%.1f", bassGain)):frequency=100:width_type=o:width=0.5") {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // 高音
        if trebleGain != 0.0 {
            if let ctx = createFilter(graph: graph, name: "treble", label: "treble",
                                       args: "gain=\(String(format: "%.1f", trebleGain)):frequency=3000:width_type=o:width=0.5") {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // 超低音增强
        if subboostEnabled {
            if let ctx = createFilter(graph: graph, name: "asubboost", label: "subboost",
                                       args: "dry=0.5:wet=0.8:decay=0.7:feedback=0.5:cutoff=\(String(format: "%.0f", subboostCutoff))") {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // 带通滤波
        if bandpassEnabled {
            if let ctx = createFilter(graph: graph, name: "bandpass", label: "bandpass",
                                       args: "frequency=\(String(format: "%.0f", bandpassFrequency)):width_type=h:width=\(String(format: "%.0f", bandpassWidth))") {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // 带阻滤波
        if bandrejectEnabled {
            if let ctx = createFilter(graph: graph, name: "bandreject", label: "bandreject",
                                       args: "frequency=\(String(format: "%.0f", bandrejectFrequency)):width_type=h:width=\(String(format: "%.0f", bandrejectWidth))") {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // ==================== 空间效果 ====================
        
        // 人声消除（需要在空间效果之前，因为它依赖立体声）
        if vocalRemovalLevel > 0.0 && channelCount == 2 {
            // 使用 stereotools 的 mlev（中置电平）来消除人声
            let mlev = 1.0 - vocalRemovalLevel
            if let ctx = createFilter(graph: graph, name: "stereotools", label: "vocal",
                                       args: "mlev=\(String(format: "%.2f", mlev))") {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // 声道交换
        if channelSwapEnabled && channelCount == 2 {
            if let ctx = createFilter(graph: graph, name: "pan", label: "swap",
                                       args: "stereo|c0=c1|c1=c0") {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // 声道平衡
        if channelBalance != 0.0 && channelCount == 2 {
            let leftGain = channelBalance < 0 ? 1.0 : 1.0 - channelBalance
            let rightGain = channelBalance > 0 ? 1.0 : 1.0 + channelBalance
            if let ctx = createFilter(graph: graph, name: "pan", label: "balance",
                                       args: "stereo|c0=\(String(format: "%.2f", leftGain))*c0|c1=\(String(format: "%.2f", rightGain))*c1") {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // 立体声宽度
        if stereoWidth != 1.0 && channelCount == 2 {
            if let ctx = createFilter(graph: graph, name: "stereotools", label: "width",
                                       args: "slev=\(String(format: "%.2f", stereoWidth))") {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // 环绕增强
        if surroundLevel > 0.0 && channelCount == 2 {
            let m = 1.0 + surroundLevel * 3.0
            if let ctx = createFilter(graph: graph, name: "extrastereo", label: "surround",
                                       args: "m=\(String(format: "%.2f", m))") {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // 混响
        if reverbLevel > 0.0 {
            let decay = 0.1 + reverbLevel * 0.5
            let args = "in_gain=0.8:out_gain=0.9:delays=60|120:decays=\(String(format: "%.2f", decay))|\(String(format: "%.2f", decay * 0.7))"
            if let ctx = createFilter(graph: graph, name: "aecho", label: "reverb", args: args) {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // 单声道
        if monoEnabled && channelCount == 2 {
            if let ctx = createFilter(graph: graph, name: "pan", label: "mono",
                                       args: "mono|c0=0.5*c0+0.5*c1") {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // ==================== 特殊效果 ====================
        
        // 合唱
        if chorusEnabled {
            let depth = 0.3 + chorusDepth * 0.7
            if let ctx = createFilter(graph: graph, name: "chorus", label: "chorus",
                                       args: "in_gain=0.5:out_gain=0.9:delays=50|60|40:decays=\(String(format: "%.2f", depth))|\(String(format: "%.2f", depth * 0.8))|\(String(format: "%.2f", depth * 0.6)):speeds=0.25|0.4|0.3:depths=2|2.3|1.3") {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // 镶边
        if flangerEnabled {
            let depth = 2 + flangerDepth * 8
            if let ctx = createFilter(graph: graph, name: "flanger", label: "flanger",
                                       args: "delay=0:depth=\(String(format: "%.1f", depth)):regen=0:width=71:speed=0.5:shape=sinusoidal:phase=25:interp=linear") {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // 颤音
        if tremoloEnabled {
            if let ctx = createFilter(graph: graph, name: "tremolo", label: "tremolo",
                                       args: "f=\(String(format: "%.1f", tremoloFrequency)):d=\(String(format: "%.2f", tremoloDepth))") {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // 颤抖
        if vibratoEnabled {
            if let ctx = createFilter(graph: graph, name: "vibrato", label: "vibrato",
                                       args: "f=\(String(format: "%.1f", vibratoFrequency)):d=\(String(format: "%.2f", vibratoDepth))") {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // 失真（Lo-Fi）
        if crusherEnabled {
            if let ctx = createFilter(graph: graph, name: "acrusher", label: "crusher",
                                       args: "bits=\(String(format: "%.0f", crusherBits)):samples=\(String(format: "%.0f", crusherSamples)):mix=1") {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // 电话效果（300-3400Hz 带通）
        if telephoneEnabled {
            if let ctx = createFilter(graph: graph, name: "bandpass", label: "telephone",
                                       args: "frequency=1850:width_type=h:width=3100") {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // 水下效果（低通 + 混响）
        if underwaterEnabled {
            if let ctx = createFilter(graph: graph, name: "lowpass", label: "underwater_lp",
                                       args: "frequency=500") {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
            if let ctx = createFilter(graph: graph, name: "aecho", label: "underwater_echo",
                                       args: "in_gain=0.6:out_gain=0.8:delays=100|200:decays=0.4|0.3") {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // 收音机效果（带通 + 失真）
        if radioEnabled {
            if let ctx = createFilter(graph: graph, name: "bandpass", label: "radio_bp",
                                       args: "frequency=2000:width_type=h:width=3000") {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
            if let ctx = createFilter(graph: graph, name: "acrusher", label: "radio_crush",
                                       args: "bits=12:samples=2:mix=0.5") {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // ==================== 时间效果 ====================
        
        // 延迟
        if delayMs > 0.0 {
            if let ctx = createFilter(graph: graph, name: "adelay", label: "delay",
                                       args: "delays=\(String(format: "%.0f", delayMs))|0") {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // ==================== 速度与音调 ====================
        
        let effectiveTempo: Float
        if pitchSemitones != 0.0 {
            let pitchRatio = powf(2.0, pitchSemitones / 12.0)
            let newRate = Int(Float(sampleRate) * pitchRatio)
            if let ctx = createFilter(graph: graph, name: "asetrate", label: "pitch",
                                       args: "r=\(newRate)") {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
            effectiveTempo = tempo / pitchRatio
        } else {
            effectiveTempo = tempo
        }

        if effectiveTempo != 1.0 {
            var remaining = effectiveTempo
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

        // ==================== 淡入淡出 ====================
        
        if fadeInDuration > 0.0 {
            let samples = Int(fadeInDuration * Float(sampleRate))
            if let ctx = createFilter(graph: graph, name: "afade", label: "fadein",
                                       args: "type=in:start_sample=0:nb_samples=\(samples)") {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        if fadeOutDuration > 0.0 {
            let startSample = Int(fadeOutStartTime * Float(sampleRate))
            let nbSamples = Int(fadeOutDuration * Float(sampleRate))
            if let ctx = createFilter(graph: graph, name: "afade", label: "fadeout",
                                       args: "type=out:start_sample=\(startSample):nb_samples=\(nbSamples)") {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // ==================== 输出格式 ====================
        
        let aformatArgs = "sample_fmts=flt:sample_rates=\(sampleRate):channel_layouts=\(monoEnabled ? "mono" : (channelCount == 1 ? "mono" : "stereo"))"
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

// MARK: - 辅助函数

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
