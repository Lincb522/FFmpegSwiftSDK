// EQBand.swift
// FFmpegSwiftSDK
//
// Defines the EQ frequency bands and gain parameters for the audio equalizer.
// 10-band parametric EQ covering 31 Hz to 16 kHz for HiFi-grade audio control.

import Foundation

/// Represents the ten frequency bands of the audio equalizer.
///
/// Standard 10-band EQ with ISO center frequencies covering the full
/// audible spectrum from sub-bass to brilliance.
public enum EQBand: Int, CaseIterable, Comparable {
    /// Sub-bass: 31 Hz
    case hz31 = 0
    /// Bass: 62 Hz
    case hz62 = 1
    /// Low-mid: 125 Hz
    case hz125 = 2
    /// Mid: 250 Hz
    case hz250 = 3
    /// Mid: 500 Hz
    case hz500 = 4
    /// Upper-mid: 1 kHz
    case hz1k = 5
    /// Presence: 2 kHz
    case hz2k = 6
    /// Brilliance: 4 kHz
    case hz4k = 7
    /// Brilliance: 8 kHz
    case hz8k = 8
    /// Air: 16 kHz
    case hz16k = 9

    /// The center frequency of this band, in Hz.
    public var centerFrequency: Float {
        switch self {
        case .hz31:  return 31
        case .hz62:  return 62
        case .hz125: return 125
        case .hz250: return 250
        case .hz500: return 500
        case .hz1k:  return 1000
        case .hz2k:  return 2000
        case .hz4k:  return 4000
        case .hz8k:  return 8000
        case .hz16k: return 16000
        }
    }

    /// 每个频段的 Q 值（带宽控制）。
    /// 低频段用更低的 Q（更宽带宽）以获得更饱满的低频体感，
    /// 高频段用稍高的 Q 以保持精确度。
    /// 整体比默认 Q=1.0 更宽，让 10 段之间无缝衔接。
    public var q: Float {
        switch self {
        case .hz31:  return 0.5   // 超低频需要宽带宽
        case .hz62:  return 0.6
        case .hz125: return 0.7
        case .hz250: return 0.7
        case .hz500: return 0.8
        case .hz1k:  return 0.8
        case .hz2k:  return 0.8
        case .hz4k:  return 0.7
        case .hz8k:  return 0.6
        case .hz16k: return 0.5   // 超高频也需要宽带宽
        }
    }

    /// Human-readable label for this band.
    public var label: String {
        switch self {
        case .hz31:  return "31"
        case .hz62:  return "62"
        case .hz125: return "125"
        case .hz250: return "250"
        case .hz500: return "500"
        case .hz1k:  return "1k"
        case .hz2k:  return "2k"
        case .hz4k:  return "4k"
        case .hz8k:  return "8k"
        case .hz16k: return "16k"
        }
    }

    public static func < (lhs: EQBand, rhs: EQBand) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Represents a gain setting for a specific EQ frequency band.
public struct EQBandGain {
    public let band: EQBand
    public let gainDB: Float

    public static let minGain: Float = -12.0
    public static let maxGain: Float = 12.0

    public static func clamped(_ value: Float) -> Float {
        min(max(value, minGain), maxGain)
    }

    public init(band: EQBand, gainDB: Float) {
        self.band = band
        self.gainDB = gainDB
    }
}
