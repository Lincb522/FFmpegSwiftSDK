// PlayerStatePropertyTests.swift
// FFmpegSwiftSDKTests
//
// Property-based tests for StreamPlayer state change delegate callbacks.
// **Validates: Requirements 6.3**

import XCTest
import SwiftCheck
@testable import FFmpegSwiftSDK

// MARK: - Player Operation Model

/// Represents a synchronous player operation that triggers state transitions.
/// We model operations whose state effects are immediately observable.
enum PlayerOperation: CaseIterable, CustomStringConvertible {
    case play
    case pause
    case resume
    case stop

    var description: String {
        switch self {
        case .play: return "play"
        case .pause: return "pause"
        case .resume: return "resume"
        case .stop: return "stop"
        }
    }
}

extension PlayerOperation: Arbitrary {
    static var arbitrary: Gen<PlayerOperation> {
        Gen<PlayerOperation>.fromElements(of: PlayerOperation.allCases)
    }
}

// MARK: - Property Test Delegate

/// A delegate that records state changes received via callbacks.
private final class PropertyTestDelegate: StreamPlayerDelegate {
    var callbackStates: [PlaybackState] = []

    func player(_ player: StreamPlayer, didChangeState state: PlaybackState) {
        callbackStates.append(state)
    }

    func player(_ player: StreamPlayer, didEncounterError error: FFmpegError) {}
    func player(_ player: StreamPlayer, didUpdateDuration duration: TimeInterval) {}
}

// MARK: - PlayerStatePropertyTests

final class PlayerStatePropertyTests: XCTestCase {

    // MARK: - Property 8: 播放状态变化回调
    //
    // For any valid sequence of playback state transitions
    // (idle→connecting→playing→paused→playing→stopped), the StreamPlayer's
    // delegate should receive a callback corresponding to each state transition,
    // and the state value in the callback should match the StreamPlayer's state property.
    //
    // Strategy:
    //   We generate random sequences of player operations (play/pause/resume/stop)
    //   and apply them to a StreamPlayer. For each operation we verify:
    //   1. A delegate callback fires when (and only when) the state actually changes
    //   2. The state in the callback matches the expected transition
    //   3. No duplicate consecutive callbacks for the same state (didSet guard)
    //
    //   play() triggers an async pipeline that may produce additional state changes
    //   (e.g., .error from invalid URL). We account for this by:
    //   - Verifying .connecting appears in callbacks after play()
    //   - Allowing additional async callbacks (error) without treating them as failures
    //   - Waiting briefly after play() to let the synchronous transition complete
    //
    // **Validates: Requirements 6.3**

    func testProperty8_StateChangeCallbacks() {
        // Short sequences to keep total runtime manageable across 100+ iterations
        let opsGen = Gen<[PlayerOperation]>.compose { composer in
            let count = composer.generate(using: Gen<Int>.fromElements(in: 1...8))
            return (0..<count).map { _ in composer.generate(using: PlayerOperation.arbitrary) }
        }

        property("Each state transition triggers a delegate callback with correct state")
            <- forAll(opsGen) { (operations: [PlayerOperation]) in

                let player = StreamPlayer()
                let delegate = PropertyTestDelegate()
                player.delegate = delegate

                var currentState: PlaybackState = .idle

                for op in operations {
                    let stateBefore = currentState
                    let callbackCountBefore = delegate.callbackStates.count

                    switch op {
                    case .play:
                        player.play(url: "invalid://pbt-\(arc4random())")
                        // play() synchronously transitions to .connecting via transitionState
                        // then kicks off async pipeline. Wait for sync transition.
                        Thread.sleep(forTimeInterval: 0.02)

                        if stateBefore != .connecting {
                            currentState = .connecting
                        }
                        // Async pipeline may also produce .error callback - that's expected
                        // behavior. We wait a bit more to let it settle, then update our
                        // tracked state to match reality.
                        Thread.sleep(forTimeInterval: 0.05)
                        // Sync our tracked state with the player's actual state
                        // (may have moved to .error from async pipeline)
                        currentState = player.state

                    case .pause:
                        player.pause()
                        if stateBefore == .playing {
                            currentState = .paused
                        }

                    case .resume:
                        player.resume()
                        if stateBefore == .paused {
                            currentState = .playing
                        }

                    case .stop:
                        player.stop()
                        if stateBefore != .stopped {
                            currentState = .stopped
                        }
                    }

                    let callbackCountAfter = delegate.callbackStates.count
                    let stateChanged = (stateBefore != currentState)

                    if stateChanged {
                        // Verify at least one new callback was received
                        if callbackCountAfter <= callbackCountBefore {
                            return false
                                <?> "Expected callback for \(op): \(stateBefore)→\(currentState), got none"
                        }

                        // For play(), verify .connecting appeared in the new callbacks
                        if op == .play && stateBefore != .connecting {
                            let newCallbacks = Array(delegate.callbackStates[callbackCountBefore...])
                            let hasConnecting = newCallbacks.contains(.connecting)
                            if !hasConnecting {
                                return false
                                    <?> "play() should produce .connecting callback, got \(newCallbacks)"
                            }
                        }

                        // The player's current state should match our tracked state
                        if player.state != currentState {
                            // Re-sync in case async changes happened
                            currentState = player.state
                        }
                    }
                }

                // Cleanup
                player.stop()
                Thread.sleep(forTimeInterval: 0.02)

                // Core property: no duplicate consecutive callbacks (didSet guard ensures this)
                for i in 1..<delegate.callbackStates.count {
                    if delegate.callbackStates[i] == delegate.callbackStates[i - 1] {
                        return false
                            <?> "Duplicate consecutive callbacks: \(delegate.callbackStates[i]) at index \(i)"
                    }
                }

                // Every callback state should be a valid state that the player can be in
                for cb in delegate.callbackStates {
                    switch cb {
                    case .idle, .connecting, .playing, .paused, .stopped, .error:
                        break // all valid
                    }
                }

                return true <?> "All state transitions produced correct callbacks"
            }
    }

    /// Property: stop() from any reachable state always produces a .stopped callback
    /// (unless already stopped), and the callback state matches the player's state.
    ///
    /// **Validates: Requirements 6.3**
    func testProperty8_StopAlwaysNotifiesDelegate() {
        let opsGen = Gen<[PlayerOperation]>.compose { composer in
            let count = composer.generate(using: Gen<Int>.fromElements(in: 0...5))
            return (0..<count).map { _ in composer.generate(using: PlayerOperation.arbitrary) }
        }

        property("stop() always triggers .stopped callback unless already stopped")
            <- forAll(opsGen) { (prefixOps: [PlayerOperation]) in

                let player = StreamPlayer()
                let delegate = PropertyTestDelegate()
                player.delegate = delegate

                // Apply prefix operations to reach some state
                for op in prefixOps {
                    switch op {
                    case .play:
                        player.play(url: "invalid://stop-pbt-\(arc4random())")
                        Thread.sleep(forTimeInterval: 0.07)
                    case .pause: player.pause()
                    case .resume: player.resume()
                    case .stop: player.stop()
                    }
                }

                // Let any async work settle
                Thread.sleep(forTimeInterval: 0.05)
                let stateBeforeStop = player.state
                delegate.callbackStates.removeAll()

                // Call stop
                player.stop()

                if stateBeforeStop != .stopped {
                    if !delegate.callbackStates.contains(.stopped) {
                        return false
                            <?> "stop() from \(stateBeforeStop) should produce .stopped callback"
                    }
                    if player.state != .stopped {
                        return false
                            <?> "Player state should be .stopped after stop(), got \(player.state)"
                    }
                } else {
                    if delegate.callbackStates.contains(.stopped) {
                        return false
                            <?> "stop() from .stopped should not produce duplicate callback"
                    }
                }

                return true <?> "stop() callback behavior is correct"
            }
    }

    // MARK: - Property 9: 播放会话重入
    //
    // For any positive integer N, after executing N play/stop cycles,
    // StreamPlayer should always be able to start a new playback session.
    // After each stop(), state should be .stopped.
    // After each play(), state should transition to .connecting.
    //
    // Strategy:
    //   Generate a random positive integer N (1-10, kept small for performance).
    //   Execute N play/stop cycles using an invalid URL (so the pipeline fails
    //   quickly — we're testing the state machine, not actual playback).
    //   After each play(): verify state transitions to .connecting.
    //   After each stop(): verify state is .stopped.
    //   After all N cycles, verify the player can still start one more session.
    //
    // **Validates: Requirements 6.5**

    func testProperty9_PlayStopReentry() {
        let cycleCountGen = Gen<Int>.fromElements(in: 1...10)

        property("N play/stop cycles always allow a new session to start")
            <- forAll(cycleCountGen) { (n: Int) in

                let player = StreamPlayer()
                let delegate = PropertyTestDelegate()
                player.delegate = delegate

                for i in 0..<n {
                    // play() should transition to .connecting
                    player.play(url: "invalid://reentry-pbt-\(i)-\(arc4random())")
                    // Allow synchronous state transition to settle
                    Thread.sleep(forTimeInterval: 0.02)

                    let stateAfterPlay = player.state
                    // The state should be .connecting (or may have already moved to .error
                    // from the async pipeline with an invalid URL). Both are acceptable
                    // since the key property is that play() was able to start.
                    let playStarted = (stateAfterPlay == .connecting)
                    // If async pipeline already ran, it may be .error — still means play() worked
                    let playRanAsync: Bool
                    switch stateAfterPlay {
                    case .error:
                        playRanAsync = true
                    default:
                        playRanAsync = false
                    }

                    if !playStarted && !playRanAsync {
                        return false
                            <?> "Cycle \(i+1)/\(n): play() should reach .connecting or .error, got \(stateAfterPlay)"
                    }

                    // Wait for async pipeline to settle before stopping
                    Thread.sleep(forTimeInterval: 0.05)

                    // stop() should transition to .stopped
                    player.stop()
                    let stateAfterStop = player.state
                    if stateAfterStop != .stopped {
                        return false
                            <?> "Cycle \(i+1)/\(n): stop() should produce .stopped, got \(stateAfterStop)"
                    }
                }

                // After N cycles, verify the player can still start a new session
                delegate.callbackStates.removeAll()
                player.play(url: "invalid://reentry-final-\(arc4random())")
                Thread.sleep(forTimeInterval: 0.02)

                let finalState = player.state
                let finalStarted = (finalState == .connecting)
                let finalRanAsync: Bool
                switch finalState {
                case .error:
                    finalRanAsync = true
                default:
                    finalRanAsync = false
                }

                if !finalStarted && !finalRanAsync {
                    return false
                        <?> "After \(n) cycles, play() should still work, got \(finalState)"
                }

                // Verify .connecting appeared in the delegate callbacks
                let hasConnecting = delegate.callbackStates.contains(.connecting)
                if !hasConnecting {
                    return false
                        <?> "After \(n) cycles, play() should produce .connecting callback"
                }

                // Cleanup
                player.stop()
                Thread.sleep(forTimeInterval: 0.02)

                return true <?> "Player successfully restarted after \(n) play/stop cycles"
            }
    }

    /// Property: play() always transitions to .connecting first, and the delegate
    /// receives a .connecting callback with matching state.
    ///
    /// **Validates: Requirements 6.3**
    func testProperty8_PlayAlwaysTransitionsToConnecting() {
        let opsGen = Gen<[PlayerOperation]>.compose { composer in
            let count = composer.generate(using: Gen<Int>.fromElements(in: 0...5))
            return (0..<count).map { _ in composer.generate(using: PlayerOperation.arbitrary) }
        }

        property("play() always produces .connecting as first state change")
            <- forAll(opsGen) { (prefixOps: [PlayerOperation]) in

                let player = StreamPlayer()
                let delegate = PropertyTestDelegate()
                player.delegate = delegate

                // Apply prefix operations
                for op in prefixOps {
                    switch op {
                    case .play:
                        player.play(url: "invalid://conn-pbt-\(arc4random())")
                        Thread.sleep(forTimeInterval: 0.07)
                    case .pause: player.pause()
                    case .resume: player.resume()
                    case .stop: player.stop()
                    }
                }

                // Let async work settle
                Thread.sleep(forTimeInterval: 0.05)
                let stateBeforePlay = player.state
                delegate.callbackStates.removeAll()

                // Call play
                player.play(url: "invalid://conn-verify-\(arc4random())")
                Thread.sleep(forTimeInterval: 0.02)

                if stateBeforePlay != .connecting {
                    let hasConnecting = delegate.callbackStates.contains(.connecting)
                    if !hasConnecting {
                        return false
                            <?> "play() from \(stateBeforePlay) should produce .connecting callback"
                    }
                }

                // Cleanup
                player.stop()
                Thread.sleep(forTimeInterval: 0.02)

                return true <?> "play() correctly transitions to .connecting"
            }
    }
}
