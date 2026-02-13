// EQFilter.swift
// FFmpegSwiftSDK
//
// 10-band peaking EQ filter using Biquad IIR filters.
// Coefficients computed from the Audio EQ Cookbook (Robert Bristow-Johnson).

import Foundation

// MARK: - Biquad Filter

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
}

struct BiquadState {
    var z1: Float = 0.0
    var z2: Float = 0.0

    mutating func reset() {
        z1 = 0.0
        z2 = 0.0
    }
}

// MARK: - EQFilter

/// A 10-band peaking EQ filter for HiFi audio processing.
///
/// Each band uses a Biquad peaking EQ with coefficients from the Audio EQ Cookbook.
/// Bands are applied in series from low to high frequency.
/// Thread-safe: gains can be modified from any thread while processing runs on another.
public final class EQFilter {

    private let lock = NSLock()

    private var gains: [EQBand: Float] = {
        var g = [EQBand: Float]()
        for band in EQBand.allCases { g[band] = 0.0 }
        return g
    }()

    private var states: [EQBand: [BiquadState]] = {
        var s = [EQBand: [BiquadState]]()
        for band in EQBand.allCases { s[band] = [] }
        return s
    }()

    public init() {}

    @discardableResult
    public func setGain(_ gain: Float, for band: EQBand) -> Float {
        let clamped = EQBandGain.clamped(gain)
        lock.lock()
        gains[band] = clamped
        lock.unlock()
        return clamped
    }

    public func gain(for band: EQBand) -> Float {
        lock.lock()
        let value = gains[band] ?? 0.0
        lock.unlock()
        return value
    }

    public func reset() {
        lock.lock()
        for band in EQBand.allCases {
            gains[band] = 0.0
            states[band] = []
        }
        lock.unlock()
    }

    public func process(_ buffer: AudioBuffer) -> AudioBuffer {
        let totalSamples = buffer.frameCount * buffer.channelCount
        let outputData = UnsafeMutablePointer<Float>.allocate(capacity: totalSamples)
        outputData.initialize(from: buffer.data, count: totalSamples)

        lock.lock()
        let currentGains = gains
        lock.unlock()

        let sampleRate = Float(buffer.sampleRate)
        let channelCount = buffer.channelCount
        let frameCount = buffer.frameCount

        for band in EQBand.allCases {
            let gainDB = currentGains[band] ?? 0.0

            let coeffs = BiquadCoefficients.peakingEQ(
                gainDB: gainDB,
                centerFrequency: band.centerFrequency,
                sampleRate: sampleRate,
                q: band.q
            )

            lock.lock()
            if states[band]?.count != channelCount {
                states[band] = Array(repeating: BiquadState(), count: channelCount)
            }
            var bandStates = states[band]!
            lock.unlock()

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

            lock.lock()
            states[band] = bandStates
            lock.unlock()
        }

        return AudioBuffer(
            data: outputData,
            frameCount: frameCount,
            channelCount: channelCount,
            sampleRate: buffer.sampleRate
        )
    }
}
