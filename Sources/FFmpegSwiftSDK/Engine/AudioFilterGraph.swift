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
    private(set) var loudnormLRA: Float = 7.0      // LRA（响度范围），降低到 7 更保守
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
    
    // ==================== 新增：音频修复滤镜 ====================
    
    /// FFT 降噪（afftdn）
    private(set) var fftDenoiseEnabled: Bool = false
    private(set) var fftDenoiseAmount: Float = 10.0  // 降噪量（dB）
    
    /// 去除脉冲噪声（adeclick）
    private(set) var declickEnabled: Bool = false
    
    /// 去除削波失真（adeclip）
    private(set) var declipEnabled: Bool = false
    
    // ==================== 新增：动态处理滤镜 ====================
    
    /// 动态音频标准化（dynaudnorm）- 比 loudnorm 更适合实时
    private(set) var dynaudnormEnabled: Bool = false
    private(set) var dynaudnormFrameLen: Int = 500      // 帧长度（ms）
    private(set) var dynaudnormGaussSize: Int = 31      // 高斯窗口大小
    private(set) var dynaudnormPeak: Float = 0.95       // 目标峰值
    
    /// 语音标准化（speechnorm）
    private(set) var speechnormEnabled: Bool = false
    
    /// 压缩/扩展（compand）- 更灵活的动态控制
    private(set) var compandEnabled: Bool = false
    
    // ==================== 新增：空间音效滤镜 ====================
    
    /// Bauer 立体声转双耳（bs2b）- 改善耳机听感
    private(set) var bs2bEnabled: Bool = false
    private(set) var bs2bFcut: Int = 700       // 截止频率
    private(set) var bs2bFeed: Int = 50        // 馈送量（0.1dB 单位）
    
    /// 耳机交叉馈送（crossfeed）
    private(set) var crossfeedEnabled: Bool = false
    private(set) var crossfeedStrength: Float = 0.3
    
    /// Haas 效果（haas）- 增加空间感
    private(set) var haasEnabled: Bool = false
    private(set) var haasDelay: Float = 20.0   // 延迟（ms）
    
    /// 虚拟低音（virtualbass）
    private(set) var virtualbassEnabled: Bool = false
    private(set) var virtualbassCutoff: Float = 250.0
    private(set) var virtualbassStrength: Float = 3.0
    
    // ==================== 新增：音色处理滤镜 ====================
    
    /// 激励器（aexciter）- 增加高频泛音
    private(set) var exciterEnabled: Bool = false
    private(set) var exciterAmount: Float = 3.0   // 激励量（dB）
    private(set) var exciterFreq: Float = 7500.0  // 起始频率
    
    /// 软削波（asoftclip）- 温暖的失真
    private(set) var softclipEnabled: Bool = false
    private(set) var softclipType: Int = 0        // 0=tanh, 1=atan, 2=cubic, 3=exp, 4=alg, 5=quintic, 6=sin, 7=erf
    
    /// 对话增强（dialoguenhance）
    private(set) var dialogueEnhanceEnabled: Bool = false
    private(set) var dialogueEnhanceOriginal: Float = 1.0
    private(set) var dialogueEnhanceEnhance: Float = 1.0
    
    // ==================== 内部状态 ====================
    
    private var processedSamples: Int64 = 0
    private var sampleRate: Int = 0
    private var channelCount: Int = 0
    private var filterGraph: UnsafeMutablePointer<AVFilterGraph>?
    private var bufferSrcCtx: UnsafeMutablePointer<AVFilterContext>?
    private var bufferSinkCtx: UnsafeMutablePointer<AVFilterContext>?
    private var needsRebuild: Bool = true
    
    // 用于平滑过渡的交叉淡化缓冲
    private var crossfadeBuffer: [Float] = []
    private var crossfadeSamplesRemaining: Int = 0
    private let crossfadeDuration: Int = 256  // 交叉淡化采样数（约 5ms @ 48kHz）
    
    // 上一帧的最后几个采样，用于检测不连续
    private var lastOutputSamples: [Float] = []
    private let smoothingSamples: Int = 64  // 平滑采样数

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
               radioEnabled ||
               fftDenoiseEnabled ||
               declickEnabled ||
               declipEnabled ||
               dynaudnormEnabled ||
               speechnormEnabled ||
               compandEnabled ||
               bs2bEnabled ||
               crossfeedEnabled ||
               haasEnabled ||
               virtualbassEnabled ||
               exciterEnabled ||
               softclipEnabled ||
               dialogueEnhanceEnabled
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

    // MARK: - 新增：音频修复滤镜

    /// 启用/禁用 FFT 降噪
    func setFFTDenoiseEnabled(_ enabled: Bool) {
        lock.lock()
        if fftDenoiseEnabled != enabled {
            fftDenoiseEnabled = enabled
            needsRebuild = true
        }
        lock.unlock()
    }

    /// 设置 FFT 降噪参数
    func setFFTDenoiseAmount(_ amount: Float) {
        lock.lock()
        fftDenoiseAmount = max(0, min(100, amount))
        if fftDenoiseEnabled { needsRebuild = true }
        lock.unlock()
    }

    /// 启用/禁用去除脉冲噪声
    func setDeclickEnabled(_ enabled: Bool) {
        lock.lock()
        if declickEnabled != enabled {
            declickEnabled = enabled
            needsRebuild = true
        }
        lock.unlock()
    }

    /// 启用/禁用去除削波失真
    func setDeclipEnabled(_ enabled: Bool) {
        lock.lock()
        if declipEnabled != enabled {
            declipEnabled = enabled
            needsRebuild = true
        }
        lock.unlock()
    }

    // MARK: - 新增：动态处理滤镜

    /// 启用/禁用动态音频标准化
    func setDynaudnormEnabled(_ enabled: Bool) {
        lock.lock()
        if dynaudnormEnabled != enabled {
            dynaudnormEnabled = enabled
            needsRebuild = true
        }
        lock.unlock()
    }

    /// 设置动态音频标准化参数
    func setDynaudnormParams(frameLen: Int = 500, gaussSize: Int = 31, peak: Float = 0.95) {
        lock.lock()
        dynaudnormFrameLen = frameLen
        dynaudnormGaussSize = gaussSize
        dynaudnormPeak = peak
        if dynaudnormEnabled { needsRebuild = true }
        lock.unlock()
    }

    /// 启用/禁用语音标准化
    func setSpeechnormEnabled(_ enabled: Bool) {
        lock.lock()
        if speechnormEnabled != enabled {
            speechnormEnabled = enabled
            needsRebuild = true
        }
        lock.unlock()
    }

    /// 启用/禁用压缩/扩展
    func setCompandEnabled(_ enabled: Bool) {
        lock.lock()
        if compandEnabled != enabled {
            compandEnabled = enabled
            needsRebuild = true
        }
        lock.unlock()
    }

    // MARK: - 新增：空间音效滤镜

    /// 启用/禁用 Bauer 立体声转双耳
    func setBS2BEnabled(_ enabled: Bool) {
        lock.lock()
        if bs2bEnabled != enabled {
            bs2bEnabled = enabled
            needsRebuild = true
        }
        lock.unlock()
    }

    /// 设置 BS2B 参数
    func setBS2BParams(fcut: Int = 700, feed: Int = 50) {
        lock.lock()
        bs2bFcut = fcut
        bs2bFeed = feed
        if bs2bEnabled { needsRebuild = true }
        lock.unlock()
    }

    /// 启用/禁用耳机交叉馈送
    func setCrossfeedEnabled(_ enabled: Bool) {
        lock.lock()
        if crossfeedEnabled != enabled {
            crossfeedEnabled = enabled
            needsRebuild = true
        }
        lock.unlock()
    }

    /// 设置交叉馈送强度
    func setCrossfeedStrength(_ strength: Float) {
        lock.lock()
        crossfeedStrength = max(0, min(1, strength))
        if crossfeedEnabled { needsRebuild = true }
        lock.unlock()
    }

    /// 启用/禁用 Haas 效果
    func setHaasEnabled(_ enabled: Bool) {
        lock.lock()
        if haasEnabled != enabled {
            haasEnabled = enabled
            needsRebuild = true
        }
        lock.unlock()
    }

    /// 设置 Haas 延迟（ms）
    func setHaasDelay(_ delay: Float) {
        lock.lock()
        haasDelay = max(0, min(40, delay))
        if haasEnabled { needsRebuild = true }
        lock.unlock()
    }

    /// 启用/禁用虚拟低音
    func setVirtualbassEnabled(_ enabled: Bool) {
        lock.lock()
        if virtualbassEnabled != enabled {
            virtualbassEnabled = enabled
            needsRebuild = true
        }
        lock.unlock()
    }

    /// 设置虚拟低音参数
    func setVirtualbassParams(cutoff: Float = 250.0, strength: Float = 3.0) {
        lock.lock()
        virtualbassCutoff = cutoff
        virtualbassStrength = strength
        if virtualbassEnabled { needsRebuild = true }
        lock.unlock()
    }

    // MARK: - 新增：音色处理滤镜

    /// 启用/禁用激励器
    func setExciterEnabled(_ enabled: Bool) {
        lock.lock()
        if exciterEnabled != enabled {
            exciterEnabled = enabled
            needsRebuild = true
        }
        lock.unlock()
    }

    /// 设置激励器参数
    func setExciterParams(amount: Float = 3.0, freq: Float = 7500.0) {
        lock.lock()
        exciterAmount = amount
        exciterFreq = freq
        if exciterEnabled { needsRebuild = true }
        lock.unlock()
    }

    /// 启用/禁用软削波
    func setSoftclipEnabled(_ enabled: Bool) {
        lock.lock()
        if softclipEnabled != enabled {
            softclipEnabled = enabled
            needsRebuild = true
        }
        lock.unlock()
    }

    /// 设置软削波类型（0=tanh, 1=atan, 2=cubic, 3=exp, 4=alg, 5=quintic, 6=sin, 7=erf）
    func setSoftclipType(_ type: Int) {
        lock.lock()
        softclipType = max(0, min(7, type))
        if softclipEnabled { needsRebuild = true }
        lock.unlock()
    }

    /// 启用/禁用对话增强
    func setDialogueEnhanceEnabled(_ enabled: Bool) {
        lock.lock()
        if dialogueEnhanceEnabled != enabled {
            dialogueEnhanceEnabled = enabled
            needsRebuild = true
        }
        lock.unlock()
    }

    /// 设置对话增强参数
    func setDialogueEnhanceParams(original: Float = 1.0, enhance: Float = 1.0) {
        lock.lock()
        dialogueEnhanceOriginal = original
        dialogueEnhanceEnhance = enhance
        if dialogueEnhanceEnabled { needsRebuild = true }
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
        loudnormLRA = 7.0
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
        // 新增：音频修复滤镜
        fftDenoiseEnabled = false
        fftDenoiseAmount = 10.0
        declickEnabled = false
        declipEnabled = false
        // 新增：动态处理滤镜
        dynaudnormEnabled = false
        dynaudnormFrameLen = 500
        dynaudnormGaussSize = 31
        dynaudnormPeak = 0.95
        speechnormEnabled = false
        compandEnabled = false
        // 新增：空间音效滤镜
        bs2bEnabled = false
        bs2bFcut = 700
        bs2bFeed = 50
        crossfeedEnabled = false
        crossfeedStrength = 0.3
        haasEnabled = false
        haasDelay = 20.0
        virtualbassEnabled = false
        virtualbassCutoff = 250.0
        virtualbassStrength = 3.0
        // 新增：音色处理滤镜
        exciterEnabled = false
        exciterAmount = 3.0
        exciterFreq = 7500.0
        softclipEnabled = false
        softclipType = 0
        dialogueEnhanceEnabled = false
        dialogueEnhanceOriginal = 1.0
        dialogueEnhanceEnhance = 1.0
        // 状态
        processedSamples = 0
        needsRebuild = true
        lock.unlock()
        destroyGraph()
    }


    // MARK: - 处理

    /// 处理一个音频 buffer，返回滤镜处理后的结果。
    /// 如果没有激活的滤镜，直接返回原 buffer（零拷贝）。
    /// 
    /// 修复音频电流声问题：
    /// 1. 滤镜图重建时先 flush 旧图中的剩余帧
    /// 2. 使用交叉淡化平滑过渡
    /// 3. 检测并修复音频不连续
    func process(_ buffer: AudioBuffer) -> AudioBuffer {
        lock.lock()
        let active = checkAnyFilterActive()
        lock.unlock()

        guard active else { 
            // 清空交叉淡化状态
            lock.lock()
            crossfadeBuffer.removeAll()
            crossfadeSamplesRemaining = 0
            lastOutputSamples.removeAll()
            lock.unlock()
            return buffer 
        }

        lock.lock()

        processedSamples += Int64(buffer.frameCount)

        // 格式变化或参数变化时重建滤镜图
        let needsGraphRebuild = needsRebuild || sampleRate != buffer.sampleRate || channelCount != buffer.channelCount
        
        if needsGraphRebuild {
            // 保存旧图的最后输出用于交叉淡化
            if filterGraph != nil && !lastOutputSamples.isEmpty {
                crossfadeBuffer = lastOutputSamples
                crossfadeSamplesRemaining = crossfadeDuration
            }
            
            // Flush 旧滤镜图中的剩余帧（避免丢失数据）
            flushFilterGraphUnsafe()
            
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

        guard getResult >= 0 else {
            var ofp: UnsafeMutablePointer<AVFrame>? = outFrame
            av_frame_free(&ofp)
            lock.unlock()
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

        // 应用交叉淡化平滑过渡（修复滤镜图重建时的电流声）
        if crossfadeSamplesRemaining > 0 && !crossfadeBuffer.isEmpty {
            applyCrossfadeUnsafe(outData, frameCount: outFrameCount, channelCount: outChannels)
        }
        
        // 应用平滑处理（修复音频不连续导致的爆音）
        applySmoothingUnsafe(outData, frameCount: outFrameCount, channelCount: outChannels)
        
        // 保存最后几个采样用于下次平滑
        saveLastSamplesUnsafe(outData, frameCount: outFrameCount, channelCount: outChannels)
        
        lock.unlock()

        return AudioBuffer(
            data: outData,
            frameCount: outFrameCount,
            channelCount: outChannels,
            sampleRate: outRate
        )
    }
    
    /// Flush 滤镜图中的剩余帧（在 lock 内调用）
    private func flushFilterGraphUnsafe() {
        guard let srcCtx = bufferSrcCtx, let sinkCtx = bufferSinkCtx else { return }
        
        // 发送 EOF 信号给滤镜图
        av_buffersrc_add_frame(srcCtx, nil)
        
        // 取出所有剩余帧（丢弃，但这样可以清空滤镜内部缓冲）
        let flushFrame = av_frame_alloc()
        if let frame = flushFrame {
            while av_buffersink_get_frame(sinkCtx, frame) >= 0 {
                av_frame_unref(frame)
            }
            var fp: UnsafeMutablePointer<AVFrame>? = frame
            av_frame_free(&fp)
        }
    }
    
    /// 应用交叉淡化（在 lock 内调用）
    private func applyCrossfadeUnsafe(_ data: UnsafeMutablePointer<Float>, frameCount: Int, channelCount: Int) {
        let samplesToFade = min(crossfadeSamplesRemaining, frameCount)
        let fadeBufferChannels = crossfadeBuffer.count / smoothingSamples
        
        guard fadeBufferChannels == channelCount else {
            crossfadeBuffer.removeAll()
            crossfadeSamplesRemaining = 0
            return
        }
        
        for i in 0..<samplesToFade {
            let fadeProgress = Float(crossfadeDuration - crossfadeSamplesRemaining + i) / Float(crossfadeDuration)
            let newWeight = fadeProgress
            let oldWeight = 1.0 - fadeProgress
            
            for ch in 0..<channelCount {
                let idx = i * channelCount + ch
                let oldIdx = min(i, smoothingSamples - 1) * channelCount + ch
                
                if oldIdx < crossfadeBuffer.count {
                    data[idx] = data[idx] * newWeight + crossfadeBuffer[oldIdx] * oldWeight
                }
            }
        }
        
        crossfadeSamplesRemaining -= samplesToFade
        if crossfadeSamplesRemaining <= 0 {
            crossfadeBuffer.removeAll()
        }
    }
    
    /// 应用平滑处理，修复帧边界不连续（在 lock 内调用）
    private func applySmoothingUnsafe(_ data: UnsafeMutablePointer<Float>, frameCount: Int, channelCount: Int) {
        guard !lastOutputSamples.isEmpty, lastOutputSamples.count == channelCount else { return }
        
        // 检测第一个采样与上一帧最后采样的差异
        var maxDiff: Float = 0
        for ch in 0..<channelCount {
            let diff = abs(data[ch] - lastOutputSamples[ch])
            maxDiff = max(maxDiff, diff)
        }
        
        // 如果差异过大（可能产生爆音），应用短时平滑
        let threshold: Float = 0.3  // 约 -10dB 的跳变
        if maxDiff > threshold {
            let smoothSamples = min(32, frameCount)
            for i in 0..<smoothSamples {
                let weight = Float(i) / Float(smoothSamples)
                for ch in 0..<channelCount {
                    let idx = i * channelCount + ch
                    data[idx] = data[idx] * weight + lastOutputSamples[ch] * (1.0 - weight)
                }
            }
        }
    }
    
    /// 保存最后几个采样（在 lock 内调用）
    private func saveLastSamplesUnsafe(_ data: UnsafeMutablePointer<Float>, frameCount: Int, channelCount: Int) {
        let samplesToSave = min(smoothingSamples, frameCount)
        let startIdx = (frameCount - samplesToSave) * channelCount
        
        lastOutputSamples = Array(UnsafeBufferPointer(start: data + startIdx, count: samplesToSave * channelCount))
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
        // 使用 linear=true 模式，避免实时处理时的 pumping 效果
        // dual_mono=true 对单声道内容更友好
        // offset=0 不额外调整偏移
        if loudnormEnabled {
            let args = "I=\(String(format: "%.1f", loudnormTarget)):LRA=\(String(format: "%.1f", loudnormLRA)):TP=\(String(format: "%.1f", loudnormTP)):linear=true:dual_mono=true:print_format=none"
            if let ctx = createFilter(graph: graph, name: "loudnorm", label: "loudnorm", args: args) {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // 动态音频标准化（dynaudnorm）- 比 loudnorm 更适合实时处理
        if dynaudnormEnabled {
            let args = "framelen=\(dynaudnormFrameLen):gausssize=\(dynaudnormGaussSize):peak=\(String(format: "%.2f", dynaudnormPeak))"
            if let ctx = createFilter(graph: graph, name: "dynaudnorm", label: "dynaudnorm", args: args) {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // 语音标准化（speechnorm）- 专为语音内容优化
        if speechnormEnabled {
            if let ctx = createFilter(graph: graph, name: "speechnorm", label: "speechnorm", args: "e=12.5:r=0.0001:l=1") {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // 压缩/扩展（compand）- 更灵活的动态控制
        if compandEnabled {
            // 默认参数：轻度压缩，适合音乐
            let args = "attacks=0.3:decays=0.8:points=-80/-80|-45/-45|-27/-25|0/-10:soft-knee=6:gain=5"
            if let ctx = createFilter(graph: graph, name: "compand", label: "compand", args: args) {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // ==================== 音频修复滤镜 ====================

        // FFT 降噪（afftdn）- 基于 FFT 的降噪
        if fftDenoiseEnabled {
            let args = "nr=\(String(format: "%.0f", fftDenoiseAmount)):nf=-25:tn=1"
            if let ctx = createFilter(graph: graph, name: "afftdn", label: "afftdn", args: args) {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // 去除脉冲噪声（adeclick）
        if declickEnabled {
            if let ctx = createFilter(graph: graph, name: "adeclick", label: "adeclick", args: "w=55:o=75") {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // 去除削波失真（adeclip）
        if declipEnabled {
            if let ctx = createFilter(graph: graph, name: "adeclip", label: "adeclip", args: "w=55:o=75") {
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

        // 环绕增强（使用 stereotools 替代 extrastereo，更平滑）
        if surroundLevel > 0.0 && channelCount == 2 {
            // stereotools 的 sbal 参数控制立体声宽度，范围 -1 到 1
            // 0 = 原始，正值增加分离度
            let sbal = surroundLevel * 0.5  // 最大 0.5，避免失真
            let args = "mode=lr>lr:sbal=\(String(format: "%.2f", sbal))"
            if let ctx = createFilter(graph: graph, name: "stereotools", label: "surround", args: args) {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // 混响（使用更平滑的参数，减少电流声）
        if reverbLevel > 0.0 {
            // 使用更长的延迟和更低的增益，避免金属感
            let decay = 0.15 + reverbLevel * 0.35  // 更保守的衰减
            let wetGain = 0.3 + reverbLevel * 0.4  // 湿信号增益
            let dryGain = 1.0 - reverbLevel * 0.3  // 干信号保留更多
            // 使用多个延迟点创建更自然的混响
            let args = "in_gain=\(String(format: "%.2f", dryGain)):out_gain=\(String(format: "%.2f", wetGain)):delays=40|80|120|160:decays=\(String(format: "%.2f", decay))|\(String(format: "%.2f", decay * 0.8))|\(String(format: "%.2f", decay * 0.6))|\(String(format: "%.2f", decay * 0.4))"
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

        // ==================== 新增：空间音效滤镜 ====================

        // Bauer 立体声转双耳（bs2b）- 改善耳机听感
        if bs2bEnabled && channelCount == 2 {
            let args = "fcut=\(bs2bFcut):feed=\(bs2bFeed)"
            if let ctx = createFilter(graph: graph, name: "bs2b", label: "bs2b", args: args) {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // 耳机交叉馈送（crossfeed）- 使用 stereotools 实现
        if crossfeedEnabled && channelCount == 2 {
            // 使用 stereotools 的 balance 参数模拟交叉馈送
            let args = "balance_in=\(String(format: "%.2f", crossfeedStrength)):balance_out=\(String(format: "%.2f", crossfeedStrength * 0.5))"
            if let ctx = createFilter(graph: graph, name: "stereotools", label: "crossfeed", args: args) {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // Haas 效果（haas）- 增加空间感
        if haasEnabled && channelCount == 2 {
            let args = "level_in=1:level_out=1:side_gain=1:middle_source=mid:middle_phase=false:left_delay=\(String(format: "%.1f", haasDelay)):left_balance=-1:left_gain=1:left_phase=false:right_delay=0:right_balance=1:right_gain=1:right_phase=false"
            if let ctx = createFilter(graph: graph, name: "haas", label: "haas", args: args) {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // 虚拟低音（virtualbass）- 通过谐波生成低音感
        if virtualbassEnabled {
            let args = "cutoff=\(String(format: "%.0f", virtualbassCutoff)):strength=\(String(format: "%.1f", virtualbassStrength))"
            if let ctx = createFilter(graph: graph, name: "virtualbass", label: "virtualbass", args: args) {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // ==================== 新增：音色处理滤镜 ====================

        // 激励器（aexciter）- 增加高频泛音
        if exciterEnabled {
            let args = "level_in=1:level_out=1:amount=\(String(format: "%.1f", exciterAmount)):drive=1:blend=0:freq=\(String(format: "%.0f", exciterFreq)):ceil=9999:listen=false"
            if let ctx = createFilter(graph: graph, name: "aexciter", label: "aexciter", args: args) {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // 软削波（asoftclip）- 温暖的失真
        if softclipEnabled {
            let typeNames = ["tanh", "atan", "cubic", "exp", "alg", "quintic", "sin", "erf"]
            let typeName = typeNames[min(softclipType, typeNames.count - 1)]
            let args = "type=\(typeName):threshold=1:output=1:param=1:oversample=1"
            if let ctx = createFilter(graph: graph, name: "asoftclip", label: "asoftclip", args: args) {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // 对话增强（dialoguenhance）- 增强人声清晰度
        if dialogueEnhanceEnabled && channelCount == 2 {
            let args = "original=\(String(format: "%.1f", dialogueEnhanceOriginal)):enhance=\(String(format: "%.1f", dialogueEnhanceEnhance))"
            if let ctx = createFilter(graph: graph, name: "dialoguenhance", label: "dialoguenhance", args: args) {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // ==================== 特殊效果 ====================
        
        // 合唱（使用更平滑的参数）
        if chorusEnabled {
            // 降低深度和速度，使用更保守的参数避免电流声
            let depth = 0.2 + chorusDepth * 0.4  // 更保守的深度
            let args = "in_gain=0.6:out_gain=0.8:delays=25|35|45:decays=\(String(format: "%.2f", depth))|\(String(format: "%.2f", depth * 0.85))|\(String(format: "%.2f", depth * 0.7)):speeds=0.2|0.25|0.3:depths=1.5|1.8|1.2"
            if let ctx = createFilter(graph: graph, name: "chorus", label: "chorus", args: args) {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // 镶边（使用更平滑的参数）
        if flangerEnabled {
            // 降低深度和 regen，使用更平滑的插值
            let depth = 1.5 + flangerDepth * 4.0  // 更保守的深度
            let args = "delay=1:depth=\(String(format: "%.1f", depth)):regen=0:width=50:speed=0.3:shape=sinusoidal:phase=50:interp=quadratic"
            if let ctx = createFilter(graph: graph, name: "flanger", label: "flanger", args: args) {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // 颤音（优化参数，减少电流声）
        if tremoloEnabled {
            // 使用更平滑的深度参数
            let smoothDepth = tremoloDepth * 0.7  // 降低最大深度
            let args = "f=\(String(format: "%.1f", tremoloFrequency)):d=\(String(format: "%.2f", smoothDepth))"
            if let ctx = createFilter(graph: graph, name: "tremolo", label: "tremolo", args: args) {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // 颤抖（优化参数）
        if vibratoEnabled {
            // 使用更保守的深度
            let smoothDepth = vibratoDepth * 0.6
            let args = "f=\(String(format: "%.1f", vibratoFrequency)):d=\(String(format: "%.2f", smoothDepth))"
            if let ctx = createFilter(graph: graph, name: "vibrato", label: "vibrato", args: args) {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // 失真（Lo-Fi，优化参数减少刺耳感）
        if crusherEnabled {
            // 使用更高的位深和更低的采样降低因子
            let smoothBits = max(crusherBits, 6.0)  // 最低 6 位，避免太刺耳
            let smoothSamples = min(crusherSamples, 8.0)  // 最高 8x 降采样
            let args = "bits=\(String(format: "%.0f", smoothBits)):samples=\(String(format: "%.0f", smoothSamples)):mix=0.8"
            if let ctx = createFilter(graph: graph, name: "acrusher", label: "crusher", args: args) {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // 电话效果（300-3400Hz 带通，优化参数）
        if telephoneEnabled {
            // 使用更平滑的滤波器
            let args = "frequency=1850:width_type=h:width=2800:poles=2"
            if let ctx = createFilter(graph: graph, name: "bandpass", label: "telephone", args: args) {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // 水下效果（低通 + 混响，使用更平滑的参数）
        if underwaterEnabled {
            // 使用更高的截止频率和更平滑的混响
            if let ctx = createFilter(graph: graph, name: "lowpass", label: "underwater_lp",
                                       args: "frequency=600:poles=2") {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
            // 更自然的水下回声
            if let ctx = createFilter(graph: graph, name: "aecho", label: "underwater_echo",
                                       args: "in_gain=0.7:out_gain=0.7:delays=60|120|180:decays=0.35|0.25|0.15") {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
        }

        // 收音机效果（带通 + 轻微失真，优化参数）
        if radioEnabled {
            // 使用更自然的带通
            let args1 = "frequency=1800:width_type=h:width=2500:poles=2"
            if let ctx = createFilter(graph: graph, name: "bandpass", label: "radio_bp", args: args1) {
                guard avfilter_link(lastCtx, 0, ctx, 0) >= 0 else { destroyGraphUnsafe(); return }
                lastCtx = ctx
            }
            // 更轻微的失真
            let args2 = "bits=10:samples=2:mix=0.4"
            if let ctx = createFilter(graph: graph, name: "acrusher", label: "radio_crush", args: args2) {
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
