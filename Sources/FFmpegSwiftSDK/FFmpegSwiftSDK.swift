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
// - ``AudioEffects``          — 音频效果控制器：音量、变速不变调、变调不变速、响度标准化、淡入淡出。
//
// ### 音频可视化
// - ``SpectrumAnalyzer``      — 实时 FFT 频谱分析器，输出频率幅度数据供 UI 绘制。
// - ``WaveformGenerator``     — 波形预览生成器，解码整首歌生成波形缩略图数据。
//
// ### 元数据
// - ``MetadataReader``        — 读取 ID3 标签、专辑封面、艺术家等元数据。
// - ``AudioMetadata``         — 元数据结构体。
//
// ### 歌词同步
// - ``LyricSyncer``           — 实时歌词同步引擎，LRC 解析 + 时间对准。
// - ``LyricParser``           — LRC 格式解析器（标准/增强/多时间标签）。
// - ``LyricLine``             — 歌词行数据（时间、文字、逐字、翻译）。
// - ``LyricWord``             — 逐字歌词数据（起止时间 + 文字）。
// - ``LyricMetadata``         — LRC 文件元信息（标题、艺术家等）。
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
