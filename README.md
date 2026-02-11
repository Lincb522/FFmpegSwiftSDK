# FFmpegSwiftSDK

A Swift SDK wrapping FFmpeg for iOS streaming media playback with real-time 10-band audio equalization and HiFi audio support.

## Features

- **Streaming Playback** — RTMP, HLS, RTSP, HTTP(S), local files
- **30+ Audio Codecs** — AAC, MP3, FLAC, ALAC, Opus, Vorbis, WAV/PCM, WavPack, APE, DSD, AC3, DTS, WMA, and more
- **Video Codecs** — H.264, HEVC (H.265)
- **10-Band Parametric EQ** — Real-time equalization from 31 Hz to 16 kHz, applied on the audio render thread
- **HiFi Audio** — Supports up to 192 kHz / 32-bit via CoreAudio AudioUnit
- **A/V Sync** — Audio-clock-based synchronization with frame drop/repeat logic
- **Swift Package Manager** — Integrates as a standard SPM package

## Requirements

- iOS 16.0+
- macOS 13.0+ (development/testing)
- Xcode 15.0+
- Swift 5.9+

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Lincb522/FFmpegSwiftSDK.git", from: "0.1.0")
]
```

Or in Xcode: File → Add Package Dependencies → paste the repository URL.

> **Note:** The package includes a prebuilt `FFmpegLibs.xcframework` (~64 MB) tracked via Git LFS. Make sure `git-lfs` is installed before cloning.

## Quick Start

```swift
import FFmpegSwiftSDK

let player = StreamPlayer()
player.delegate = self
player.play(url: "https://example.com/music.flac")

// 10-band EQ
player.equalizer.setGain(6.0, for: .hz125)   // boost bass
player.equalizer.setGain(-3.0, for: .hz4k)   // cut presence

// Playback control
player.pause()
player.resume()
player.stop()
```

### StreamPlayerDelegate

```swift
extension MyClass: StreamPlayerDelegate {
    func player(_ player: StreamPlayer, didChangeState state: PlaybackState) {
        // .idle, .connecting, .playing, .paused, .stopped, .error(_)
    }

    func player(_ player: StreamPlayer, didEncounterError error: FFmpegError) {
        print(error.description)
    }

    func player(_ player: StreamPlayer, didUpdateDuration duration: TimeInterval) {
        // Total duration in seconds
    }
}
```

### Stream Info & HiFi Detection

```swift
if let info = player.streamInfo {
    print(info.audioCodec)    // "flac"
    print(info.sampleRate)    // 96000
    print(info.bitDepth)      // 24
    print(info.channelCount)  // 2

    let isHiRes = (info.sampleRate ?? 0) > 48000 || (info.bitDepth ?? 0) > 16
}
```

### EQ Bands

| Band | Frequency |
|------|-----------|
| `.hz31` | 31 Hz |
| `.hz62` | 62 Hz |
| `.hz125` | 125 Hz |
| `.hz250` | 250 Hz |
| `.hz500` | 500 Hz |
| `.hz1k` | 1 kHz |
| `.hz2k` | 2 kHz |
| `.hz4k` | 4 kHz |
| `.hz8k` | 8 kHz |
| `.hz16k` | 16 kHz |

Gain range: -12 dB to +12 dB. Values outside this range are clamped automatically.

## Architecture

```
┌─────────────────────────────────────────────┐
│                Public API                    │
│   StreamPlayer  ·  AudioEqualizer           │
├─────────────────────────────────────────────┤
│                Engine                        │
│  ConnectionManager → Demuxer → Decoders     │
│  AudioRenderer (CoreAudio) · VideoRenderer  │
│  EQFilter · AVSyncController                │
├─────────────────────────────────────────────┤
│              Bridge Layer                    │
│  FFmpegFormatContext · FFmpegCodecContext    │
├─────────────────────────────────────────────┤
│              CFFmpeg (C module)              │
│  module.modulemap → FFmpeg C headers        │
├─────────────────────────────────────────────┤
│           FFmpegLibs.xcframework             │
│  libavformat · libavcodec · libavutil        │
│  libswresample · libavfilter                 │
└─────────────────────────────────────────────┘
```

## Building FFmpeg from Source

See [BUILD.md](BUILD.md) for instructions on cross-compiling FFmpeg 7.1 for iOS.

## Example App

The `Example/` directory contains a SwiftUI HiFi player demo with:
- Dark theme UI with gradient background
- Transport controls (play/pause/stop)
- Collapsible 10-band EQ with custom vertical sliders
- HiFi quality indicator (Hi-Res 无损 / 无损音质)
- Stream info display (codec, sample rate, bit depth, channels)

To run:
```bash
# Install xcodegen if needed
brew install xcodegen

# Generate Xcode project
xcodegen generate --spec Example/project.yml --project Example/

# Open in Xcode, select simulator, build & run
```

## License

MIT License. See [LICENSE](LICENSE).

FFmpeg is licensed under LGPL 2.1. This SDK links FFmpeg as a static library. See [FFmpeg License](https://ffmpeg.org/legal.html).
