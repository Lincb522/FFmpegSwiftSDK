// AudioRepairEngine.swift
// FFmpegSwiftSDK
//
// 音频修复引擎：在所有音效处理之后、输出到硬件之前，
// 自动检测并修复各种音频问题。
//
// 修复能力：
// 1. 削波修复（Declip）：检测并插值重建被削波的波形
// 2. 电流声消除（DC Offset + 高频噪声）：去除直流偏移和超高频噪声
// 3. 卡顿平滑（Gap Smoothing）：检测并填补音频间隙
// 4. 重叠消除（Overlap Removal）：检测并修复音频帧重叠
// 5. 爆音抑制（Pop/Click Removal）：检测并平滑突发脉冲
// 6. 采样率不匹配平滑：处理不同采样率之间的过渡
// 7. 软限幅（Soft Limiter）：防止输出超过 0dBFS
// 8. 抖动（Dither）：量化噪声整形，提升低电平信号质量
//
// 设计原则：
// - 调用极简：只需 enable/disable，内部全自动
// - 零延迟：所有处理在当前帧内完成
// - 低开销：只在检测到问题时才执行修复

import Foundation
import Accelerate

/// 音频修复引擎
///
/// 在音频输出链路的最末端工作，自动检测并修复各种音频瑕疵。
/// 所有修复模块可独立开关，也可一键全部启用。
///
/// 使用方式：
/// ```swift
/// let engine = AudioRepairEngine()
/// engine.enableAll()  // 一键启用所有修复
/// // 或者按需启用
/// engine.isDeclipEnabled = true
/// engine.isSoftLimiterEnabled = true
/// ```
public final class AudioRepairEngine {

    // MARK: - 修复模块开关

    /// 削波修复：检测并重建被削波的波形
    public var isDeclipEnabled: Bool = false

    /// 电流声消除：去除 DC 偏移 + 超高频噪声
    public var isDenoiseEnabled: Bool = false

    /// 卡顿平滑：检测并填补音频间隙（连续静音帧）
    public var isGapSmoothingEnabled: Bool = false

    /// 重叠消除：检测并修复音频帧重叠导致的相位问题
    public var isOverlapRemovalEnabled: Bool = false

    /// 爆音抑制：检测并平滑突发脉冲（pop/click）
    public var isPopRemovalEnabled: Bool = false

    /// 软限幅：防止输出超过 0dBFS，使用 tanh 曲线柔和限幅
    public var isSoftLimiterEnabled: Bool = false

    /// 抖动：在低电平信号中添加三角概率密度抖动，改善量化质量
    public var isDitherEnabled: Bool = false

    /// 淡入保护：播放开始时自动淡入，避免开头爆音
    public var isFadeInProtectionEnabled: Bool = false

    /// 是否有任何修复模块启用
    public var isActive: Bool {
        return isDeclipEnabled || isDenoiseEnabled || isGapSmoothingEnabled ||
               isOverlapRemovalEnabled || isPopRemovalEnabled || isSoftLimiterEnabled ||
               isDitherEnabled || isFadeInProtectionEnabled
    }

    // MARK: - 可调参数

    /// 削波检测阈值（0~1），超过此值视为削波。默认 0.98
    public var clipThreshold: Float = 0.98

    /// 爆音检测灵敏度（采样间差值阈值）。默认 0.3
    public var popSensitivity: Float = 0.3

    /// 软限幅阈值（0~1）。默认 0.95
    public var limiterThreshold: Float = 0.95

    /// 淡入保护时长（采样数）。默认 256（约 5ms @ 48kHz）
    public var fadeInSamples: Int = 256

    // MARK: - 内部状态

    private let lock = NSLock()

    // DC 偏移滤波器状态（每声道）
    private var dcFilterState: [DCBlockerState] = []

    // 上一帧的尾部采样（用于跨帧检测）
    private var previousTail: [Float] = []
    private let tailLength: Int = 64

    // 爆音检测的上一个采样值（每声道）
    private var lastSamples: [Float] = []

    // 淡入保护计数器
    private var fadeInCounter: Int = 0
    private var fadeInActive: Bool = true

    // 抖动状态
    private var ditherState: Float = 0

    // 帧计数（用于统计）
    private var frameCount: Int64 = 0

    // 修复统计
    private var stats = RepairStats()

    // MARK: - DC 偏移滤波器状态

    private struct DCBlockerState {
        var xPrev: Float = 0
        var yPrev: Float = 0
    }

    // MARK: - 修复统计

    /// 修复统计信息
    public struct RepairStats {
        /// 修复的削波采样数
        public var clippedSamplesRepaired: Int = 0
        /// 消除的爆音数
        public var popsRemoved: Int = 0
        /// 填补的间隙数
        public var gapsFilled: Int = 0
        /// 修复的重叠帧数
        public var overlapsFixed: Int = 0
        /// 软限幅触发次数
        public var limiterActivations: Int = 0
        /// 总处理帧数
        public var totalFramesProcessed: Int64 = 0
    }

    /// 获取当前修复统计
    public var repairStats: RepairStats {
        lock.lock()
        let s = stats
        lock.unlock()
        return s
    }

    /// 重置统计
    public func resetStats() {
        lock.lock()
        stats = RepairStats()
        lock.unlock()
    }

    // MARK: - 初始化

    public init() {}

    // MARK: - 一键操作

    /// 启用所有修复模块（推荐）
    public func enableAll() {
        isDeclipEnabled = true
        isDenoiseEnabled = true
        isGapSmoothingEnabled = true
        isOverlapRemovalEnabled = true
        isPopRemovalEnabled = true
        isSoftLimiterEnabled = true
        isDitherEnabled = true
        isFadeInProtectionEnabled = true
    }

    /// 禁用所有修复模块
    public func disableAll() {
        isDeclipEnabled = false
        isDenoiseEnabled = false
        isGapSmoothingEnabled = false
        isOverlapRemovalEnabled = false
        isPopRemovalEnabled = false
        isSoftLimiterEnabled = false
        isDitherEnabled = false
        isFadeInProtectionEnabled = false
    }

    /// 重置所有内部状态（切歌时调用）
    public func reset() {
        lock.lock()
        dcFilterState.removeAll()
        previousTail.removeAll()
        lastSamples.removeAll()
        fadeInCounter = 0
        fadeInActive = true
        ditherState = 0
        frameCount = 0
        lock.unlock()
    }

    // MARK: - 核心处理

    /// 处理一帧音频数据，自动检测并修复问题
    ///
    /// 在 AudioRenderer 的 render callback 中调用，
    /// 位于 AudioFilterGraph 和 EQFilter 之后。
    ///
    /// - Parameters:
    ///   - data: 音频采样数据指针（Float32 交错格式），原地修改
    ///   - frameCount: 帧数
    ///   - channelCount: 声道数
    ///   - sampleRate: 采样率
    public func process(
        _ data: UnsafeMutablePointer<Float>,
        frameCount: Int,
        channelCount: Int,
        sampleRate: Int
    ) {
        guard isActive, frameCount > 0, channelCount > 0 else { return }

        let totalSamples = frameCount * channelCount

        lock.lock()

        // 确保状态数组大小正确
        ensureStateSize(channelCount: channelCount)

        frameCount_internal_update(frameCount)

        // === 修复流水线（顺序很重要） ===

        // 1. 淡入保护（最先执行，避免开头爆音）
        if isFadeInProtectionEnabled {
            applyFadeInProtection(data, totalSamples: totalSamples, channelCount: channelCount)
        }

        // 2. DC 偏移消除（去除直流分量，这是电流声的主要来源之一）
        if isDenoiseEnabled {
            applyDCBlocker(data, frameCount: frameCount, channelCount: channelCount)
        }

        // 3. 爆音/脉冲检测与修复（在其他处理之前，避免爆音被放大）
        if isPopRemovalEnabled {
            applyPopRemoval(data, frameCount: frameCount, channelCount: channelCount)
        }

        // 4. 卡顿平滑（检测连续静音并用前一帧尾部平滑过渡）
        if isGapSmoothingEnabled {
            applyGapSmoothing(data, frameCount: frameCount, channelCount: channelCount)
        }

        // 5. 重叠消除（检测与前一帧的波形重叠并修复）
        if isOverlapRemovalEnabled {
            applyOverlapRemoval(data, frameCount: frameCount, channelCount: channelCount)
        }

        // 6. 削波修复（检测并插值重建被削波的波形）
        if isDeclipEnabled {
            applyDeclip(data, frameCount: frameCount, channelCount: channelCount)
        }

        // 7. 超高频噪声滤除（简单的一阶低通，去除 > 20kHz 的噪声）
        if isDenoiseEnabled {
            applyUltrasonicFilter(data, frameCount: frameCount, channelCount: channelCount, sampleRate: sampleRate)
        }

        // 8. 软限幅（最后执行，确保输出不超过 0dBFS）
        if isSoftLimiterEnabled {
            applySoftLimiter(data, totalSamples: totalSamples)
        }

        // 9. 抖动（在限幅之后，量化之前）
        if isDitherEnabled {
            applyDither(data, totalSamples: totalSamples)
        }

        // 保存尾部采样用于下一帧的跨帧检测
        saveTail(data, frameCount: frameCount, channelCount: channelCount)

        stats.totalFramesProcessed += Int64(frameCount)

        lock.unlock()
    }

    // MARK: - 内部帧计数

    private func frameCount_internal_update(_ count: Int) {
        frameCount += Int64(count)
    }

    // MARK: - 状态管理

    private func ensureStateSize(channelCount: Int) {
        if dcFilterState.count != channelCount {
            dcFilterState = Array(repeating: DCBlockerState(), count: channelCount)
        }
        if lastSamples.count != channelCount {
            lastSamples = Array(repeating: 0, count: channelCount)
        }
    }

    private func saveTail(_ data: UnsafeMutablePointer<Float>, frameCount: Int, channelCount: Int) {
        let samplesToSave = min(tailLength, frameCount) * channelCount
        let startIdx = (frameCount - min(tailLength, frameCount)) * channelCount
        previousTail = Array(UnsafeBufferPointer(start: data + startIdx, count: samplesToSave))
    }

    // MARK: - 1. 淡入保护

    /// 播放开始或 seek 后自动淡入，避免开头爆音
    private func applyFadeInProtection(
        _ data: UnsafeMutablePointer<Float>,
        totalSamples: Int,
        channelCount: Int
    ) {
        guard fadeInActive else { return }

        let totalFrames = totalSamples / channelCount
        for frame in 0..<totalFrames {
            if fadeInCounter >= fadeInSamples {
                fadeInActive = false
                break
            }
            // 使用 S 曲线（smoothstep）淡入，比线性更自然
            let t = Float(fadeInCounter) / Float(fadeInSamples)
            let gain = t * t * (3.0 - 2.0 * t)  // smoothstep
            for ch in 0..<channelCount {
                data[frame * channelCount + ch] *= gain
            }
            fadeInCounter += 1
        }
    }

    // MARK: - 2. DC 偏移消除

    /// 使用一阶高通滤波器去除直流偏移（电流声的主要来源）
    ///
    /// 传递函数: y[n] = x[n] - x[n-1] + R * y[n-1]
    /// R = 0.9975 对应约 3Hz 的截止频率 @ 48kHz
    private func applyDCBlocker(
        _ data: UnsafeMutablePointer<Float>,
        frameCount: Int,
        channelCount: Int
    ) {
        let R: Float = 0.9975  // 极点位置，越接近 1 截止频率越低

        for ch in 0..<channelCount {
            var xPrev = dcFilterState[ch].xPrev
            var yPrev = dcFilterState[ch].yPrev

            for frame in 0..<frameCount {
                let idx = frame * channelCount + ch
                let x = data[idx]
                let y = x - xPrev + R * yPrev
                data[idx] = y
                xPrev = x
                yPrev = y
            }

            dcFilterState[ch].xPrev = xPrev
            dcFilterState[ch].yPrev = yPrev
        }
    }

    // MARK: - 3. 爆音/脉冲检测与修复

    /// 检测相邻采样之间的异常跳变（pop/click），用线性插值修复
    ///
    /// 原理：正常音频信号的相邻采样差值有限（取决于频率和振幅），
    /// 如果差值超过阈值，说明可能是脉冲噪声或帧边界不连续。
    private func applyPopRemoval(
        _ data: UnsafeMutablePointer<Float>,
        frameCount: Int,
        channelCount: Int
    ) {
        for ch in 0..<channelCount {
            var prev = lastSamples[ch]

            for frame in 0..<frameCount {
                let idx = frame * channelCount + ch
                let current = data[idx]
                let diff = abs(current - prev)

                if diff > popSensitivity {
                    // 检测到爆音，使用三点中值滤波修复
                    if frame > 0 && frame < frameCount - 1 {
                        let prevSample = data[(frame - 1) * channelCount + ch]
                        let nextSample = data[(frame + 1) * channelCount + ch]
                        // 中值滤波：取三个值的中间值
                        data[idx] = median3(prevSample, current, nextSample)
                    } else if frame == 0 {
                        // 第一个采样：与前一帧尾部平滑过渡
                        data[idx] = prev * 0.7 + current * 0.3
                    }
                    stats.popsRemoved += 1
                }

                prev = data[idx]
            }

            lastSamples[ch] = prev
        }
    }

    /// 三值中值
    private func median3(_ a: Float, _ b: Float, _ c: Float) -> Float {
        if a > b {
            if b > c { return b }
            else if a > c { return c }
            else { return a }
        } else {
            if a > c { return a }
            else if b > c { return c }
            else { return b }
        }
    }

    // MARK: - 4. 卡顿平滑

    /// 检测连续静音帧（可能是缓冲区欠载导致的卡顿），
    /// 用前一帧的尾部数据做交叉淡化填补
    private func applyGapSmoothing(
        _ data: UnsafeMutablePointer<Float>,
        frameCount: Int,
        channelCount: Int
    ) {
        // 检测帧开头是否全是静音（可能是 gap）
        let checkSamples = min(32, frameCount)
        var maxAbs: Float = 0
        for i in 0..<(checkSamples * channelCount) {
            maxAbs = max(maxAbs, abs(data[i]))
        }

        // 如果开头几乎全是静音，且前一帧有数据，做交叉淡化
        let silenceThreshold: Float = 0.0001
        if maxAbs < silenceThreshold && !previousTail.isEmpty {
            let tailFrames = previousTail.count / channelCount
            let fadeFrames = min(tailFrames, min(32, frameCount))

            for frame in 0..<fadeFrames {
                let fadeOut = Float(fadeFrames - frame) / Float(fadeFrames)
                let tailFrame = tailFrames - fadeFrames + frame
                for ch in 0..<channelCount {
                    let tailIdx = tailFrame * channelCount + ch
                    let dataIdx = frame * channelCount + ch
                    if tailIdx < previousTail.count {
                        // 用前一帧尾部的衰减信号填补
                        data[dataIdx] = previousTail[tailIdx] * fadeOut * 0.5
                    }
                }
            }
            stats.gapsFilled += 1
        }
    }

    // MARK: - 5. 重叠消除

    /// 检测当前帧开头与前一帧尾部的波形重叠，
    /// 通过交叉淡化消除重叠导致的相位叠加（音量突增/失真）
    private func applyOverlapRemoval(
        _ data: UnsafeMutablePointer<Float>,
        frameCount: Int,
        channelCount: Int
    ) {
        guard !previousTail.isEmpty else { return }

        let tailFrames = previousTail.count / channelCount
        let compareFrames = min(16, min(tailFrames, frameCount))

        // 计算前一帧尾部和当前帧开头的相关性
        var correlation: Float = 0
        var energy1: Float = 0
        var energy2: Float = 0

        for frame in 0..<compareFrames {
            for ch in 0..<channelCount {
                let tailIdx = (tailFrames - compareFrames + frame) * channelCount + ch
                let dataIdx = frame * channelCount + ch
                if tailIdx < previousTail.count {
                    let a = previousTail[tailIdx]
                    let b = data[dataIdx]
                    correlation += a * b
                    energy1 += a * a
                    energy2 += b * b
                }
            }
        }

        let denominator = sqrtf(energy1 * energy2)
        let normalizedCorr = denominator > 0 ? correlation / denominator : 0

        // 如果相关性很高（> 0.8），说明可能有重叠
        if normalizedCorr > 0.8 {
            // 应用短交叉淡化消除重叠
            let fadeFrames = min(16, frameCount)
            for frame in 0..<fadeFrames {
                let fadeIn = Float(frame) / Float(fadeFrames)
                for ch in 0..<channelCount {
                    let idx = frame * channelCount + ch
                    data[idx] *= fadeIn
                }
            }
            stats.overlapsFixed += 1
        }
    }
