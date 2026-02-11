// AVSyncPropertyTests.swift
// FFmpegSwiftSDKTests
//
// Property-based tests for AVSyncController audio-video synchronization.
// **Validates: Requirements 4.3**

import XCTest
import SwiftCheck
@testable import FFmpegSwiftSDK

final class AVSyncPropertyTests: XCTestCase {

    // MARK: - Property 3: 音视频同步偏差控制
    //
    // For any monotonically increasing audio PTS sequence and video PTS sequence,
    // the AVSyncController's sync actions should ensure that the drift between
    // displayed video frames and the audio clock never exceeds 40 milliseconds.
    //
    // Strategy:
    //   1. Generate random monotonically increasing PTS sequences for audio and video.
    //      - Start from a random base time ≥ 0.
    //      - Each subsequent PTS increments by a random positive delta.
    //   2. Interleave audio clock updates and video sync action queries to simulate
    //      realistic playback where audio and video frames arrive in temporal order.
    //   3. For each video frame:
    //      - Update the audio clock to the latest audio PTS that is ≤ the video PTS
    //        (simulating audio-master-clock behavior where audio is processed first).
    //      - Query syncAction(for: videoPTS).
    //      - For .display(delay:) actions: verify |videoPTS - audioClock| ≤ 40ms
    //        (the controller only returns .display when drift is within threshold).
    //      - For .drop actions: the frame is skipped (video was too far behind),
    //        which is a valid compensation mechanism.
    //      - For .repeatPrevious actions: the previous frame is held (video was too
    //        far ahead), which is also a valid compensation mechanism.
    //   4. The property holds if every .display action has drift ≤ 40ms.
    //
    // **Validates: Requirements 4.3**

    /// Generator for a monotonically increasing PTS sequence.
    /// Produces an array of TimeInterval values where each is strictly greater than the previous.
    /// - Parameters:
    ///   - count: Number of PTS values to generate (10-50).
    ///   - minDelta: Minimum increment between consecutive PTS values.
    ///   - maxDelta: Maximum increment between consecutive PTS values.
    static func monotonicallyIncreasingPTSGen(
        count: Int,
        minDelta: Double = 0.001,
        maxDelta: Double = 0.100
    ) -> Gen<[TimeInterval]> {
        // Generate `count` positive deltas, then compute prefix sums from a random base
        let deltaGen = Gen<Double>.fromElements(in: minDelta...maxDelta)
        let baseGen = Gen<Double>.fromElements(in: 0.0...10.0)

        return Gen<(Double, [Double])>.zip(baseGen, sequence(Array(repeating: deltaGen, count: count)))
            .map { (base, deltas) -> [TimeInterval] in
                var pts: [TimeInterval] = []
                var current = base
                for delta in deltas {
                    current += delta
                    pts.append(current)
                }
                return pts
            }
    }

    func testProperty3_AVSyncDriftControl() {
        // Generate sequence lengths between 10 and 50
        let countGen = Gen<Int>.fromElements(in: 10...50)

        property("Displayed video frames always have drift ≤ 40ms from audio clock")
            <- forAll(countGen) { (count: Int) in

                // Generate monotonically increasing PTS sequences for audio and video
                // Audio typically has smaller intervals (e.g., ~23ms for 1024 samples at 44100Hz)
                // Video typically has larger intervals (e.g., ~33ms for 30fps)
                let audioPTSGen = AVSyncPropertyTests.monotonicallyIncreasingPTSGen(
                    count: count,
                    minDelta: 0.010,
                    maxDelta: 0.050
                )
                let videoPTSGen = AVSyncPropertyTests.monotonicallyIncreasingPTSGen(
                    count: count,
                    minDelta: 0.020,
                    maxDelta: 0.080
                )

                return forAll(audioPTSGen, videoPTSGen) { (audioPTS: [TimeInterval], videoPTS: [TimeInterval]) in
                    let controller = AVSyncController()

                    var audioIndex = 0

                    for videoPt in videoPTS {
                        // Advance audio clock to the latest audio PTS ≤ current video PTS.
                        // This simulates the audio-master-clock model where audio frames
                        // are processed and the clock is updated before video frames are rendered.
                        while audioIndex < audioPTS.count && audioPTS[audioIndex] <= videoPt {
                            controller.updateAudioClock(audioPTS[audioIndex])
                            audioIndex += 1
                        }

                        let action = controller.syncAction(for: videoPt)
                        let currentAudio = controller.currentAudioClock()

                        switch action {
                        case .display(let delay):
                            // For displayed frames, the drift between video PTS and audio clock
                            // must be within the maxDrift threshold (40ms).
                            // The controller only returns .display when |drift| ≤ maxDrift.
                            let drift = abs(videoPt - currentAudio)
                            if drift > controller.maxDrift + 1e-9 {
                                return false
                                    <?> "Displayed frame drift \(drift)s exceeds 40ms (videoPTS=\(videoPt), audioClock=\(currentAudio), delay=\(delay))"
                            }

                        case .drop:
                            // Frame is dropped because video is too far behind audio.
                            // This is a valid compensation action - no drift violation.
                            break

                        case .repeatPrevious:
                            // Previous frame is repeated because video is too far ahead.
                            // This is a valid compensation action - no drift violation.
                            break
                        }
                    }

                    return true <?> "All displayed frames have drift ≤ 40ms"
                }
            }
    }

    /// Additional property: verify that the sync controller always takes compensatory
    /// action (drop or repeat) when drift exceeds 40ms, and never displays a frame
    /// with drift > 40ms.
    ///
    /// This tests the contrapositive: if a frame IS displayed, drift MUST be ≤ 40ms.
    ///
    /// **Validates: Requirements 4.3**
    func testProperty3_DisplayImpliesDriftWithinThreshold() {
        // Generate individual audio clock and video PTS pairs with varying drift
        let audioClockGen = Gen<Double>.fromElements(in: 0.0...100.0)
        let driftGen = Gen<Double>.fromElements(in: -0.200...0.200)

        property("syncAction .display implies drift ≤ 40ms")
            <- forAll(audioClockGen, driftGen) { (audioClock: Double, drift: Double) in
                let controller = AVSyncController()
                controller.updateAudioClock(audioClock)

                let videoPTS = audioClock + drift
                let action = controller.syncAction(for: videoPTS)

                switch action {
                case .display:
                    // If the controller chose to display, drift must be within threshold
                    let absDrift = abs(drift)
                    return (absDrift <= controller.maxDrift + 1e-9)
                        <?> "Display action with drift \(drift)s should have |drift| ≤ 40ms"

                case .drop:
                    // Drop means video was behind by > 40ms
                    return (drift < -controller.maxDrift + 1e-9)
                        <?> "Drop action should only occur when video is behind by > 40ms (drift=\(drift))"

                case .repeatPrevious:
                    // Repeat means video was ahead by > 40ms
                    return (drift > controller.maxDrift - 1e-9)
                        <?> "RepeatPrevious should only occur when video is ahead by > 40ms (drift=\(drift))"
                }
            }
    }
}
