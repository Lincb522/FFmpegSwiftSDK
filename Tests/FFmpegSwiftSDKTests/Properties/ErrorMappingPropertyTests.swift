// ErrorMappingPropertyTests.swift
// FFmpegSwiftSDKTests
//
// Property-based tests for FFmpegError error code mapping.
// **Validates: Requirements 7.4, 8.2, 8.3**

import XCTest
import SwiftCheck
@testable import FFmpegSwiftSDK

final class ErrorMappingPropertyTests: XCTestCase {

    // MARK: - Property 10: 错误码映射完整性
    //
    // For any negative Int32 error code, FFmpegError.from(code:) should return
    // a valid FFmpegError instance where:
    //   1. The instance is valid (guaranteed by Swift type system)
    //   2. description is non-empty
    //   3. ffmpegCode is a valid negative Int32
    //
    // Note: ffmpegCode does NOT always equal the original input code.
    // Some error cases map multiple input codes to a single canonical code:
    //   - networkDisconnected: both ECONNRESET(-104) and EPIPE(-32) → ffmpegCode = -104
    //   - connectionTimeout: always returns -110
    //   - unsupportedFormat: always returns DECODER_NOT_FOUND code
    //   - resourceAllocationFailed: always returns -12
    // Only the .unknown(code:) case preserves the original input code exactly.
    //
    // **Validates: Requirements 7.4, 8.2, 8.3**

    func testProperty10_ErrorCodeMappingCompleteness() {
        // Generator: random negative Int32 values (FFmpeg error codes are negative)
        let negativeInt32Gen: Gen<Int32> = Gen<Int32>.fromElements(in: Int32.min ... -1)

        property("Every negative Int32 maps to a valid FFmpegError with non-empty description and valid ffmpegCode")
            <- forAll(negativeInt32Gen) { (code: Int32) in
                let error = FFmpegError.from(code: code)

                // 1. from(code:) returns a valid FFmpegError instance (guaranteed by type system)

                // 2. description must be non-empty
                let descriptionNonEmpty = !error.description.isEmpty

                // 3. ffmpegCode must be a valid negative Int32.
                //    For .unknown(code:), ffmpegCode equals the original input.
                //    For known mapped cases, ffmpegCode returns the canonical code for that error type.
                let ffmpegCode = error.ffmpegCode
                let codeIsNegative = ffmpegCode < 0

                // 4. For .unknown case, ffmpegCode must exactly equal the input code
                let unknownCodePreserved: Bool
                if case .unknown(let unknownCode) = error {
                    unknownCodePreserved = unknownCode == code
                } else {
                    // For known cases, ffmpegCode is a canonical negative code (already checked above)
                    unknownCodePreserved = true
                }

                return descriptionNonEmpty <?> "description is non-empty"
                    ^&&^
                    codeIsNegative <?> "ffmpegCode (\(ffmpegCode)) is negative"
                    ^&&^
                    unknownCodePreserved <?> "unknown case preserves original code (\(code))"
            }
    }
}
