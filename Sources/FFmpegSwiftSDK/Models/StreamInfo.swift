// StreamInfo.swift
// FFmpegSwiftSDK
//
// Describes the streams found in a media container after demuxing.
// Contains metadata about audio and video streams such as codec names,
// sample rates, dimensions, and duration.

import Foundation

/// Metadata describing the audio and video streams found in a media container.
///
/// `StreamInfo` is produced by `Demuxer.findStreams()` after analyzing the
/// format context. It provides a high-level summary of what the media contains
/// without exposing FFmpeg internals.
///
/// - Note: For live streams (e.g., RTMP, RTSP), `duration` will be `nil`.
public struct StreamInfo {

    /// The URL of the media source that was opened.
    public let url: String

    /// Whether the container includes at least one audio stream.
    public let hasAudio: Bool

    /// Whether the container includes at least one video stream.
    public let hasVideo: Bool

    /// The name of the audio codec (e.g., "aac", "mp3"), or `nil` if no audio stream exists.
    public let audioCodec: String?

    /// The name of the video codec (e.g., "h264", "hevc"), or `nil` if no video stream exists.
    public let videoCodec: String?

    /// The audio sample rate in Hz (e.g., 44100, 48000), or `nil` if no audio stream exists.
    public let sampleRate: Int?

    /// The number of audio channels (e.g., 1 for mono, 2 for stereo), or `nil` if no audio stream exists.
    public let channelCount: Int?

    /// The audio bit depth (e.g., 16, 24, 32), or `nil` if no audio stream exists.
    public let bitDepth: Int?

    /// The video frame width in pixels, or `nil` if no video stream exists.
    public let width: Int?

    /// The video frame height in pixels, or `nil` if no video stream exists.
    public let height: Int?

    /// The total duration of the media in seconds, or `nil` for live streams.
    public let duration: TimeInterval?

    /// Creates a new `StreamInfo` instance.
    ///
    /// - Parameters:
    ///   - url: The URL of the media source.
    ///   - hasAudio: Whether an audio stream was found.
    ///   - hasVideo: Whether a video stream was found.
    ///   - audioCodec: The audio codec name, or `nil`.
    ///   - videoCodec: The video codec name, or `nil`.
    ///   - sampleRate: The audio sample rate in Hz, or `nil`.
    ///   - channelCount: The number of audio channels, or `nil`.
    ///   - bitDepth: The audio bit depth, or `nil`.
    ///   - width: The video width in pixels, or `nil`.
    ///   - height: The video height in pixels, or `nil`.
    ///   - duration: The media duration in seconds, or `nil` for live streams.
    public init(
        url: String,
        hasAudio: Bool,
        hasVideo: Bool,
        audioCodec: String?,
        videoCodec: String?,
        sampleRate: Int?,
        channelCount: Int?,
        bitDepth: Int?,
        width: Int?,
        height: Int?,
        duration: TimeInterval?
    ) {
        self.url = url
        self.hasAudio = hasAudio
        self.hasVideo = hasVideo
        self.audioCodec = audioCodec
        self.videoCodec = videoCodec
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitDepth = bitDepth
        self.width = width
        self.height = height
        self.duration = duration
    }
}
