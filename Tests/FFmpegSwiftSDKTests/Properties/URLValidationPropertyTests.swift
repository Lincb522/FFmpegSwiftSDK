// URLValidationPropertyTests.swift
// FFmpegSwiftSDKTests
//
// Property-based tests for invalid URL error handling in ConnectionManager.
// **Validates: Requirements 2.4**

import XCTest
import SwiftCheck
@testable import FFmpegSwiftSDK

// MARK: - Invalid URL Generator

/// Known FFmpeg protocol prefixes that could cause real connection attempts
/// and long timeouts. We must avoid generating these as "invalid" URLs.
private let ffmpegProtocolPrefixes = [
    "rtp:", "srtp:", "udp:", "tcp:", "tls:", "srt:", "rist:",
    "rtmp:", "rtmps:", "rtmpt:", "rtmpte:", "rtmpts:",
    "rtsp:", "rtsps:",
    "http:", "https:",
    "hls:", "mmsh:", "mmst:",
    "ftp:", "sftp:", "smb:",
    "file:", "pipe:", "data:",
    "crypto:", "ffrtmphttp:", "ffrtmpcrypt:",
    "subfile:", "concat:", "async:",
]

/// Returns true if the string starts with any known FFmpeg protocol prefix,
/// which could cause FFmpeg to attempt a real (slow) connection.
private func looksLikeFFmpegProtocol(_ s: String) -> Bool {
    let lowered = s.lowercased()
    return ffmpegProtocolPrefixes.contains { lowered.hasPrefix($0) }
}

/// Generates random invalid URL strings that should never successfully connect.
/// Categories include:
///   - Empty strings
///   - Random ASCII garbage (no protocol scheme)
///   - Malformed protocol prefixes with unreachable hosts
///   - Strings with special characters and whitespace
///
/// IMPORTANT: We filter out any string that starts with a known FFmpeg protocol
/// prefix (e.g. "rtp:", "udp:", "tcp:") because FFmpeg may attempt a real
/// connection for those, causing long timeouts and false failures.
private let invalidURLGen: Gen<String> = Gen<String>.one(of: [
    // 1. Empty string
    Gen.pure(""),

    // 2. Random short ASCII strings (no valid protocol scheme)
    //    Prefix with "zqx" to ensure it's not a valid FFmpeg protocol
    Gen<Character>.fromElements(in: "a"..."z")
        .proliferate(withSize: 10)
        .map { "zqx" + String($0) },

    // 3. Malformed protocol prefixes with unreachable hosts ending in .invalid.test
    Gen<String>.fromElements(of: [
        "xyz://", "abc://", "notaprotocol://",
        "rtmp://", "rtsp://", "http://", "https://"
    ]).flatMap { prefix in
        Gen<Character>.fromElements(in: "a"..."z")
            .proliferate(withSize: 12)
            .map { prefix + String($0) + ".invalid.test" }
    },

    // 4. Strings with special characters (none are FFmpeg protocol prefixes)
    Gen<String>.fromElements(of: [
        "!!!@@@###$$",
        "   ",
        "\t\n\r",
        "://missing-scheme",
        "::",
        "//no-scheme"
    ]),

    // 5. Very long random strings (prefixed to avoid protocol match)
    Gen<Character>.fromElements(in: "a"..."z")
        .proliferate(withSize: 200)
        .map { "zzz" + String($0) }
]).suchThat { !looksLikeFFmpegProtocol($0) }

final class URLValidationPropertyTests: XCTestCase {

    // MARK: - Property 1: 无效 URL 错误处理
    //
    // For any invalid or unreachable URL string, ConnectionManager's connect
    // method should throw an FFmpegError. The error type should be one of the
    // FFmpegError cases (connectionFailed, connectionTimeout, unsupportedFormat,
    // resourceAllocationFailed, etc.).
    //
    // Strategy:
    //   1. Generate random invalid URL strings (garbage, malformed protocols,
    //      empty strings, unreachable hosts).
    //   2. Call ConnectionManager.connect(url:) with each generated URL.
    //   3. Verify that the call throws an FFmpegError.
    //
    // We bridge async connect() into the synchronous SwiftCheck property
    // by running each check inside a semaphore-blocked async task.
    //
    // **Validates: Requirements 2.4**

    func testProperty1_InvalidURLErrorHandling() {
        property("Invalid URLs cause ConnectionManager.connect to throw FFmpegError")
            <- forAll(invalidURLGen) { (url: String) in
                let manager = ConnectionManager()

                // Bridge async to sync for SwiftCheck
                let semaphore = DispatchSemaphore(value: 0)
                var thrownError: Error?
                var didThrow = false

                Task {
                    do {
                        _ = try await manager.connect(url: url)
                        // If connect succeeds unexpectedly, disconnect immediately
                        manager.disconnect()
                    } catch {
                        thrownError = error
                        didThrow = true
                    }
                    semaphore.signal()
                }

                // Wait with a generous timeout (connect has its own 10s timeout,
                // but invalid URLs should fail much faster)
                let waitResult = semaphore.wait(timeout: .now() + 15.0)

                if waitResult == .timedOut {
                    // If we timed out waiting, the test infrastructure failed
                    return false <?> "Timed out waiting for connect to complete for URL: \(url)"
                }

                // Verify that connect threw an error
                guard didThrow else {
                    return false <?> "connect(url:) did not throw for invalid URL: \(url)"
                }

                // Verify the error is an FFmpegError
                guard thrownError is FFmpegError else {
                    return false <?> "Error is not FFmpegError: \(String(describing: thrownError)) for URL: \(url)"
                }

                return true <?> "connect(url:) correctly threw FFmpegError for URL: \(url)"
            }
    }
}
