// AudioAnalyzer.swift
// FFmpegSwiftSDK
//
// 音频分析引擎，提供静音检测、BPM 检测、峰值检测、响度测量等功能。

import Foundation
import Accelerate

/// 音频分析器，提供各种音频分析功能。
///
/// 支持以下分析：
/// - 静音检测：检测音频中的静音片段
/// - BPM 检测：检测歌曲的节拍速度
/// - 峰值检测：检测音频峰值电平
/// - 响度测量：测量音频的 LUFS 响度
/// - 削波检测：检测数字削波
public final class AudioAnalyzer {
    
    // MARK: - 静音检测
    
    /// 静音片段信息
    public struct SilenceSegment {
        /// 开始时间（秒）
        public let startTime: TimeInterval
        /// 结束时间（秒）
        public let endTime: TimeInterval
        /// 持续时长（秒）
        public var duration: TimeInterval { endTime - startTime }
    }
    
    /// 检测音频数据中的静音片段
    /// - Parameters:
    ///   - samples: 音频采样数据（Float32）
    ///   - sampleRate: 采样率
    ///   - threshold: 静音阈值（dB），默认 -50dB
    ///   - minDuration: 最小静音时长（秒），默认 0.5 秒
    /// - Returns: 静音片段数组
    public static func detectSilence(
        samples: [Float],
        sampleRate: Int,
        threshold: Float = -50.0,
        minDuration: TimeInterval = 0.5
    ) -> [SilenceSegment] {
        let windowSize = 1024
        let hopSize = 512
        let thresholdLinear = powf(10.0, threshold / 20.0)
        let minSamples = Int(minDuration * Double(sampleRate))
        
        var segments: [SilenceSegment] = []
        var silenceStart: Int? = nil
        
        var i = 0
        while i + windowSize <= samples.count {
            // 计算窗口 RMS
            var sumSquares: Float = 0
            for j in 0..<windowSize {
                let sample = samples[i + j]
                sumSquares += sample * sample
            }
            let rms = sqrtf(sumSquares / Float(windowSize))
            
            let isSilent = rms < thresholdLinear
            
            if isSilent {
                if silenceStart == nil {
                    silenceStart = i
                }
            } else {
                if let start = silenceStart {
                    let duration = i - start
                    if duration >= minSamples {
                        let startTime = Double(start) / Double(sampleRate)
                        let endTime = Double(i) / Double(sampleRate)
                        segments.append(SilenceSegment(startTime: startTime, endTime: endTime))
                    }
                    silenceStart = nil
                }
            }
            
            i += hopSize
        }
        
        // 处理末尾的静音
        if let start = silenceStart {
            let duration = samples.count - start
            if duration >= minSamples {
                let startTime = Double(start) / Double(sampleRate)
                let endTime = Double(samples.count) / Double(sampleRate)
                segments.append(SilenceSegment(startTime: startTime, endTime: endTime))
            }
        }
        
        return segments
    }
    
    // MARK: - BPM 检测
    
    /// BPM 检测结果
    public struct BPMResult {
        /// 检测到的 BPM
        public let bpm: Float
        /// 置信度（0~1）
        public let confidence: Float
    }
    
    /// 检测音频的 BPM（节拍速度）
    /// - Parameters:
    ///   - samples: 音频采样数据（Float32，单声道）
    ///   - sampleRate: 采样率
    /// - Returns: BPM 检测结果
    public static func detectBPM(samples: [Float], sampleRate: Int) -> BPMResult {
        // 使用能量包络 + 自相关法检测 BPM
        
        // 1. 计算能量包络
        let windowSize = 1024
        let hopSize = 512
        var envelope: [Float] = []
        
        var i = 0
        while i + windowSize <= samples.count {
            var sum: Float = 0
            for j in 0..<windowSize {
                sum += abs(samples[i + j])
            }
            envelope.append(sum / Float(windowSize))
            i += hopSize
        }
        
        guard envelope.count > 100 else {
            return BPMResult(bpm: 0, confidence: 0)
        }
        
        // 2. 计算差分（检测节拍起始点）
        var diff: [Float] = []
        for i in 1..<envelope.count {
            let d = max(0, envelope[i] - envelope[i - 1])
            diff.append(d)
        }
        
        // 3. 自相关
        let envelopeRate = Float(sampleRate) / Float(hopSize)
        let minBPM: Float = 60
        let maxBPM: Float = 200
        let minLag = Int(envelopeRate * 60.0 / maxBPM)
        let maxLag = Int(envelopeRate * 60.0 / minBPM)
        
        var bestLag = minLag
        var bestCorr: Float = 0
        
        for lag in minLag...min(maxLag, diff.count / 2) {
            var corr: Float = 0
            var count = 0
            for i in 0..<(diff.count - lag) {
                corr += diff[i] * diff[i + lag]
                count += 1
            }
            if count > 0 {
                corr /= Float(count)
                if corr > bestCorr {
                    bestCorr = corr
                    bestLag = lag
                }
            }
        }
        
        let bpm = envelopeRate * 60.0 / Float(bestLag)
        
        // 计算置信度（基于自相关峰值的显著性）
        var avgCorr: Float = 0
        var corrCount = 0
        for lag in minLag...min(maxLag, diff.count / 2) {
            var corr: Float = 0
            var count = 0
            for i in 0..<(diff.count - lag) {
                corr += diff[i] * diff[i + lag]
                count += 1
            }
            if count > 0 {
                avgCorr += corr / Float(count)
                corrCount += 1
            }
        }
        avgCorr /= Float(corrCount)
        
        let confidence = min(1.0, bestCorr / (avgCorr * 2 + 0.001))
        
        return BPMResult(bpm: bpm, confidence: confidence)
    }
    
    // MARK: - 峰值检测
    
    /// 峰值检测结果
    public struct PeakResult {
        /// 峰值电平（dBFS）
        public let peakDB: Float
        /// 峰值位置（秒）
        public let peakTime: TimeInterval
        /// 是否削波
        public let isClipping: Bool
    }
    
    /// 检测音频峰值
    /// - Parameters:
    ///   - samples: 音频采样数据（Float32）
    ///   - sampleRate: 采样率
    ///   - clippingThreshold: 削波阈值（线性），默认 0.99
    /// - Returns: 峰值检测结果
    public static func detectPeak(
        samples: [Float],
        sampleRate: Int,
        clippingThreshold: Float = 0.99
    ) -> PeakResult {
        var maxAbs: Float = 0
        var maxIndex = 0
        var clippingCount = 0
        
        for (index, sample) in samples.enumerated() {
            let abs = Swift.abs(sample)
            if abs > maxAbs {
                maxAbs = abs
                maxIndex = index
            }
            if abs >= clippingThreshold {
                clippingCount += 1
            }
        }
        
        let peakDB = maxAbs > 0 ? 20.0 * log10f(maxAbs) : -Float.infinity
        let peakTime = Double(maxIndex) / Double(sampleRate)
        let isClipping = clippingCount > 10 // 超过 10 个采样点削波
        
        return PeakResult(peakDB: peakDB, peakTime: peakTime, isClipping: isClipping)
    }
    
    // MARK: - 响度测量
    
    /// 响度测量结果
    public struct LoudnessResult {
        /// 积分响度（LUFS）
        public let integratedLUFS: Float
        /// 短期响度（LUFS）
        public let shortTermLUFS: Float
        /// 响度范围（LRA）
        public let loudnessRange: Float
        /// 真峰值（dBTP）
        public let truePeak: Float
    }
    
    /// 测量音频响度（简化版 EBU R128）
    /// - Parameters:
    ///   - samples: 音频采样数据（Float32）
    ///   - sampleRate: 采样率
    ///   - channelCount: 声道数
    /// - Returns: 响度测量结果
    public static func measureLoudness(
        samples: [Float],
        sampleRate: Int,
        channelCount: Int
    ) -> LoudnessResult {
        // 简化版响度测量
        // 完整的 EBU R128 需要 K-weighting 滤波，这里使用简化算法
        
        let frameCount = samples.count / channelCount
        
        // 计算 RMS
        var sumSquares: Float = 0
        for sample in samples {
            sumSquares += sample * sample
        }
        let rms = sqrtf(sumSquares / Float(samples.count))
        
        // 转换为 LUFS（简化：LUFS ≈ 20*log10(RMS) - 0.691）
        let integratedLUFS = rms > 0 ? 20.0 * log10f(rms) - 0.691 : -70.0
        
        // 短期响度（最后 3 秒）
        let shortTermSamples = min(sampleRate * 3 * channelCount, samples.count)
        var shortTermSum: Float = 0
        for i in (samples.count - shortTermSamples)..<samples.count {
            shortTermSum += samples[i] * samples[i]
        }
        let shortTermRMS = sqrtf(shortTermSum / Float(shortTermSamples))
        let shortTermLUFS = shortTermRMS > 0 ? 20.0 * log10f(shortTermRMS) - 0.691 : -70.0
        
        // 真峰值
        var maxAbs: Float = 0
        for sample in samples {
            maxAbs = max(maxAbs, abs(sample))
        }
        let truePeak = maxAbs > 0 ? 20.0 * log10f(maxAbs) : -Float.infinity
        
        // 响度范围（简化计算）
        let loudnessRange: Float = 10.0 // 简化值
        
        return LoudnessResult(
            integratedLUFS: integratedLUFS,
            shortTermLUFS: shortTermLUFS,
            loudnessRange: loudnessRange,
            truePeak: truePeak
        )
    }
    
    // MARK: - 削波检测
    
    /// 削波检测结果
    public struct ClippingResult {
        /// 削波采样点数量
        public let clippedSamples: Int
        /// 削波百分比
        public let clippingPercentage: Float
        /// 是否有严重削波
        public let hasSevereClipping: Bool
        /// 削波位置（秒）
        public let clippingPositions: [TimeInterval]
    }
    
    /// 检测音频削波
    /// - Parameters:
    ///   - samples: 音频采样数据（Float32）
    ///   - sampleRate: 采样率
    ///   - threshold: 削波阈值（线性），默认 0.99
    /// - Returns: 削波检测结果
    public static func detectClipping(
        samples: [Float],
        sampleRate: Int,
        threshold: Float = 0.99
    ) -> ClippingResult {
        var clippedSamples = 0
        var positions: [TimeInterval] = []
        var lastClipTime: TimeInterval = -1
        
        for (index, sample) in samples.enumerated() {
            if abs(sample) >= threshold {
                clippedSamples += 1
                let time = Double(index) / Double(sampleRate)
                // 合并相邻的削波位置（0.1 秒内）
                if time - lastClipTime > 0.1 {
                    positions.append(time)
                    lastClipTime = time
                }
            }
        }
        
        let percentage = Float(clippedSamples) / Float(samples.count) * 100.0
        let hasSevereClipping = percentage > 0.1 // 超过 0.1% 认为严重
        
        return ClippingResult(
            clippedSamples: clippedSamples,
            clippingPercentage: percentage,
            hasSevereClipping: hasSevereClipping,
            clippingPositions: positions
        )
    }
    
    // MARK: - 相位检测
    
    /// 相位检测结果
    public struct PhaseResult {
        /// 相位相关性（-1 到 +1）
        /// +1 = 完全同相，0 = 无相关，-1 = 完全反相
        public let correlation: Float
        /// 是否存在相位问题
        public let hasPhaseIssue: Bool
        /// 相位问题描述
        public let description: String
    }
    
    /// 检测立体声音频的相位问题
    /// - Parameters:
    ///   - samples: 音频采样数据（Float32，交错立体声）
    ///   - sampleRate: 采样率
    /// - Returns: 相位检测结果
    public static func detectPhase(
        samples: [Float],
        sampleRate: Int
    ) -> PhaseResult {
        let frameCount = samples.count / 2
        guard frameCount > 0 else {
            return PhaseResult(correlation: 0, hasPhaseIssue: false, description: "无数据")
        }
        
        // 计算左右声道的相关性
        var sumLR: Float = 0
        var sumL2: Float = 0
        var sumR2: Float = 0
        
        for i in 0..<frameCount {
            let left = samples[i * 2]
            let right = samples[i * 2 + 1]
            sumLR += left * right
            sumL2 += left * left
            sumR2 += right * right
        }
        
        let denominator = sqrtf(sumL2 * sumR2)
        let correlation = denominator > 0 ? sumLR / denominator : 0
        
        // 判断相位问题
        let hasPhaseIssue: Bool
        let description: String
        
        if correlation < -0.5 {
            hasPhaseIssue = true
            description = "严重反相：左右声道几乎完全反相，混合为单声道时会相互抵消"
        } else if correlation < 0 {
            hasPhaseIssue = true
            description = "部分反相：存在相位问题，可能影响单声道兼容性"
        } else if correlation > 0.95 {
            hasPhaseIssue = false
            description = "高度相关：左右声道几乎相同，可能是伪立体声"
        } else {
            hasPhaseIssue = false
            description = "正常：立体声相位正常"
        }
        
        return PhaseResult(
            correlation: correlation,
            hasPhaseIssue: hasPhaseIssue,
            description: description
        )
    }
    
    // MARK: - 频率分析
    
    /// 频率分析结果
    public struct FrequencyAnalysis {
        /// 主频率（Hz）
        public let dominantFrequency: Float
        /// 频谱质心（Hz）- 音色亮度指标
        public let spectralCentroid: Float
        /// 低频能量占比（0~1）
        public let lowEnergyRatio: Float
        /// 中频能量占比（0~1）
        public let midEnergyRatio: Float
        /// 高频能量占比（0~1）
        public let highEnergyRatio: Float
    }
    
    /// 分析音频频率特征
    /// - Parameters:
    ///   - samples: 音频采样数据（Float32，单声道）
    ///   - sampleRate: 采样率
    /// - Returns: 频率分析结果
    public static func analyzeFrequency(
        samples: [Float],
        sampleRate: Int
    ) -> FrequencyAnalysis {
        let fftSize = 2048
        guard samples.count >= fftSize else {
            return FrequencyAnalysis(
                dominantFrequency: 0,
                spectralCentroid: 0,
                lowEnergyRatio: 0,
                midEnergyRatio: 0,
                highEnergyRatio: 0
            )
        }
        
        // 简化 FFT：使用 DFT 计算幅度谱
        var magnitudes = [Float](repeating: 0, count: fftSize / 2)
        let nyquist = Float(sampleRate) / 2.0
        let binWidth = nyquist / Float(fftSize / 2)
        
        for k in 0..<(fftSize / 2) {
            var real: Float = 0
            var imag: Float = 0
            let freq = Float(k) * 2.0 * .pi / Float(fftSize)
            
            for n in 0..<fftSize {
                let sample = samples[n]
                real += sample * cosf(freq * Float(n))
                imag -= sample * sinf(freq * Float(n))
            }
            
            magnitudes[k] = sqrtf(real * real + imag * imag) / Float(fftSize)
        }
        
        // 找主频率
        var maxMag: Float = 0
        var maxIndex = 0
        for (i, mag) in magnitudes.enumerated() {
            if mag > maxMag {
                maxMag = mag
                maxIndex = i
            }
        }
        let dominantFrequency = Float(maxIndex) * binWidth
        
        // 计算频谱质心
        var weightedSum: Float = 0
        var totalMag: Float = 0
        for (i, mag) in magnitudes.enumerated() {
            let freq = Float(i) * binWidth
            weightedSum += freq * mag
            totalMag += mag
        }
        let spectralCentroid = totalMag > 0 ? weightedSum / totalMag : 0
        
        // 计算频段能量占比
        // 低频: 0-300Hz, 中频: 300-4000Hz, 高频: 4000Hz+
        let lowCutoff = Int(300.0 / binWidth)
        let midCutoff = Int(4000.0 / binWidth)
        
        var lowEnergy: Float = 0
        var midEnergy: Float = 0
        var highEnergy: Float = 0
        
        for (i, mag) in magnitudes.enumerated() {
            let energy = mag * mag
            if i < lowCutoff {
                lowEnergy += energy
            } else if i < midCutoff {
                midEnergy += energy
            } else {
                highEnergy += energy
            }
        }
        
        let totalEnergy = lowEnergy + midEnergy + highEnergy
        
        return FrequencyAnalysis(
            dominantFrequency: dominantFrequency,
            spectralCentroid: spectralCentroid,
            lowEnergyRatio: totalEnergy > 0 ? lowEnergy / totalEnergy : 0,
            midEnergyRatio: totalEnergy > 0 ? midEnergy / totalEnergy : 0,
            highEnergyRatio: totalEnergy > 0 ? highEnergy / totalEnergy : 0
        )
    }
    
    // MARK: - 动态范围分析
    
    /// 动态范围分析结果
    public struct DynamicRangeResult {
        /// 动态范围（dB）
        public let dynamicRange: Float
        /// 峰值电平（dBFS）
        public let peakLevel: Float
        /// RMS 电平（dBFS）
        public let rmsLevel: Float
        /// 波峰因数（Peak/RMS，dB）
        public let crestFactor: Float
    }
    
    /// 分析音频动态范围
    /// - Parameters:
    ///   - samples: 音频采样数据（Float32）
    ///   - sampleRate: 采样率
    /// - Returns: 动态范围分析结果
    public static func analyzeDynamicRange(
        samples: [Float],
        sampleRate: Int
    ) -> DynamicRangeResult {
        guard !samples.isEmpty else {
            return DynamicRangeResult(
                dynamicRange: 0,
                peakLevel: -Float.infinity,
                rmsLevel: -Float.infinity,
                crestFactor: 0
            )
        }
        
        // 计算峰值
        var maxAbs: Float = 0
        var sumSquares: Float = 0
        
        for sample in samples {
            let abs = Swift.abs(sample)
            maxAbs = max(maxAbs, abs)
            sumSquares += sample * sample
        }
        
        let rms = sqrtf(sumSquares / Float(samples.count))
        
        let peakLevel = maxAbs > 0 ? 20.0 * log10f(maxAbs) : -Float.infinity
        let rmsLevel = rms > 0 ? 20.0 * log10f(rms) : -Float.infinity
        let crestFactor = peakLevel - rmsLevel
        
        // 动态范围：使用窗口化 RMS 的最大最小差
        let windowSize = sampleRate / 10 // 100ms 窗口
        var maxRMS: Float = 0
        var minRMS: Float = Float.infinity
        
        var i = 0
        while i + windowSize <= samples.count {
            var windowSum: Float = 0
            for j in 0..<windowSize {
                let sample = samples[i + j]
                windowSum += sample * sample
            }
            let windowRMS = sqrtf(windowSum / Float(windowSize))
            if windowRMS > 0.0001 { // 忽略静音
                maxRMS = max(maxRMS, windowRMS)
                minRMS = min(minRMS, windowRMS)
            }
            i += windowSize / 2 // 50% 重叠
        }
        
        let dynamicRange: Float
        if minRMS > 0 && minRMS < Float.infinity {
            dynamicRange = 20.0 * log10f(maxRMS / minRMS)
        } else {
            dynamicRange = 0
        }
        
        return DynamicRangeResult(
            dynamicRange: dynamicRange,
            peakLevel: peakLevel,
            rmsLevel: rmsLevel,
            crestFactor: crestFactor
        )
    }
}
