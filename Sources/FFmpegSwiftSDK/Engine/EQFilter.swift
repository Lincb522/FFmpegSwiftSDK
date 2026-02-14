// EQFilter.swift
// FFmpegSwiftSDK
//
// 10 段峰值均衡器，使用 Biquad IIR 滤波器实现。
// 系数计算基于 Audio EQ Cookbook (Robert Bristow-Johnson)。
// 优化：添加增益平滑和状态重置，避免参数变化时产生电流声。

import Foundation

// MARK: - Biquad 滤波器

struct BiquadCoefficients {
    var b0: Float
    var b1: Float
    var b2: Float
    var a1: Float
    var a2: Float

    static func peakingEQ(gainDB: Float, centerFrequency: Float, sampleRate: Float, q: Float = 1.0) -> BiquadCoefficients {
        let a = powf(10.0, gainDB / 40.0)
        let w0 = 2.0 * Float.pi * centerFrequency / sampleRate
        let sinW0 = sinf(w0)
        let cosW0 = cosf(w0)
        let alpha = sinW0 / (2.0 * q)

        let b0 = 1.0 + alpha * a
        let b1 = -2.0 * cosW0
        let b2 = 1.0 - alpha * a
        let a0 = 1.0 + alpha / a
        let a1 = -2.0 * cosW0
        let a2 = 1.0 - alpha / a

        return BiquadCoefficients(
            b0: b0 / a0, b1: b1 / a0, b2: b2 / a0,
            a1: a1 / a0, a2: a2 / a0
        )
    }

    static var unity: BiquadCoefficients {
        BiquadCoefficients(b0: 1.0, b1: 0.0, b2: 0.0, a1: 0.0, a2: 0.0)
    }
    
    /// 线性插值两组系数
    static func interpolate(_ a: BiquadCoefficients, _ b: BiquadCoefficients, t: Float) -> BiquadCoefficients {
        return BiquadCoefficients(
            b0: a.b0 + (b.b0 - a.b0) * t,
            b1: a.b1 + (b.b1 - a.b1) * t,
            b2: a.b2 + (b.b2 - a.b2) * t,
            a1: a.a1 + (b.a1 - a.a1) * t,
            a2: a.a2 + (b.a2 - a.a2) * t
        )
    }
}

struct BiquadState {
    var z1: Float = 0.0
    var z2: Float = 0.0

    mutating func reset() {
        z1 = 0.0
        z2 = 0.0
    }
    
    /// 软重置：逐渐衰减状态而不是立即清零
    mutating func softReset(factor: Float = 0.9) {
        z1 *= factor
        z2 *= factor
    }
}

// MARK: - EQFilter

/// 10 段峰值均衡器，用于 HiFi 音频处理。
///
/// 每个频段使用 Biquad 峰值 EQ，系数来自 Audio EQ Cookbook。
/// 频段从低频到高频串联处理。
/// 线程安全：增益可以从任何线程修改，处理在另一个线程运行。
/// 
/// 优化特性：
/// - 增益平滑：参数变化时使用插值避免突变
/// - 状态管理：大幅度参数变化时软重置滤波器状态
public final class EQFilter {

    private let lock = NSLock()

    private var gains: [EQBand: Float] = {
        var g = [EQBand: Float]()
        for band in EQBand.allCases { g[band] = 0.0 }
        return g
    }()
    
    /// 目标增益（用于平滑过渡）
    private var targetGains: [EQBand: Float] = {
        var g = [EQBand: Float]()
        for band in EQBand.allCases { g[band] = 0.0 }
        return g
    }()
    
    /// 当前系数
    private var currentCoeffs: [EQBand: BiquadCoefficients] = {
        var c = [EQBand: BiquadCoefficients]()
        for band in EQBand.allCases { c[band] = .unity }
        return c
    }()

    private var states: [EQBand: [BiquadState]] = {
        var s = [EQBand: [BiquadState]]()
        for band in EQBand.allCases { s[band] = [] }
        return s
    }()
    
    /// 增益平滑系数（每帧向目标靠近的比例）
    private let smoothingFactor: Float = 0.05
    
    /// 上一次的采样率
    private var lastSampleRate: Float = 44100

    public init() {}

    @discardableResult
    public func setGain(_ gain: Float, for band: EQBand) -> Float {
        let clamped = EQBandGain.clamped(gain)
        lock.lock()
        let oldGain = targetGains[band] ?? 0.0
        targetGains[band] = clamped
        
        // 如果变化很大，软重置滤波器状态避免电流声
        if abs(clamped - oldGain) > 6.0 {
            if var bandStates = states[band] {
                for i in 0..<bandStates.count {
                    bandStates[i].softReset(factor: 0.5)
                }
                states[band] = bandStates
            }
        }
        lock.unlock()
        return clamped
    }

    public func gain(for band: EQBand) -> Float {
        lock.lock()
        let value = targetGains[band] ?? 0.0
        lock.unlock()
        return value
    }

    public func reset() {
        lock.lock()
        for band in EQBand.allCases {
            gains[band] = 0.0
            targetGains[band] = 0.0
            currentCoeffs[band] = .unity
            states[band] = []
        }
        lock.unlock()
    }

    public func process(_ buffer: AudioBuffer) -> AudioBuffer {
        let totalSamples = buffer.frameCount * buffer.channelCount
        let outputData = UnsafeMutablePointer<Float>.allocate(capacity: totalSamples)
        outputData.initialize(from: buffer.data, count: totalSamples)

        lock.lock()
        
        let sampleRate = Float(buffer.sampleRate)
        let channelCount = buffer.channelCount
        let frameCount = buffer.frameCount
        
        // 检测采样率变化，重置状态
        if abs(sampleRate - lastSampleRate) > 1 {
            for band in EQBand.allCases {
                states[band] = []
            }
            lastSampleRate = sampleRate
        }

        for band in EQBand.allCases {
            // 平滑增益过渡
            let targetGain = targetGains[band] ?? 0.0
            var currentGain = gains[band] ?? 0.0
            
            // 逐渐靠近目标增益
            if abs(targetGain - currentGain) > 0.01 {
                currentGain += (targetGain - currentGain) * smoothingFactor
            } else {
                currentGain = targetGain
            }
            gains[band] = currentGain
            
            // 计算目标系数
            let targetCoeffs = BiquadCoefficients.peakingEQ(
                gainDB: currentGain,
                centerFrequency: band.centerFrequency,
                sampleRate: sampleRate,
                q: band.q
            )
            
            // 系数插值（更平滑的过渡）
            let oldCoeffs = currentCoeffs[band] ?? .unity
            let coeffs = BiquadCoefficients.interpolate(oldCoeffs, targetCoeffs, t: 0.3)
            currentCoeffs[band] = coeffs

            // 初始化状态
            if states[band]?.count != channelCount {
                states[band] = Array(repeating: BiquadState(), count: channelCount)
            }
            var bandStates = states[band]!

            for ch in 0..<channelCount {
                var z1 = bandStates[ch].z1
                var z2 = bandStates[ch].z2

                for frame in 0..<frameCount {
                    let idx = frame * channelCount + ch
                    let input = outputData[idx]
                    let output = coeffs.b0 * input + z1
                    z1 = coeffs.b1 * input - coeffs.a1 * output + z2
                    z2 = coeffs.b2 * input - coeffs.a2 * output
                    outputData[idx] = output
                }

                bandStates[ch].z1 = z1
                bandStates[ch].z2 = z2
            }

            states[band] = bandStates
        }
        
        lock.unlock()

        return AudioBuffer(
            data: outputData,
            frameCount: frameCount,
            channelCount: channelCount,
            sampleRate: buffer.sampleRate
        )
    }
}
