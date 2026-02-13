<p align="center">
  <img src="assets/logo.svg" width="180" alt="FFmpegSwiftSDK Logo" />
  <h1 align="center">FFmpegSwiftSDK</h1>
  <p align="center">
    基于 FFmpeg 8.0 的 iOS 流媒体播放 Swift SDK<br/>
    HiFi 无损 · 10 段 EQ · 实时音效 · 频谱分析 · 歌词同步 · 无缝切歌
  </p>
  <p align="center">
    <img src="https://img.shields.io/badge/platform-iOS%2016%2B-blue?style=flat-square" />
    <img src="https://img.shields.io/badge/swift-5.9%2B-orange?style=flat-square" />
    <img src="https://img.shields.io/badge/FFmpeg-8.0-green?style=flat-square" />
    <img src="https://img.shields.io/badge/license-MIT-lightgrey?style=flat-square" />
    <img src="https://img.shields.io/badge/SPM-compatible-brightgreen?style=flat-square" />
  </p>
</p>

---

## 特性一览

| 类别 | 功能 |
|:---|:---|
| 播放 | RTMP / HLS / RTSP / HTTP(S) / 本地文件，30+ 音频解码器，H.264 / HEVC 视频（VideoToolbox 硬解） |
| HiFi | 最高 192kHz / 32bit，FLAC / ALAC / DSD / WAV 无损直出，CoreAudio AudioUnit 渲染 |
| 均衡器 | 10 段参数 EQ（31Hz ~ 16kHz），渲染线程实时处理，零延迟 |
| 音效 | 音量 · 变速不变调 · 变调不变速 · 低音 · 高音 · 环绕 · 混响 · 响度标准化 · 淡入淡出 |
| 可视化 | 实时 FFT 频谱分析（vDSP 加速）· 波形预览生成 |
| 元数据 | ID3v1/v2 · Vorbis Comment · iTunes Metadata · 专辑封面提取 |
| 歌词 | LRC 解析 · 逐字同步 · 双语歌词 · 时间偏移调整 |
| 高级 | A-B 循环 · 无缝切歌（Gapless）· 交叉淡入淡出 · Seek |
| 同步 | 基于音频时钟的 A/V 同步，自动丢帧 / 重复帧补偿 |

---

## 环境要求

- iOS 16.0+ / macOS 13.0+（开发测试）
- Xcode 15.0+
- Swift 5.9+

---

## 安装

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/Lincb522/FFmpegSwiftSDK.git", from: "0.12.0")
]
```

或在 Xcode 中：**File → Add Package Dependencies** → 粘贴仓库地址。

> iOS 预编译库（`FFmpegLibs.xcframework`，约 28MB）通过 GitHub Release 自动下载，无需额外配置。

---

## 快速上手

### 基础播放

```swift
import FFmpegSwiftSDK

let player = StreamPlayer()
player.delegate = self
player.play(url: "https://example.com/music.flac")

player.pause()
player.resume()
player.seek(to: 60)
player.stop()
```

### 视频播放

```swift
// 将视频图层添加到视图
view.layer.addSublayer(player.videoDisplayLayer)
player.videoDisplayLayer.frame = view.bounds
player.play(url: "https://example.com/video.mp4")
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
    func playerDidTransitionToNextTrack(_ player: StreamPlayer) {
        // 无缝切歌完成
    }
}
```

---

## 10 段均衡器

```swift
player.equalizer.setGain(6.0, for: .hz125)   // 增强低音
player.equalizer.setGain(-3.0, for: .hz4k)   // 削减高频
player.equalizer.reset()                       // 重置全部
```

| 频段 | 频率 | 用途 |
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

增益范围 **-12 ~ +12 dB**，超出自动钳位并通过 `AudioEqualizerDelegate` 通知。

---

## 音频效果

所有效果通过 `player.audioEffects` 访问，基于 FFmpeg avfilter 实时处理：

```swift
// 音量
player.audioEffects.setVolume(3.0)              // +3dB

// 变速不变调（0.5x ~ 4.0x）
player.audioEffects.setTempo(1.5)

// 变调不变速（-12 ~ +12 半音）
player.audioEffects.setPitch(3)                 // 升 3 个半音

// 低音 / 高音增强
player.audioEffects.setBassGain(6.0)            // +6dB 低音
player.audioEffects.setTrebleGain(-3.0)         // -3dB 高音

// 环绕 / 混响（0 ~ 1）
player.audioEffects.setSurroundLevel(0.5)
player.audioEffects.setReverbLevel(0.3)

// 响度标准化（EBU R128）
player.audioEffects.setLoudnormEnabled(true)

// 淡入淡出
player.audioEffects.setFadeIn(duration: 3.0)    // 3 秒淡入
player.audioEffects.setFadeOut(duration: 5.0, startTime: 180.0)

// 重置全部
player.audioEffects.reset()
```

---

## 实时频谱分析

基于 vDSP 加速的 FFT 频谱分析器，输出归一化频率幅度数据供 UI 绘制：

```swift
player.spectrumAnalyzer.isEnabled = true
player.spectrumAnalyzer.smoothing = 0.7  // 平滑系数

player.spectrumAnalyzer.onSpectrum = { magnitudes in
    // magnitudes: [Float]，长度 = bandCount（默认 64）
    // 值范围 [0, 1]，在音频线程回调
    DispatchQueue.main.async {
        self.updateSpectrumUI(magnitudes)
    }
}
```

---

## 波形预览

独立于播放 pipeline，在后台解码整首歌生成波形缩略图：

```swift
let samples = try await player.waveformGenerator.generate(
    url: "file:///path/to/song.flac",
    samplesCount: 200,
    onProgress: { progress in
        print("波形生成进度: \(Int(progress * 100))%")
    }
)
// samples: [WaveformSample]
// 每个 sample 包含 .positive（正峰值）和 .negative（负峰值）
```

---

## 元数据读取

读取 ID3v1/v2、Vorbis Comment、iTunes Metadata 等标签：

```swift
let metadata = try player.metadataReader.read(url: "file:///path/to/song.flac")

print(metadata.title)       // 歌曲标题
print(metadata.artist)      // 艺术家
print(metadata.album)       // 专辑名

// 专辑封面（JPEG/PNG Data，可直接转 UIImage）
if let data = metadata.artworkData {
    let image = UIImage(data: data)
}

// 所有原始标签
for (key, value) in metadata.rawTags {
    print("\(key): \(value)")
}
```

---

## 歌词同步

LRC 解析 + 实时时间对准，支持标准 LRC、增强 LRC（逐字）、双语歌词：

```swift
// 加载 LRC 歌词
player.lyricSyncer.load(lrcContent: lrcString)

// 双语歌词
player.lyricSyncer.loadBilingual(
    originalLRC: chineseLRC,
    translationLRC: englishLRC
)

// 实时同步回调
player.lyricSyncer.onSync = { lineIndex, line, wordIndex, progress in
    // lineIndex: 当前行索引
    // line.text: 当前行文字
    // line.translation: 翻译（双语模式）
    // wordIndex: 逐字索引（增强 LRC）
    // progress: 行内进度 [0, 1]
}

// 时间偏移调整（秒，正值延后，负值提前）
player.lyricSyncer.offset = -0.5

// 获取附近歌词（滚动显示）
let nearby = player.lyricSyncer.nearbyLines(range: 3)
```

支持的 LRC 格式：

```
[ti:歌曲标题]
[ar:艺术家]
[00:05.00]这是一句歌词
[00:10.00][00:30.00]重复歌词（多时间标签）
[00:15.00]<00:15.00>逐<00:15.50>字<00:16.00>歌<00:16.50>词
```

---

## A-B 循环

精确区间循环，适用于练歌、学乐器等场景：

```swift
// 设置循环区间（播放到 B 点自动跳回 A 点）
player.setABLoop(pointA: 30.0, pointB: 60.0)

// 查询状态
player.isABLoopEnabled    // true
player.abLoopPointA       // 30.0
player.abLoopPointB       // 60.0

// 清除循环
player.clearABLoop()
```

---

## 无缝切歌 & 交叉淡入淡出

```swift
// 预加载下一首（后台连接 + 初始化解码器）
player.prepareNext(url: "https://example.com/next.flac")

// EOF 时自动无缝切换，或手动触发：
player.switchToNext()

// 交叉淡入淡出（当前歌曲淡出 + 下一首淡入）
player.setCrossfadeDuration(5.0)  // 5 秒交叉
```

---

## 流信息 & HiFi 检测

```swift
if let info = player.streamInfo {
    info.audioCodec      // "flac"
    info.sampleRate      // 96000
    info.bitDepth        // 24
    info.channelCount    // 2
    info.containerFormat // "flac"
    info.duration        // 245.3（秒）

    info.isLossless      // true
    info.isHiRes         // true（采样率 > 48kHz 或位深 > 16bit）
    info.qualityLabel    // "Hi-Res 24bit/96kHz"
}
```

---

## 编解码能力查询

```swift
// 支持的音频解码器
let audioCodecs = CodecCapabilities.supportedAudioCodecs
// [AudioCodecInfo(name: "aac", displayName: "AAC", isLossless: false, ...), ...]

// 支持的视频解码器
let videoCodecs = CodecCapabilities.supportedVideoCodecs

// 支持的容器格式
let formats = CodecCapabilities.supportedContainerFormats

// 支持的流协议
let protocols = CodecCapabilities.supportedProtocols

// 支持的音频滤镜
let filters = CodecCapabilities.supportedAudioFilters
```

---

## 架构

```
┌──────────────────────────────────────────────────────────────┐
│                      📱 Public API 层                         │
│  StreamPlayer · AudioEqualizer · AudioEffects                │
│  CodecCapabilities                                           │
├──────────────────────────────────────────────────────────────┤
│                      ⚙️ Engine 引擎层                         │
│  ConnectionManager → Demuxer → AudioDecoder / VideoDecoder   │
│  AudioRenderer (CoreAudio) · VideoRenderer (AVSampleBuffer)  │
│  EQFilter · AudioFilterGraph · AVSyncController              │
│  SpectrumAnalyzer · WaveformGenerator                        │
│  MetadataReader · LyricSyncer / LyricParser                  │
├──────────────────────────────────────────────────────────────┤
│                      🔗 Bridge 桥接层                         │
│  FFmpegFormatContext · FFmpegCodecContext                     │
├──────────────────────────────────────────────────────────────┤
│                      📐 Core / Models                         │
│  FFmpegError · StreamInfo · VideoFrame · AudioBuffer · EQBand│
├──────────────────────────────────────────────────────────────┤
│                      🔧 CFFmpeg (C 模块)                      │
│  module.modulemap → FFmpeg 8.0 C 头文件                       │
├──────────────────────────────────────────────────────────────┤
│                      📦 FFmpegLibs.xcframework                │
│  libavformat · libavcodec · libavutil                        │
│  libswresample · libavfilter                                 │
└──────────────────────────────────────────────────────────────┘
```

数据流：

```
URL → ConnectionManager → Demuxer ─┬─ AudioDecoder → AudioFilterGraph → EQFilter → AudioRenderer
                                    └─ VideoDecoder → AVSyncController → VideoRenderer
```

---

## 支持的格式

### 音频解码器

| 类型 | 格式 |
|:---|:---|
| 有损 | AAC · MP3 · Opus · Vorbis · AC-3 · E-AC-3 · DTS · WMA · Cook |
| 无损 | FLAC · ALAC · WavPack · APE · TAK · TTA |
| PCM | 16bit / 24bit / 32bit / Float32 / Float64（Hi-Res） |
| DSD | DSD64 / DSD128（LSB/MSB） |

### 视频解码器

H.264/AVC · HEVC/H.265（均支持 VideoToolbox 硬件加速）

### 容器格式

MP4/M4A/MOV · MPEG-TS · FLV · HLS · MKV/WebM · Ogg · FLAC · WAV · MP3 · AAC

### 流协议

HTTP · HTTPS · HLS · RTMP · TCP · UDP · File · Concat · Data URI

---

## 示例应用

`Example/` 目录包含完整的 SwiftUI HiFi 播放器 Demo，展示所有 SDK 功能：

- 暗色主题 + 渐变背景
- 播放 / 暂停 / 停止 / Seek 控制
- 10 段 EQ 均衡器（自定义垂直滑块）
- 音频效果面板（音量、倍速、变调、低音、高音、环绕、混响、淡入、响度标准化）
- 实时频谱可视化动画
- 波形进度条（可点击 Seek）
- 元数据显示 + 专辑封面
- 歌词同步滚动显示 + 偏移调整
- A-B 循环设置
- HiFi 品质指示

```bash
# 安装 xcodegen（如未安装）
brew install xcodegen

# 生成 Xcode 工程
xcodegen generate --spec Example/project.yml --project Example/

# 用 Xcode 打开，选择模拟器，编译运行
```

---

## 从源码编译 FFmpeg

详见 [BUILD.md](BUILD.md)。

构建脚本位于 `scripts/` 目录：

| 脚本 | 用途 |
|:---|:---|
| `build-ffmpeg-ios.sh` | 交叉编译 FFmpeg for iOS（arm64 / x86_64） |
| `rebuild-sim-and-xcframework.sh` | 重建模拟器库 + 合并 xcframework |
| `rebuild-all.sh` | 完整重建（设备 + 模拟器 + xcframework） |
| `package-and-release.sh` | 打包 xcframework zip |
| `upload-release.sh` | 上传到 GitHub Release |

---

## 完整 API 参考

<details>
<summary>StreamPlayer</summary>

```swift
public final class StreamPlayer {
    // 播放控制
    func play(url: String)
    func pause()
    func resume()
    func stop()
    func seek(to time: TimeInterval)

    // 状态
    var state: PlaybackState { get }
    var currentTime: TimeInterval { get }
    var streamInfo: StreamInfo? { get }
    weak var delegate: StreamPlayerDelegate?

    // 子系统
    let equalizer: AudioEqualizer
    let audioEffects: AudioEffects
    let spectrumAnalyzer: SpectrumAnalyzer
    let waveformGenerator: WaveformGenerator
    let metadataReader: MetadataReader
    let lyricSyncer: LyricSyncer

    // 视频
    var videoDisplayLayer: AVSampleBufferDisplayLayer { get }
    var isVideoHardwareAccelerated: Bool { get }

    // A-B 循环
    func setABLoop(pointA: TimeInterval, pointB: TimeInterval)
    func clearABLoop()
    var isABLoopEnabled: Bool { get }
    var abLoopPointA: TimeInterval? { get }
    var abLoopPointB: TimeInterval? { get }

    // 无缝切歌
    func prepareNext(url: String)
    func switchToNext(seekTo: TimeInterval?)
    func cancelNextPreparation()

    // 交叉淡入淡出
    func setCrossfadeDuration(_ duration: Float)
    var currentCrossfadeDuration: Float { get }
}
```

</details>

<details>
<summary>AudioEffects</summary>

```swift
public final class AudioEffects {
    func setVolume(_ db: Float)
    var volume: Float { get }

    func setTempo(_ rate: Float)          // 0.5 ~ 4.0
    var tempo: Float { get }

    func setPitch(_ semitones: Float)     // -12 ~ +12
    var pitchSemitones: Float { get }

    func setBassGain(_ db: Float)         // -12 ~ +12
    var bassGain: Float { get }

    func setTrebleGain(_ db: Float)       // -12 ~ +12
    var trebleGain: Float { get }

    func setSurroundLevel(_ level: Float) // 0 ~ 1
    var surroundLevel: Float { get }

    func setReverbLevel(_ level: Float)   // 0 ~ 1
    var reverbLevel: Float { get }

    func setLoudnormEnabled(_ enabled: Bool)
    func setLoudnormParams(targetLUFS: Float, lra: Float, truePeak: Float)
    var isLoudnormEnabled: Bool { get }

    func setFadeIn(duration: Float)
    func setFadeOut(duration: Float, startTime: Float)

    func reset()
    var isActive: Bool { get }
}
```

</details>

<details>
<summary>LyricSyncer</summary>

```swift
public final class LyricSyncer {
    func load(lrcContent: String)
    func load(lines: [LyricLine])
    func loadBilingual(originalLRC: String, translationLRC: String)
    func clear()

    func update(time: TimeInterval)
    func line(at time: TimeInterval) -> LyricLine?
    func nearbyLines(range: Int) -> [(index: Int, line: LyricLine)]
    func reset()

    var onSync: LyricSyncCallback?
    var offset: TimeInterval
    var currentLineIndex: Int { get }
    var currentWordIndex: Int? { get }
    var isLoaded: Bool { get }
    var lines: [LyricLine] { get }
    var metadata: LyricMetadata? { get }
}
```

</details>

---

## 许可证

本项目采用 [MIT 许可证](LICENSE)。

FFmpeg 采用 LGPL 2.1 许可证，本 SDK 以静态库方式链接。详见 [FFmpeg 许可证](https://ffmpeg.org/legal.html)。
