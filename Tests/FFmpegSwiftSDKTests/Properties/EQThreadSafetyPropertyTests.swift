// EQThreadSafetyPropertyTests.swift
// FFmpegSwiftSDKTests
//
// Property-based tests for EQFilter thread safety under concurrent access.
// **Validates: Requirements 5.7**

import XCTest
import SwiftCheck
@testable import FFmpegSwiftSDK

// MARK: - Concurrent Operation Model

/// Represents a single operation that can be performed on an EQFilter.
/// Used to generate random sequences of concurrent operations.
enum EQOperation {
    /// Set a gain value for a specific band.
    case setGain(band: EQBand, gainDB: Float)
    /// Process an audio buffer through the filter.
    case processBuffer(frameCount: Int, channelCount: Int, sampleRate: Int)
}

extension EQOperation: Arbitrary {
    static var arbitrary: Gen<EQOperation> {
        let setGainGen: Gen<EQOperation> = Gen<(EQBand, Float)>.zip(
            EQBand.arbitrary,
            Float.arbitrary.suchThat { !$0.isNaN && !$0.isInfinite }
                .map { EQBandGain.clamped($0) }
        ).map { .setGain(band: $0.0, gainDB: $0.1) }

        let processGen: Gen<EQOperation> = Gen<(Int, Int, Int)>.zip(
            Gen<Int>.fromElements(in: 64...512),
            Gen<Int>.fromElements(in: 1...2),
            Gen<Int>.fromElements(of: [44100, 48000])
        ).map { .processBuffer(frameCount: $0.0, channelCount: $0.1, sampleRate: $0.2) }

        return Gen<EQOperation>.one(of: [setGainGen, processGen])
    }
}

// MARK: - EQThreadSafetyPropertyTests

final class EQThreadSafetyPropertyTests: XCTestCase {

    // MARK: - Property 7: EQ 线程安全
    //
    // For any concurrent sequence of gain modification operations and audio
    // processing operations, EQFilter must not produce data races, crashes,
    // or undefined behavior. Each process() output must correspond to some
    // consistent gain state.
    //
    // Strategy:
    //   1. Use SwiftCheck to generate random sequences of EQOperations.
    //   2. Split operations into two groups: setGain ops and process ops.
    //   3. Execute both groups concurrently on separate dispatch queues.
    //   4. Verify:
    //      a. No crashes occur (implicit - test completes).
    //      b. All output buffers have valid metadata (frameCount, channelCount, sampleRate match input).
    //      c. All output samples are finite (not NaN or Inf), confirming consistent gain state.
    //      d. Gains read after all operations are valid (within [-12, 12]).
    //
    // **Validates: Requirements 5.7**

    func testProperty7_EQThreadSafety() {
        // Generator: a list of 10-30 random EQ operations
        let opsGen: Gen<[EQOperation]> = EQOperation.arbitrary
            .proliferate(withSize: 20)

        property("EQFilter is thread-safe under concurrent gain modification and audio processing")
            <- forAll(opsGen) { (operations: [EQOperation]) in
                // Ensure we have a meaningful test
                guard !operations.isEmpty else { return true <?> "empty operations" }

                let filter = EQFilter()

                // Split operations into setGain and process groups
                var gainOps: [(EQBand, Float)] = []
                var processOps: [(Int, Int, Int)] = []

                for op in operations {
                    switch op {
                    case .setGain(let band, let gainDB):
                        gainOps.append((band, gainDB))
                    case .processBuffer(let frameCount, let channelCount, let sampleRate):
                        processOps.append((frameCount, channelCount, sampleRate))
                    }
                }

                // Ensure we have at least one of each type for a meaningful concurrency test
                if gainOps.isEmpty {
                    gainOps.append((.hz125, 3.0))
                }
                if processOps.isEmpty {
                    processOps.append((128, 1, 44100))
                }

                // Track results from process operations
                let resultsLock = NSLock()
                var processResults: [(valid: Bool, frameCount: Int, channelCount: Int, sampleRate: Int)] = []
                var allSamplesFinite = true

                let group = DispatchGroup()

                // Thread 1: Execute gain operations
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    for (band, gainDB) in gainOps {
                        filter.setGain(gainDB, for: band)
                    }
                    group.leave()
                }

                // Thread 2: Execute process operations
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    for (frameCount, channelCount, sampleRate) in processOps {
                        let totalSamples = frameCount * channelCount
                        let inputData = UnsafeMutablePointer<Float>.allocate(capacity: totalSamples)
                        for i in 0..<totalSamples {
                            inputData[i] = sinf(Float(i) * 0.01)
                        }
                        let input = AudioBuffer(
                            data: inputData,
                            frameCount: frameCount,
                            channelCount: channelCount,
                            sampleRate: sampleRate
                        )

                        let output = filter.process(input)

                        // Validate output metadata matches input
                        let metadataValid = output.frameCount == frameCount
                            && output.channelCount == channelCount
                            && output.sampleRate == sampleRate

                        // Validate all output samples are finite
                        var samplesFinite = true
                        let outputTotalSamples = output.frameCount * output.channelCount
                        for i in 0..<outputTotalSamples {
                            if output.data[i].isNaN || output.data[i].isInfinite {
                                samplesFinite = false
                                break
                            }
                        }

                        resultsLock.lock()
                        processResults.append((
                            valid: metadataValid,
                            frameCount: frameCount,
                            channelCount: channelCount,
                            sampleRate: sampleRate
                        ))
                        if !samplesFinite {
                            allSamplesFinite = false
                        }
                        resultsLock.unlock()

                        // Clean up
                        inputData.deallocate()
                        output.data.deallocate()
                    }
                    group.leave()
                }

                // Wait for both threads to complete
                let waitResult = group.wait(timeout: .now() + 10.0)
                let completedInTime = waitResult == .success

                // Verify gains are valid after all operations
                var gainsValid = true
                for band in EQBand.allCases {
                    let g = filter.gain(for: band)
                    if g < EQBandGain.minGain || g > EQBandGain.maxGain || g.isNaN || g.isInfinite {
                        gainsValid = false
                    }
                }

                // Verify all process results had valid metadata
                resultsLock.lock()
                let allMetadataValid = processResults.allSatisfy { $0.valid }
                let localSamplesFinite = allSamplesFinite
                resultsLock.unlock()

                return completedInTime <?> "operations completed within timeout"
                    ^&&^
                    allMetadataValid <?> "all output buffers have valid metadata"
                    ^&&^
                    localSamplesFinite <?> "all output samples are finite (no NaN/Inf)"
                    ^&&^
                    gainsValid <?> "all gains are valid after concurrent operations"
            }
    }
}
