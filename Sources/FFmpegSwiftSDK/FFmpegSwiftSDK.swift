// FFmpegSwiftSDK.swift
// FFmpegSwiftSDK
//
// Module entry point for the FFmpeg Swift SDK.
//
// This SDK wraps FFmpeg's C libraries through a Swift-friendly API, providing
// streaming media playback and real-time audio equalization capabilities.
//
// ## Public API Surface
//
// ### Playback
// - ``StreamPlayer``          — Main player class: connect, play, pause, resume, stop.
// - ``StreamPlayerDelegate``  — Delegate protocol for playback state, error, and duration callbacks.
// - ``PlaybackState``         — Enum representing player states (idle, connecting, playing, paused, stopped, error).
//
// ### Audio Equalizer
// - ``AudioEqualizer``        — Three-band EQ with gain control for low/mid/high frequencies.
// - ``AudioEqualizerDelegate``— Delegate protocol for gain clamping notifications.
// - ``EQBand``                — Frequency band enum (low: 20–300 Hz, mid: 300–4000 Hz, high: 4–20 kHz).
// - ``EQBandGain``            — Gain setting struct with clamping to [-12, +12] dB.
//
// ### Audio Effects
// - ``AudioEffects``          — 音频效果控制器：音量、变速不变调、响度标准化。
//
// ### SuperEqualizer
// - ``SuperEqualizer``        — 18 段高精度均衡器（基于 FFmpeg superequalizer 16383 阶 FIR 滤波器）。
// - ``SuperEQBand``           — 18 个频段枚举（65Hz ~ 20kHz）。
//
// ### Models
// - ``StreamInfo``            — Metadata about a media stream (codecs, dimensions, duration).
// - ``VideoFrame``            — Decoded video frame with CVPixelBuffer and timing info.
//
// ### Errors
// - ``FFmpegError``           — Unified error type mapping FFmpeg C error codes to Swift.
//
// ## Quick Start
//
// ```swift
// import FFmpegSwiftSDK
//
// let player = StreamPlayer()
// player.delegate = self
// player.play(url: "rtmp://example.com/live/stream")
//
// // Adjust EQ
// player.equalizer.setGain(6.0, for: .low)
// player.equalizer.setGain(-3.0, for: .mid)
//
// // Control playback
// player.pause()
// player.resume()
// player.stop()
// ```

import Foundation
