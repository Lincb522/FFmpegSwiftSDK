// EQApplyPropertyTests.swift
// FFmpegSwiftSDKTests
//
// Property-based tests for EQFilter real-time gain application.
// **Validates: Requirements 5.2**

import XCTest
import SwiftCheck
@testable import FFmpegSwiftSDK

// MARK: - Arbitrary conformance for EQBand

extension EQBand: Arbitrary {
    public static var arbitrary: Gen<EQBand> {
        Gen<EQBand>.fromElements(of: EQBand.allCases)
    }
}

final class EQApplyPropertyTests: XCTestCase {

    // MARK: - Property 6: 增益实时应用
    //
    // For any EQ band and any valid gain value (-12 to +12 dB), after setting
    // the gain, the next processed audio buffer's output should reflect the new
    // gain setting (differ from the output before the gain change, unless the
    // old and new gains are the same).
    //
    // Strategy:
    //   1. Create a fresh EQFilter (all gains 0 dB).
    //   2. Generate a deterministic sine wave buffer at the band's center frequency
    //      (this ensures the band's filter has maximum effect on the signal).
    //   3. Process the buffer with default 0 dB gain → output_before.
    //   4. Create a fresh EQFilter with the new non-zero gain for the chosen band.
    //   5. Process the same input → output_after.
    //   6. Verify that output_after differs from output_before.
    //
    // We use a fresh filter for each gain setting to isolate the effect of the
    // gain parameter from the Biquad delay line state, which would otherwise
    // carry over between process() calls and complicate the comparison.
    //
    // **Validates: Requirements 5.2**

    func testProperty6_GainRealtimeApplication() {
        // Generator: non-zero gain values in valid range
        // We exclude values very close to zero (|gain| < 0.5) to ensure a measurable effect
        let nonZeroGainGen: Gen<Float> = Gen<Float>.one(of: [
            Gen<Float>.fromElements(in: -12.0 ... -0.5),
            Gen<Float>.fromElements(in: 0.5 ... 12.0)
        ])

        // Fixed buffer parameters for deterministic comparison
        let frameCount = 4096
        let channelCount = 1
        let sampleRate = 44100

        property("Setting a non-zero gain produces different output than zero gain")
            <- forAll(EQBand.arbitrary, nonZeroGainGen) { (band: EQBand, gainDB: Float) in

                // Create a deterministic sine wave at the band's center frequency.
                // This maximizes the filter's effect on the signal.
                let centerFreq = band.centerFrequency
                let totalSamples = frameCount * channelCount

                // --- Output with 0 dB gain (identity) ---
                let filterBefore = EQFilter()
                let inputBefore = UnsafeMutablePointer<Float>.allocate(capacity: totalSamples)
                for frame in 0..<frameCount {
                    let sample = sinf(2.0 * Float.pi * centerFreq * Float(frame) / Float(sampleRate))
                    for ch in 0..<channelCount {
                        inputBefore[frame * channelCount + ch] = sample
                    }
                }
                let bufferBefore = AudioBuffer(
                    data: inputBefore,
                    frameCount: frameCount,
                    channelCount: channelCount,
                    sampleRate: sampleRate
                )
                let outputBefore = filterBefore.process(bufferBefore)

                // --- Output with the new gain applied ---
                let filterAfter = EQFilter()
                filterAfter.setGain(gainDB, for: band)

                let inputAfter = UnsafeMutablePointer<Float>.allocate(capacity: totalSamples)
                for frame in 0..<frameCount {
                    let sample = sinf(2.0 * Float.pi * centerFreq * Float(frame) / Float(sampleRate))
                    for ch in 0..<channelCount {
                        inputAfter[frame * channelCount + ch] = sample
                    }
                }
                let bufferAfter = AudioBuffer(
                    data: inputAfter,
                    frameCount: frameCount,
                    channelCount: channelCount,
                    sampleRate: sampleRate
                )
                let outputAfter = filterAfter.process(bufferAfter)

                // --- Compare: outputs must differ ---
                var maxDifference: Float = 0.0
                for i in 0..<totalSamples {
                    let diff = abs(outputAfter.data[i] - outputBefore.data[i])
                    if diff > maxDifference {
                        maxDifference = diff
                    }
                }

                // Clean up
                inputBefore.deallocate()
                inputAfter.deallocate()
                outputBefore.data.deallocate()
                outputAfter.data.deallocate()

                // The output with non-zero gain must differ from zero-gain output
                return (maxDifference > 1e-6)
                    <?> "gain \(gainDB) dB on band \(band) should change output (maxDiff=\(maxDifference))"
            }
    }
}
