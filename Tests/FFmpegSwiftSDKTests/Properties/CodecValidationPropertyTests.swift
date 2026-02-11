// CodecValidationPropertyTests.swift
// FFmpegSwiftSDKTests
//
// Property-based tests for unsupported codec format error handling.
// **Validates: Requirements 3.4**

import XCTest
import SwiftCheck
@testable import FFmpegSwiftSDK
import CFFmpeg

// MARK: - Unsupported Codec ID Generator

/// The combined set of all supported codec ID raw values (audio + video).
/// Used to filter out supported codecs from generated random values.
private let allSupportedCodecIDs: Set<UInt32> = supportedAudioCodecIDs.union(supportedVideoCodecIDs)

/// Generates random UInt32 values that are NOT in the supported codec ID sets.
/// These represent unsupported codec IDs that should trigger unsupportedFormat errors.
///
/// Strategy:
///   - Generate random UInt32 values across a wide range
///   - Filter out any values that happen to match supported codec IDs
///     (AV_CODEC_ID_AAC, AV_CODEC_ID_MP3, AV_CODEC_ID_H264, AV_CODEC_ID_HEVC)
private let unsupportedCodecIDGen: Gen<UInt32> = Gen<UInt32>.fromElements(
    in: 0...UInt32(500)
).suchThat { !allSupportedCodecIDs.contains($0) }

final class CodecValidationPropertyTests: XCTestCase {

    // MARK: - Property 2: 不支持编解码格式错误处理
    //
    // For any codec ID NOT in the supported list (H.264, H.265, AAC, MP3),
    // calling validateCodecSupported should throw FFmpegError.unsupportedFormat,
    // and the error message should contain a codec name (non-empty string).
    //
    // Strategy:
    //   1. Generate random UInt32 values not in the supported codec ID sets.
    //   2. Convert to AVCodecID and call validateCodecSupported with both
    //      supportedAudioCodecIDs and supportedVideoCodecIDs.
    //   3. Verify that the call throws FFmpegError.unsupportedFormat.
    //   4. Verify the error contains a non-empty codec name.
    //
    // **Validates: Requirements 3.4**

    func testProperty2_UnsupportedCodecFormatErrorHandling() {
        property("Unsupported codec IDs cause validateCodecSupported to throw unsupportedFormat with non-empty codec name")
            <- forAll(unsupportedCodecIDGen) { (rawCodecID: UInt32) in
                let codecID = AVCodecID(rawValue: rawCodecID)

                // Test against audio supported set
                let audioResult = self.validateThrowsUnsupportedFormat(
                    codecID: codecID,
                    supportedIDs: supportedAudioCodecIDs
                )

                // Test against video supported set
                let videoResult = self.validateThrowsUnsupportedFormat(
                    codecID: codecID,
                    supportedIDs: supportedVideoCodecIDs
                )

                return audioResult ^&&^ videoResult
            }
    }

    // MARK: - Helpers

    /// Validates that calling `validateCodecSupported` with the given codec ID
    /// throws `FFmpegError.unsupportedFormat` with a non-empty codec name.
    ///
    /// - Parameters:
    ///   - codecID: The codec ID to test.
    ///   - supportedIDs: The set of supported codec IDs to validate against.
    /// - Returns: A `Testable` property result.
    private func validateThrowsUnsupportedFormat(
        codecID: AVCodecID,
        supportedIDs: Set<UInt32>
    ) -> Property {
        do {
            try validateCodecSupported(codecID, in: supportedIDs)
            // Should have thrown - this is a failure
            return (false <?> "validateCodecSupported did not throw for codec ID \(codecID.rawValue)")
        } catch let error as FFmpegError {
            // Verify it's specifically unsupportedFormat
            if case .unsupportedFormat(let codecName) = error {
                let nameNonEmpty = !codecName.isEmpty
                return nameNonEmpty <?> "codec name is non-empty for codec ID \(codecID.rawValue), got: '\(codecName)'"
            } else {
                return (false <?> "Expected unsupportedFormat but got \(error) for codec ID \(codecID.rawValue)")
            }
        } catch {
            return (false <?> "Unexpected non-FFmpegError: \(error) for codec ID \(codecID.rawValue)")
        }
    }
}
