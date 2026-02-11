// AudioEqualizer.swift
// FFmpegSwiftSDK
//
// Public API for the three-band audio equalizer. Wraps the internal EQFilter
// and adds delegate notification when gain values are clamped.

import Foundation

// MARK: - AudioEqualizerDelegate

/// Delegate protocol for receiving notifications when a gain value is clamped
/// to the valid range [-12 dB, +12 dB].
public protocol AudioEqualizerDelegate: AnyObject {
    /// Called when a requested gain value was outside the valid range and was clamped.
    ///
    /// - Parameters:
    ///   - eq: The equalizer that performed the clamping.
    ///   - original: The originally requested gain value in dB.
    ///   - clamped: The actual gain value after clamping.
    ///   - band: The frequency band the gain was set for.
    func equalizer(_ eq: AudioEqualizer, didClampGain original: Float, to clamped: Float, for band: EQBand)
}

// MARK: - AudioEqualizer

/// A three-band audio equalizer providing gain control for low, mid, and high
/// frequency bands.
///
/// `AudioEqualizer` wraps the internal `EQFilter` and exposes a safe public API.
/// When a gain value outside [-12, +12] dB is provided, it is clamped to the
/// nearest boundary and the delegate is notified.
///
/// Access this equalizer through `StreamPlayer.equalizer`.
///
/// Usage:
/// ```swift
/// let player = StreamPlayer()
/// player.equalizer.delegate = self
/// player.equalizer.setGain(6.0, for: .low)
/// player.equalizer.setGain(-3.0, for: .mid)
/// let currentGain = player.equalizer.gain(for: .high)
/// player.equalizer.reset()
/// ```
public final class AudioEqualizer {

    // MARK: - Properties

    /// Delegate for receiving gain clamping notifications.
    public weak var delegate: AudioEqualizerDelegate?

    /// The underlying EQ filter that performs the actual audio processing.
    internal let filter: EQFilter

    // MARK: - Initialization

    /// Creates a new `AudioEqualizer` wrapping the given `EQFilter`.
    ///
    /// - Parameter filter: The internal EQ filter to wrap.
    internal init(filter: EQFilter) {
        self.filter = filter
    }

    // MARK: - Public API

    /// Sets the gain for a specific frequency band.
    ///
    /// If the value is outside the valid range [-12.0, +12.0] dB, it is clamped
    /// to the nearest boundary and the delegate is notified via
    /// `equalizer(_:didClampGain:to:for:)`.
    ///
    /// This method is thread-safe.
    ///
    /// - Parameters:
    ///   - gainDB: The desired gain in dB.
    ///   - band: The frequency band to adjust.
    public func setGain(_ gainDB: Float, for band: EQBand) {
        let clamped = filter.setGain(gainDB, for: band)
        if clamped != gainDB {
            delegate?.equalizer(self, didClampGain: gainDB, to: clamped, for: band)
        }
    }

    /// Returns the current gain for a specific frequency band.
    ///
    /// This method is thread-safe.
    ///
    /// - Parameter band: The frequency band to query.
    /// - Returns: The current gain in dB.
    public func gain(for band: EQBand) -> Float {
        return filter.gain(for: band)
    }

    /// Resets all frequency bands to 0 dB gain.
    ///
    /// This method is thread-safe.
    public func reset() {
        filter.reset()
    }
}
