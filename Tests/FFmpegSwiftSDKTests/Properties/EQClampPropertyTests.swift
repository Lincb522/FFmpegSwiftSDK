// EQClampPropertyTests.swift
// FFmpegSwiftSDKTests
//
// Property-based tests for EQBandGain.clamped(_:) gain clamping correctness.
// **Validates: Requirements 5.3, 5.4**

import XCTest
import SwiftCheck
@testable import FFmpegSwiftSDK

final class EQClampPropertyTests: XCTestCase {

    // MARK: - Property 4: 增益钳位正确性
    //
    // For any finite Float x, EQBandGain.clamped(x) must satisfy:
    //   1. The result is always within [-12.0, 12.0]
    //   2. When x is in [-12.0, 12.0], clamped(x) == x
    //   3. When x < -12.0, clamped(x) == -12.0
    //   4. When x > 12.0, clamped(x) == 12.0
    //
    // **Validates: Requirements 5.3, 5.4**

    func testProperty4_GainClampCorrectness() {
        // Generator: arbitrary finite Float values (filter out NaN and infinity)
        let finiteFloatGen = Float.arbitrary.suchThat { !$0.isNaN && !$0.isInfinite }

        property("clamped value is always in [-12, 12] and preserves in-range values or clamps to boundary")
            <- forAll(finiteFloatGen) { (x: Float) in
                let result = EQBandGain.clamped(x)
                let minGain = EQBandGain.minGain  // -12.0
                let maxGain = EQBandGain.maxGain   // +12.0

                // 1. Result is always within [-12.0, 12.0]
                let inRange = result >= minGain && result <= maxGain

                // 2. When x is in [-12.0, 12.0], clamped(x) == x
                // 3. When x < -12.0, clamped(x) == -12.0
                // 4. When x > 12.0, clamped(x) == 12.0
                let correctValue: Bool
                if x < minGain {
                    correctValue = result == minGain
                } else if x > maxGain {
                    correctValue = result == maxGain
                } else {
                    correctValue = result == x
                }

                return inRange <?> "result \(result) is in [-12, 12]"
                    ^&&^
                    correctValue <?> "clamped(\(x)) == \(result) is correct"
            }
    }
}
