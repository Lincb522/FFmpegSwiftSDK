// EQIdentityPropertyTests.swift
// FFmpegSwiftSDKTests
//
// Property-based tests for EQFilter zero-gain identity transform.
// **Validates: Requirements 5.5**

import XCTest
import SwiftCheck
@testable import FFmpegSwiftSDK

final class EQIdentityPropertyTests: XCTestCase {

    // MARK: - Property 5: 零增益恒等变换
    //
    // For any PCM audio buffer, when all EQFilter band gains are set to 0 dB,
    // the processed output data must be identical to the input data within
    // floating-point precision (error < 1e-6).
    //
    // A fresh EQFilter instance is created for each iteration to avoid
    // delay line state from previous iterations affecting the output.
    //
    // **Validates: Requirements 5.5**

    func testProperty5_ZeroGainIdentity() {
        // Generators for buffer parameters
        let frameCountGen = Gen<Int>.fromElements(in: 64...2048)
        let channelCountGen = Gen<Int>.fromElements(in: 1...2)
        let sampleRateGen = Gen<Int>.fromElements(of: [44100, 48000])

        property("zero gain EQ is identity transform") <- forAll(frameCountGen, channelCountGen, sampleRateGen) { (frameCount: Int, channelCount: Int, sampleRate: Int) in
            // Create a fresh EQFilter for each iteration (avoids delay line state leaking)
            let filter = EQFilter()

            let totalSamples = frameCount * channelCount

            // Allocate and fill input with random PCM data in [-1.0, 1.0]
            let inputData = UnsafeMutablePointer<Float>.allocate(capacity: totalSamples)
            for i in 0..<totalSamples {
                inputData[i] = Float.random(in: -1.0...1.0)
            }

            let input = AudioBuffer(
                data: inputData,
                frameCount: frameCount,
                channelCount: channelCount,
                sampleRate: sampleRate
            )

            // Process with all gains at 0 dB (default)
            let output = filter.process(input)

            // Compute maximum absolute error between output and input
            var maxError: Float = 0.0
            for i in 0..<totalSamples {
                let error = abs(output.data[i] - inputData[i])
                if error > maxError {
                    maxError = error
                }
            }

            // Clean up allocated memory
            inputData.deallocate()
            output.data.deallocate()

            return (maxError < 1e-6)
                <?> "max error \(maxError) should be < 1e-6 (frameCount=\(frameCount), channels=\(channelCount), sampleRate=\(sampleRate))"
        }
    }
}
