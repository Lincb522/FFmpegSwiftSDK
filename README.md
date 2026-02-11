<p align="center">
  <h1 align="center">🎵 FFmpegSwiftSDK</h1>
  <p align="center">
    基于 FFmpeg 7.1 的 iOS 流媒体播放 Swift SDK<br/>
    支持实时 10 段 EQ 均衡器 · HiFi 无损音频 · 音视频同步
  </p>
  <p align="center">
    <img src="https://img.shields.io/badge/platform-iOS%2016%2B-blue?style=flat-square" />
    <img src="https://img.shields.io/badge/swift-5.9%2B-orange?style=flat-square" />
    <img src="https://img.shields.io/badge/FFmpeg-7.1-green?style=flat-square" />
    <img src="https://img.shields.io/badge/license-MIT-lightgrey?style=flat-square" />
    <img src="https://img.shields.io/badge/SPM-compatible-brightgreen?style=flat-square" />
  </p>
</p>

---

## ✨ 特性

| 功能 | 说明 |
|:---:|:---|
| 🎧 流媒体播放 | RTMP / HLS / RTSP / HTTP(S) / 本地文件 |
| 🎼 30+ 音频解码器 | AAC、MP3、FLAC、ALAC、Opus、Vorbis、WAV/PCM、WavPack、APE、DSD、AC3、DTS、WMA 等 |
| 🎬 视频解码 | H.264、HEVC (H.265) |
| 🎛️ 10 段参数 EQ | 31Hz ~ 16kHz 实时均衡，渲染线程处理，零延迟 |
| 🎵 HiFi 音频 | 最高支持 192kHz / 32bit，CoreAudio AudioUnit 直出 |
| 🔄 音视频同步 | 基于音频时钟的 A/V 同步，自动丢帧/重复帧 |
| 📦 SPM 集成 | 标准 Swift Package Manager，一行引入 |

---

## 📋 环境要求

- iOS 16.0+
- macOS 13.0+（开发/测试）
- Xcode 15.0+
- Swift 5.9+

---

## 🚀 安装

### Swift Package Manager

在 `Package.swift` 中添加：

```swift
dependencies: [
    .package(url: "https://github.com/Lincb522/FFmpegSwiftSDK.git", from: "0.1.0")
]
```

或在 Xcode 中：**File → Add Package Dependencies** → 粘贴仓库地址。

> 💡 本库包含预编译的 `FFmpegLibs.xcframework`（约 64MB），通过 Git LFS 管理。克隆前请确保已安装 `git-lfs`。

---

## 📖 快速上手

### 基础播放

```swift
import FFmpegSwiftSDK

let player = StreamPlayer()
player.delegate = self
player.play(url: "https://example.com/music.flac")

// 播放控制
player.pause()
player.resume()
player.stop()
```

### 实时 EQ 均衡器

```swift
// 增强低音
player.equalizer.setGain(6.0, for: .hz125)

// 削减中高频
player.equalizer.setGain(-3.0, for: .hz4k)

// 重置所有频段
player.equalizer.reset()
```

### 播放状态回调

```swift
extension MyClass: StreamPlayerDelegate {
    func player(_ player: StreamPlayer, didChangeState state: PlaybackState) {
        // .idle / .connecting / .playing / .paused / .stopped / .error(_)
    }

    func player(_ player: StreamPlayer, didEncounterError error: FFmpegError) {
        print(error.description)
    }

    func player(_ player: StreamPlayer, didUpdateDuration duration: TimeInterval) {
        // 总时长（秒）
    }
}
```

### 流信息 & HiFi 检测

```swift
if let info = player.streamInfo {
    print(info.audioCodec)    // "flac"
    print(info.sampleRate)    // 96000
    print(info.bitDepth)      // 24
    print(info.channelCount)  // 2

    // 判断是否为 Hi-Res 音频
    let isHiRes = (info.sampleRate ?? 0) > 48000 || (info.bitDepth ?? 0) > 16
}
```

---

## 🎛️ EQ 频段


| 频段 | 频率 | 典型用途 |
|:---:|:---:|:---|
| `.hz31` | 31 Hz | 超低频，体感震动 |
| `.hz62` | 62 Hz | 低音下潜 |
| `.hz125` | 125 Hz | 低音力度 |
| `.hz250` | 250 Hz | 低中频温暖感 |
| `.hz500` | 500 Hz | 中频厚度 |
| `.hz1k` | 1 kHz | 中频人声 |
| `.hz2k` | 2 kHz | 中高频清晰度 |
| `.hz4k` | 4 kHz | 高频存在感 |
| `.hz8k` | 8 kHz | 高频明亮度 |
| `.hz16k` | 16 kHz | 超高频空气感 |

> 增益范围：**-12 dB** ~ **+12 dB**，超出范围自动钳位。

---

## 🏗️ 架构

```
┌─────────────────────────────────────────────────┐
│              📱 Public API 层                    │
│         StreamPlayer  ·  AudioEqualizer          │
├─────────────────────────────────────────────────┤
│              ⚙️ Engine 引擎层                    │
│   ConnectionManager → Demuxer → AudioDecoder    │
│   AudioRenderer (CoreAudio) · VideoRenderer     │
│   EQFilter · AVSyncController · VideoDecoder    │
├─────────────────────────────────────────────────┤
│              🔗 Bridge 桥接层                    │
│   FFmpegFormatContext · FFmpegCodecContext       │
├─────────────────────────────────────────────────┤
│              📐 CFFmpeg (C 模块)                 │
│   module.modulemap → FFmpeg C 头文件             │
├─────────────────────────────────────────────────┤
│              📚 FFmpegLibs.xcframework           │
│   libavformat · libavcodec · libavutil           │
│   libswresample · libavfilter                    │
└─────────────────────────────────────────────────┘
```

---

## 🔨 从源码编译 FFmpeg

详见 [BUILD.md](BUILD.md)。

---

## 📱 示例应用

`Example/` 目录包含一个完整的 SwiftUI HiFi 播放器 Demo：

- 🌙 暗色主题 + 渐变背景
- ▶️ 播放 / 暂停 / 停止控制
- 🎛️ 可折叠 10 段 EQ 均衡器（自定义垂直滑块）
- 💎 HiFi 品质指示（Hi-Res 无损 / 无损音质）
- 📊 流信息展示（编码格式、采样率、位深、声道数）

```bash
# 安装 xcodegen（如未安装）
brew install xcodegen

# 生成 Xcode 工程
xcodegen generate --spec Example/project.yml --project Example/

# 用 Xcode 打开，选择模拟器，编译运行
```

---

## 📄 许可证

本项目采用 [MIT 许可证](LICENSE)。

FFmpeg 采用 LGPL 2.1 许可证，本 SDK 以静态库方式链接 FFmpeg。详见 [FFmpeg 许可证](https://ffmpeg.org/legal.html)。

---

<p align="center">
  用 ❤️ 和 Swift 构建
</p>
