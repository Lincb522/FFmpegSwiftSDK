// StreamPlayer.swift
// FFmpegSwiftSDK
//
// Public API for streaming media playback. Orchestrates ConnectionManager,
// Demuxer, AudioDecoder, VideoDecoder, EQFilter, AudioRenderer, VideoRenderer,
// and AVSyncController into a unified playback pipeline.

import Foundation
import CFFmpeg
import AudioToolbox
import AVFoundation

// MARK: - PlaybackState

/// Represents the current state of the stream player.
public enum PlaybackState: Equatable {
    /// No playback session is active.
    case idle
    /// Connecting to the media source.
    case connecting
    /// Actively playing audio/video.
    case playing
    /// Playback is paused.
    case paused
    /// Playback has been stopped.
    case stopped
    /// An error occurred during playback.
    case error(FFmpegError)
}

// MARK: - StreamPlayerDelegate

/// Delegate protocol for receiving playback state changes, errors, and duration updates.
public protocol StreamPlayerDelegate: AnyObject {
    /// Called when the player's playback state changes.
    func player(_ player: StreamPlayer, didChangeState state: PlaybackState)
    /// Called when the player encounters an error.
    func player(_ player: StreamPlayer, didEncounterError error: FFmpegError)
    /// Called when the player updates the current playback duration/time.
    func player(_ player: StreamPlayer, didUpdateDuration duration: TimeInterval)
    /// 无缝切歌：当前歌曲播放完毕，已自动切换到预加载的下一首
    func playerDidTransitionToNextTrack(_ player: StreamPlayer)
}

// MARK: - StreamPlayer

/// A streaming media player that connects to a URL, demuxes, decodes, and renders audio/video.
///
/// `StreamPlayer` provides a simple API for playback control: `play(url:)`, `pause()`,
/// `resume()`, and `stop()`. Internally it orchestrates the full pipeline:
/// `ConnectionManager → Demuxer → Decoder → EQFilter → Renderer`.
///
/// Demuxing and decoding run on a dedicated background `DispatchQueue` to avoid
/// blocking the main thread. State changes are communicated via `StreamPlayerDelegate`.
///
/// Usage:
/// ```swift
/// let player = StreamPlayer()
/// player.delegate = self
/// player.play(url: "rtmp://example.com/live/stream")
/// // ...
/// player.pause()
/// player.resume()
/// player.stop()
/// ```
public final class StreamPlayer {

    // MARK: - Public Properties

    /// Delegate for receiving state changes, errors, and duration updates.
    public weak var delegate: StreamPlayerDelegate?

    /// The current playback state.
    public private(set) var state: PlaybackState = .idle {
        didSet {
            if oldValue != state {
                delegate?.player(self, didChangeState: state)
            }
        }
    }

    /// The current playback time in seconds.
    /// 实际播放位置 = 解码位置 - 缓冲队列中尚未播放的时长
    public var currentTime: TimeInterval {
        let decoded = stateQueue.sync { self.decodedTime }
        let buffered = audioRenderer.queuedDuration
        return max(0, decoded - buffered)
    }

    /// 解码线程更新的已解码时间（入队时间点，非实际播放时间点）
    private var decodedTime: TimeInterval = 0

    /// Metadata about the currently playing stream, or `nil` if not connected.
    public private(set) var streamInfo: StreamInfo?

    /// The public audio equalizer for adjusting frequency band gains.
    public let equalizer: AudioEqualizer

    /// 音频效果控制器：音量、变速、响度标准化。
    public let audioEffects: AudioEffects

    /// 实时频谱分析器。设置 onSpectrum 回调并启用后，
    /// 每个 FFT 窗口会回调一次频率幅度数据。
    public let spectrumAnalyzer: SpectrumAnalyzer

    /// 波形预览生成器。独立于播放 pipeline，可在后台生成波形数据。
    public let waveformGenerator: WaveformGenerator

    /// 元数据读取器。读取音频文件的 ID3 标签、专辑封面等。
    public let metadataReader: MetadataReader

    /// 歌词同步引擎。加载 LRC 歌词后，根据播放时间实时匹配当前行。
    ///
    /// ```swift
    /// player.lyricSyncer.load(lrcContent: lrcString)
    /// player.lyricSyncer.onSync = { lineIndex, line, wordIndex, progress in
    ///     // 更新 UI：高亮当前行
    /// }
    /// ```
    public let lyricSyncer: LyricSyncer

    /// The video display layer. Add this to your view's layer hierarchy to show video.
    ///
    /// Usage (UIKit):
    /// ```swift
    /// view.layer.addSublayer(player.videoDisplayLayer)
    /// player.videoDisplayLayer.frame = view.bounds
    /// ```
    public var videoDisplayLayer: AVSampleBufferDisplayLayer {
        return videoRenderer.sampleBufferDisplayLayer
    }

    /// 视频是否正在使用 VideoToolbox 硬件加速解码。
    /// 仅在播放视频流时有意义，无视频时返回 false。
    public var isVideoHardwareAccelerated: Bool {
        return stateQueue.sync { videoDecoder?.isHardwareAccelerated ?? false }
    }

    // MARK: - Internal Components

    /// The EQ filter used for audio processing.
    internal let eqFilter: EQFilter

    /// FFmpeg avfilter 音频滤镜图（loudnorm、atempo、volume）
    internal let audioFilterGraph: AudioFilterGraph

    /// The connection manager for establishing media connections.
    private var connectionManager: ConnectionManager?

    /// The demuxer for separating audio/video packets.
    private var demuxer: Demuxer?

    /// The audio decoder.
    private var audioDecoder: AudioDecoder?

    /// The video decoder.
    private var videoDecoder: VideoDecoder?

    /// The audio renderer.
    private let audioRenderer: AudioRenderer

    /// The video renderer.
    private let videoRenderer: VideoRenderer

    /// The A/V sync controller.
    private let syncController: AVSyncController

    // MARK: - Queues & State

    /// Dedicated background queue for demuxing and decoding.
    private let playbackQueue = DispatchQueue(label: "com.ffmpeg-sdk.playback", qos: .userInitiated)

    /// Serial queue for synchronizing state changes.
    private let stateQueue = DispatchQueue(label: "com.ffmpeg-sdk.player-state")

    /// Flag indicating whether the playback loop should continue.
    private var isPlaybackActive: Bool = false

    /// The URL of the current playback session.
    private var currentURL: String?

    /// Seek 请求：播放循环会检查此值并在安全时刻执行 seek
    private var pendingSeekTime: TimeInterval? = nil
    private let seekLock = NSLock()

    /// seek 后的目标时间，用于抑制 seek 点之前的旧 PTS 更新 currentTime
    /// demuxer seek 到关键帧（通常在目标之前），解码出的前几个 packet PTS 会小于目标
    private var seekTargetTime: TimeInterval? = nil

    /// 音频流的 time_base，用于将 packet PTS 精确转换为秒
    private var audioTimeBase: AVRational = AVRational(num: 0, den: 1)

    /// 首个 audio packet 的 PTS（秒），用于消除容器/编码器起始偏移
    /// 很多音频文件第一个 packet PTS 不是 0（编码器延迟、容器头部偏移等）
    private var audioPTSOffset: TimeInterval? = nil

    // MARK: - A-B 循环

    /// A-B 循环的 A 点（秒），nil = 未设置
    private var loopPointA: TimeInterval? = nil
    /// A-B 循环的 B 点（秒），nil = 未设置
    private var loopPointB: TimeInterval? = nil
    /// A-B 循环是否启用
    private var abLoopEnabled: Bool = false

    /// 交叉淡入淡出时长（秒）
    private var crossfadeDuration: Float = 0.0

    // MARK: - Gapless Playback (预加载下一首)

    /// 预加载的下一首 pipeline 组件
    private var nextConnectionManager: ConnectionManager?
    private var nextDemuxer: Demuxer?
    private var nextAudioDecoder: AudioDecoder?
    private var nextStreamInfo: StreamInfo?
    private var nextAudioTimeBase: AVRational = AVRational(num: 0, den: 1)
    private var nextURL: String?
    /// 预加载是否就绪
    private var isNextReady: Bool = false
    /// 强制切换标志（音质切换时使用）
    private var forceTransition: Bool = false
    /// 预加载专用队列
    private let prepareQueue = DispatchQueue(label: "com.ffmpeg-sdk.prepare-next", qos: .utility)

    // MARK: - Initialization

    /// Creates a new `StreamPlayer` with default components.
    public init() {
        self.eqFilter = EQFilter()
        self.audioFilterGraph = AudioFilterGraph()
        self.equalizer = AudioEqualizer(filter: eqFilter)
        self.audioEffects = AudioEffects(filterGraph: audioFilterGraph)
        self.spectrumAnalyzer = SpectrumAnalyzer()
        self.waveformGenerator = WaveformGenerator()
        self.metadataReader = MetadataReader()
        self.lyricSyncer = LyricSyncer()
        self.audioRenderer = AudioRenderer()
        self.videoRenderer = VideoRenderer()
        self.syncController = AVSyncController()
        self.audioRenderer.setEQFilter(eqFilter)
        self.audioRenderer.setAudioFilterGraph(audioFilterGraph)
        self.audioRenderer.setSpectrumAnalyzer(spectrumAnalyzer)
        // 设置 equalizer 的 audioEffects 引用，用于应用预设的环绕效果
        self.equalizer.audioEffects = self.audioEffects
    }

    deinit {
        stopInternal()
    }

    // MARK: - Playback Control

    /// Starts playback from the given URL.
    ///
    /// This method is non-blocking. It kicks off the connection and playback
    /// pipeline on a background queue. State changes are reported via the delegate.
    ///
    /// If a session is already active, it is stopped first before starting the new one.
    ///
    /// - Parameter url: The URL of the media source (RTMP, HLS, RTSP, etc.).
    public func play(url: String) {
        // Stop any existing session first
        stopInternal()
        // 清理预加载（手动切歌时预加载的下一首可能已不正确）
        cancelNextPreparation()

        stateQueue.sync {
            self.isPlaybackActive = true
            self.currentURL = url
            self.decodedTime = 0
            self.streamInfo = nil
        }

        // Transition to connecting
        transitionState(to: .connecting)

        // Start the pipeline on the background queue
        playbackQueue.async { [weak self] in
            self?.startPipeline(url: url)
        }
    }

    /// Pauses the current playback.
    ///
    /// Audio and video rendering are paused but the session remains active.
    /// Call `resume()` to continue playback.
    public func pause() {
        guard state == .playing else { return }
        audioRenderer.pause()
        transitionState(to: .paused)
    }

    /// Resumes playback after a pause.
    ///
    /// Has no effect if the player is not in the `.paused` state.
    public func resume() {
        guard state == .paused else { return }
        audioRenderer.resume()
        transitionState(to: .playing)
    }

    /// Stops playback and releases all resources.
    ///
    /// After calling `stop()`, the player returns to a state where `play(url:)`
    /// can be called again to start a new session.
    public func stop() {
        stopInternal()
        transitionState(to: .stopped)
    }

    /// Seeks to the specified time position in seconds.
    ///
    /// 将 seek 请求投递给播放循环，由播放循环在安全时刻执行，
    /// 避免与 demuxer 的 readNextPacket 产生线程竞争。
    ///
    /// - Parameter time: The target position in seconds.
    public func seek(to time: TimeInterval) {
        seekLock.lock()
        pendingSeekTime = time
        seekLock.unlock()
    }

    // MARK: - A-B 循环

    /// 设置 A-B 循环区间。设置后自动启用循环。
    ///
    /// 播放到 B 点时自动 seek 回 A 点，实现精确区间循环。
    /// 适用于练歌、学习乐器等场景。
    ///
    /// - Parameters:
    ///   - pointA: A 点时间（秒）
    ///   - pointB: B 点时间（秒），必须大于 A 点
    public func setABLoop(pointA: TimeInterval, pointB: TimeInterval) {
        guard pointB > pointA else { return }
        stateQueue.sync {
            self.loopPointA = pointA
            self.loopPointB = pointB
            self.abLoopEnabled = true
        }
    }

    /// 清除 A-B 循环，恢复正常播放。
    public func clearABLoop() {
        stateQueue.sync {
            self.loopPointA = nil
            self.loopPointB = nil
            self.abLoopEnabled = false
        }
    }

    /// A-B 循环是否启用。
    public var isABLoopEnabled: Bool {
        stateQueue.sync { abLoopEnabled }
    }

    /// 当前 A-B 循环的 A 点（秒），nil = 未设置。
    public var abLoopPointA: TimeInterval? {
        stateQueue.sync { loopPointA }
    }

    /// 当前 A-B 循环的 B 点（秒），nil = 未设置。
    public var abLoopPointB: TimeInterval? {
        stateQueue.sync { loopPointB }
    }

    // MARK: - 交叉淡入淡出

    /// 设置交叉淡入淡出时长。
    ///
    /// 当使用 prepareNext + 无缝切歌时，当前歌曲结尾会淡出，
    /// 下一首歌曲开头会淡入，两者重叠产生 DJ 混音效果。
    ///
    /// - Parameter duration: 交叉淡入淡出时长（秒），0 = 关闭。
    ///   典型值：3~8 秒。
    public func setCrossfadeDuration(_ duration: Float) {
        audioEffects.setFadeIn(duration: duration)
        // 淡出需要知道歌曲总时长，在 startPipeline 中动态设置
        stateQueue.sync {
            self.crossfadeDuration = duration
        }
    }

    /// 当前交叉淡入淡出时长（秒）。
    public var currentCrossfadeDuration: Float {
        stateQueue.sync { crossfadeDuration }
    }

    /// 预加载下一首歌曲，实现无缝切歌（gapless playback）。
    ///
    /// 在后台队列连接并初始化下一首的 demuxer + decoder，
    /// 当前歌曲 EOF 时直接切换 pipeline，AudioRenderer 不中断。
    ///
    /// - Parameter url: 下一首歌曲的 URL
    public func prepareNext(url: String) {
        // 取消之前的预加载
        cancelNextPreparation()

        stateQueue.sync {
            self.nextURL = url
            self.isNextReady = false
        }

        prepareQueue.async { [weak self] in
            self?.performNextPreparation(url: url)
        }
    }

    /// 立即切换到预加载的下一首（用于音质切换等场景）。
    /// 不等 EOF，主动触发切换，可指定 seek 位置。
    /// - Parameter seekTo: 切换后 seek 到的位置（秒），nil 表示从头播放
    public func switchToNext(seekTo: TimeInterval? = nil) {
        guard stateQueue.sync(execute: { self.isNextReady }) else { return }
        // 投递 seek 请求，transitionToNextTrack 后播放循环会处理
        if let time = seekTo {
            seekLock.lock()
            pendingSeekTime = time
            seekLock.unlock()
        }
        // 设置标志让播放循环在下次迭代时触发切换
        stateQueue.sync {
            self.forceTransition = true
        }
    }

    /// 取消预加载
    public func cancelNextPreparation() {
        stateQueue.sync {
            nextConnectionManager?.disconnect()
            nextConnectionManager = nil
            nextDemuxer = nil
            nextAudioDecoder = nil
            nextStreamInfo = nil
            nextAudioTimeBase = AVRational(num: 0, den: 1)
            nextURL = nil
            isNextReady = false
            forceTransition = false
        }
    }

    /// 在播放循环中安全执行 seek（仅在 playbackQueue 上调用）
    /// 无缝模式：不暂停 AudioUnit，只清空缓冲区，新数据到达后自动接续播放
    private func processPendingSeek(demuxer: Demuxer) {
        seekLock.lock()
        guard let seekTime = pendingSeekTime else {
            seekLock.unlock()
            return
        }
        pendingSeekTime = nil
        seekLock.unlock()

        // 只清空缓冲区队列，不暂停 AudioUnit（空队列时会自动输出静音）
        audioRenderer.flushQueue()

        // Flush 解码器
        stateQueue.sync {
            audioDecoder?.flush()
            videoDecoder?.flush()
        }

        // 重置同步控制器
        syncController.reset()

        // 执行 seek
        do {
            try demuxer.seek(to: seekTime)
            stateQueue.sync {
                self.decodedTime = seekTime
                // 记录 seek 目标，抑制 seek 点之前的旧 PTS 更新
                self.seekTargetTime = seekTime
            }
            // seek 后重置歌词同步状态
            lyricSyncer.reset()
        } catch {
            // Seek 失败，静默处理
        }
    }

    // MARK: - Pipeline

    /// Starts the full playback pipeline: connect → demux → decode → render.
    ///
    /// This method runs on the playback queue and blocks until playback ends
    /// (either by reaching EOF, encountering an unrecoverable error, or being stopped).
    private func startPipeline(url: String) {
        let manager = ConnectionManager()
        stateQueue.sync { self.connectionManager = manager }

        // Step 1: Connect
        let formatContext: FFmpegFormatContext
        do {
            // Use a semaphore to bridge async connect to the sync playback queue
            var connectResult: Result<FFmpegFormatContext, Error>?
            let semaphore = DispatchSemaphore(value: 0)

            Task {
                do {
                    let ctx = try await manager.connect(url: url)
                    connectResult = .success(ctx)
                } catch {
                    connectResult = .failure(error)
                }
                semaphore.signal()
            }

            semaphore.wait()

            switch connectResult! {
            case .success(let ctx):
                formatContext = ctx
            case .failure(let error):
                throw error
            }
        } catch {
            handleUnrecoverableError(error)
            return
        }

        // Check if we were stopped during connection
        guard isActive() else { return }

        // Step 2: Demux - find streams
        let demuxer = Demuxer(formatContext: formatContext, url: url)
        stateQueue.sync { self.demuxer = demuxer }

        let info: StreamInfo
        do {
            info = try demuxer.findStreams()
            stateQueue.sync { self.streamInfo = info }
        } catch {
            handleUnrecoverableError(error)
            return
        }

        guard isActive() else { return }

        // Step 3: 先启动 AudioRenderer，获取硬件实际采样率
        // iOS 设备请求高采样率（如 192kHz）后，硬件可能给出不同的实际值
        var hwSampleRate: Int? = nil
        if info.hasAudio, let sampleRate = info.sampleRate, let channelCount = info.channelCount {
            do {
                let format = makeAudioFormat(sampleRate: sampleRate, channelCount: channelCount)
                try audioRenderer.start(format: format)
                hwSampleRate = audioRenderer.actualSampleRate
            } catch {
                handleUnrecoverableError(error)
                return
            }
        }

        guard isActive() else { return }

        // Step 4: 初始化解码器，用硬件实际采样率作为 SwrContext 输出目标
        // 如果硬件采样率与源不同，SwrContext 会自动重采样
        do {
            try initializeDecoders(
                formatContext: formatContext,
                demuxer: demuxer,
                streamInfo: info,
                targetSampleRate: hwSampleRate
            )
        } catch {
            handleUnrecoverableError(error)
            return
        }

        // Transition to playing
        transitionState(to: .playing)

        // Notify duration if available
        if let duration = info.duration {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.player(self, didUpdateDuration: duration)
            }
        }

        // Step 5: Run the demux/decode loop
        syncController.reset()
        runPlaybackLoop(demuxer: demuxer)
    }

    /// Initializes audio and video decoders based on the discovered streams.
    private func initializeDecoders(
        formatContext: FFmpegFormatContext,
        demuxer: Demuxer,
        streamInfo: StreamInfo,
        targetSampleRate: Int? = nil
    ) throws {
        // Initialize audio decoder
        if streamInfo.hasAudio, demuxer.currentAudioStreamIndex >= 0 {
            let streamIndex = Int(demuxer.currentAudioStreamIndex)
            if let stream = formatContext.stream(at: streamIndex),
               let codecpar = stream.pointee.codecpar {
                let codecID = codecpar.pointee.codec_id
                // 保存音频流的 time_base，用于 PTS → 秒 的精确转换
                stateQueue.sync { self.audioTimeBase = stream.pointee.time_base }
                do {
                    let decoder = try AudioDecoder(
                        codecParameters: codecpar,
                        codecID: codecID,
                        targetSampleRate: targetSampleRate
                    )
                    stateQueue.sync { self.audioDecoder = decoder }
                } catch {
                    // Audio decoder init failure is unrecoverable if we only have audio
                    if !streamInfo.hasVideo { throw error }
                    // If we have video too, we can continue without audio
                }
            }
        }

        // Initialize video decoder
        if streamInfo.hasVideo, demuxer.currentVideoStreamIndex >= 0 {
            let streamIndex = Int(demuxer.currentVideoStreamIndex)
            if let stream = formatContext.stream(at: streamIndex),
               let codecpar = stream.pointee.codecpar {
                let codecID = codecpar.pointee.codec_id
                let timeBase = stream.pointee.time_base
                do {
                    let decoder = try VideoDecoder(
                        codecParameters: codecpar,
                        codecID: codecID,
                        timeBase: timeBase
                    )
                    stateQueue.sync { self.videoDecoder = decoder }
                } catch {
                    // Video decoder init failure is unrecoverable if we only have video
                    if !streamInfo.hasAudio { throw error }
                }
            }
        }
    }

    /// The main demux/decode loop. Reads packets, decodes them, and sends
    /// the output to the appropriate renderer.
    ///
    /// Individual frame decoding errors are caught and skipped (recoverable).
    /// Unrecoverable errors (resource allocation failures, connection loss,
    /// unsupported formats) stop the loop and trigger auto-stop via delegate.
    /// Network disconnection errors are detected and propagated through the
    /// ConnectionManager delegate before notifying the app layer.
    ///
    /// Backpressure: When the audio renderer's buffer queue exceeds the max
    /// threshold, the loop sleeps briefly to let the renderer catch up. This
    /// prevents unbounded memory growth and ensures we don't race past EOF
    /// before audio finishes playing.
    private func runPlaybackLoop(demuxer initialDemuxer: Demuxer) {
        while isActive() {
            // 获取当前 demuxer（可能在无缝切歌后被替换）
            guard let currentDemuxer = stateQueue.sync(execute: { self.demuxer }) else { return }

            // 检查并处理 pending seek（线程安全，在 playbackQueue 上执行）
            processPendingSeek(demuxer: currentDemuxer)

            // Check if paused - wait briefly and retry
            if state == .paused {
                Thread.sleep(forTimeInterval: 0.01)
                continue
            }

            // 检查是否有强制切换请求（音质切换）
            let shouldForceTransition = stateQueue.sync(execute: {
                let val = self.forceTransition
                self.forceTransition = false
                return val
            })
            if shouldForceTransition && transitionToNextTrack() {
                // 强制切换成功，flush 旧 buffer 并继续
                audioRenderer.flushQueue()
                continue
            }

            // Backpressure: wait if the audio renderer has too many queued buffers
            while isActive() && audioRenderer.queuedBufferCount > AudioRenderer.maxQueuedBuffers {
                Thread.sleep(forTimeInterval: 0.01)
            }
            guard isActive() else { return }

            let packet: Demuxer.PacketType?
            do {
                packet = try currentDemuxer.readNextPacket()
            } catch let error as FFmpegError where error == .networkDisconnected {
                handleNetworkDisconnection()
                return
            } catch let error as FFmpegError where error.isUnrecoverable {
                handleUnrecoverableError(error)
                return
            } catch {
                handleUnrecoverableError(error)
                return
            }

            guard let packet = packet else {
                // EOF reached — 尝试无缝切换到预加载的下一首
                if transitionToNextTrack() {
                    // 成功切换到下一首，继续循环（下次迭代会取到新的 self.demuxer）
                    continue
                }
                // 没有预加载的下一首，正常结束
                waitForRendererDrain()
                stopInternal()
                transitionState(to: .stopped)
                return
            }

            switch packet {
            case .audio(let pkt):
                if let unrecoverableError = processAudioPacket(pkt) {
                    handleUnrecoverableError(unrecoverableError)
                    return
                }
            case .video(let pkt):
                if let unrecoverableError = processVideoPacket(pkt) {
                    handleUnrecoverableError(unrecoverableError)
                    return
                }
            }
        }
    }

    /// Waits for the audio renderer to finish playing all queued buffers after EOF.
    /// 添加 10 秒超时保护，防止无限阻塞。
    private func waitForRendererDrain() {
        let maxWait: TimeInterval = 10.0
        let start = Date()
        while isActive() && audioRenderer.queuedBufferCount > 0 {
            if Date().timeIntervalSince(start) > maxWait {
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    // MARK: - Gapless: 预加载与切换

    /// 在后台执行下一首的预加载：连接 → demux → 初始化 decoder
    private func performNextPreparation(url: String) {
        let manager = ConnectionManager()

        // Step 1: 连接
        let formatContext: FFmpegFormatContext
        do {
            var connectResult: Result<FFmpegFormatContext, Error>?
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                do {
                    let ctx = try await manager.connect(url: url)
                    connectResult = .success(ctx)
                } catch {
                    connectResult = .failure(error)
                }
                semaphore.signal()
            }
            semaphore.wait()

            switch connectResult! {
            case .success(let ctx): formatContext = ctx
            case .failure: return // 预加载失败，静默处理
            }
        }

        // 检查是否已被取消
        let stillValid = stateQueue.sync { self.nextURL == url }
        guard stillValid else {
            manager.disconnect()
            return
        }

        // Step 2: Demux - 查找流
        let demuxer = Demuxer(formatContext: formatContext, url: url)
        let info: StreamInfo
        do {
            info = try demuxer.findStreams()
        } catch {
            manager.disconnect()
            return
        }

        guard stateQueue.sync(execute: { self.nextURL == url }) else {
            manager.disconnect()
            return
        }

        // Step 3: 初始化 audio decoder
        // 使用当前 AudioRenderer 的采样率作为目标，避免需要重启 AudioUnit
        var decoder: AudioDecoder?
        var nextTimeBase = AVRational(num: 0, den: 1)
        if info.hasAudio, demuxer.currentAudioStreamIndex >= 0 {
            let streamIndex = Int(demuxer.currentAudioStreamIndex)
            if let stream = formatContext.stream(at: streamIndex),
               let codecpar = stream.pointee.codecpar {
                let codecID = codecpar.pointee.codec_id
                nextTimeBase = stream.pointee.time_base
                // 用当前 renderer 的实际采样率，这样不需要重启 AudioUnit
                let targetRate = audioRenderer.actualSampleRate > 0 ? audioRenderer.actualSampleRate : nil
                decoder = try? AudioDecoder(
                    codecParameters: codecpar,
                    codecID: codecID,
                    targetSampleRate: targetRate
                )
            }
        }

        guard decoder != nil else {
            manager.disconnect()
            return
        }

        guard stateQueue.sync(execute: { self.nextURL == url }) else {
            manager.disconnect()
            return
        }

        // 保存预加载结果
        stateQueue.sync {
            self.nextConnectionManager = manager
            self.nextDemuxer = demuxer
            self.nextAudioDecoder = decoder
            self.nextStreamInfo = info
            self.nextAudioTimeBase = nextTimeBase
            self.isNextReady = true
        }
    }

    /// 无缝切换到预加载的下一首。
    /// 在 playbackQueue 上调用（EOF 时），不停止 AudioRenderer。
    /// 如果新流的采样率或声道数与当前不同，会重启 AudioRenderer 以匹配新格式。
    /// - Returns: true 表示切换成功，播放循环应继续；false 表示没有预加载
    private func transitionToNextTrack() -> Bool {
        // 原子性地取出预加载的组件
        let (nextDemuxer, nextDecoder, nextInfo, nextTimeBase, nextConnMgr) = stateQueue.sync {
            () -> (Demuxer?, AudioDecoder?, StreamInfo?, AVRational, ConnectionManager?) in
            guard isNextReady else { return (nil, nil, nil, AVRational(num: 0, den: 1), nil) }

            let d = self.nextDemuxer
            let dec = self.nextAudioDecoder
            let info = self.nextStreamInfo
            let tb = self.nextAudioTimeBase
            let cm = self.nextConnectionManager

            // 清空预加载状态
            self.nextDemuxer = nil
            self.nextAudioDecoder = nil
            self.nextStreamInfo = nil
            self.nextAudioTimeBase = AVRational(num: 0, den: 1)
            self.nextConnectionManager = nil
            self.nextURL = nil
            self.isNextReady = false

            return (d, dec, info, tb, cm)
        }

        guard let demuxer = nextDemuxer, let decoder = nextDecoder, let info = nextInfo else {
            return false
        }

        // 检查新 decoder 的输出格式是否与当前 AudioRenderer 匹配
        let newSampleRate = decoder.outputSampleRate
        let newChannelCount = decoder.outputChannelCount
        let currentRendererRate = audioRenderer.actualSampleRate

        // 如果采样率或声道数变了，需要重启 AudioRenderer
        if newSampleRate != currentRendererRate || newChannelCount != stateQueue.sync(execute: { self.audioDecoder?.outputChannelCount ?? 0 }) {
            // 先清空旧缓冲区
            audioRenderer.flushQueue()
            // 停止旧的 AudioRenderer
            audioRenderer.stop()
            // 用新格式重启
            let format = makeAudioFormat(sampleRate: newSampleRate, channelCount: newChannelCount)
            do {
                try audioRenderer.start(format: format)
            } catch {
                // 重启失败，回退：尝试用旧格式重启
                let oldFormat = makeAudioFormat(sampleRate: currentRendererRate, channelCount: newChannelCount)
                try? audioRenderer.start(format: oldFormat)
            }
        }

        // 释放旧的 pipeline 组件（但不停止 AudioRenderer）
        stateQueue.sync {
            self.audioDecoder = nil
            self.videoDecoder = nil
            self.demuxer = demuxer
            self.audioDecoder = decoder
            self.connectionManager = nextConnMgr
            self.streamInfo = info
            self.audioTimeBase = nextTimeBase
            self.audioPTSOffset = nil  // 新歌曲重新计算 PTS 偏移
            self.currentURL = info.url
            // 如果有 pendingSeekTime（音质切换），保持当前时间不变
            // 否则是正常切歌，重置为 0
            if self.pendingSeekTime == nil {
                self.decodedTime = 0
            }
        }

        // 重置同步控制器
        syncController.reset()

        // 通知 duration
        if let duration = info.duration {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.player(self, didUpdateDuration: duration)
            }
        }

        // 通知 app 层已切换到下一首
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.playerDidTransitionToNextTrack(self)
        }

        return true
    }
    ///
    /// 使用 packet PTS + audioTimeBase 精确计算播放时间，避免 duration 累加漂移。
    /// 可恢复错误（单帧解码失败）会被跳过，不可恢复错误会触发自动停止。
    ///
    /// - Returns: An unrecoverable `FFmpegError` if one occurred, or `nil` on success/skip.
    @discardableResult
    private func processAudioPacket(_ pkt: UnsafeMutablePointer<AVPacket>) -> FFmpegError? {
        // 在 defer 之前读取 PTS，因为 av_packet_unref 会清除它
        let packetPTS = pkt.pointee.pts
        let timeBase = stateQueue.sync { self.audioTimeBase }

        defer {
            var packet: UnsafeMutablePointer<AVPacket>? = pkt
            av_packet_unref(pkt)
            av_packet_free(&packet)
        }

        guard let decoder = audioDecoder else { return nil }

        do {
            let audioBuffers = try decoder.decodeAll(packet: pkt)

            for (index, audioBuffer) in audioBuffers.enumerated() {
                audioRenderer.enqueue(audioBuffer)

                // 精确时间计算：优先使用 packet PTS + stream time_base
                // 减去首个 packet 的 PTS 偏移，确保从 0 开始
                let pts: TimeInterval
                let nopts = Int64(bitPattern: UInt64(0x8000000000000000)) // AV_NOPTS_VALUE
                if packetPTS != nopts && packetPTS >= 0 && timeBase.den > 0 {
                    // PTS 有效：转换为秒，多 frame 时用 duration 偏移
                    let basePTS = Double(packetPTS) * Double(timeBase.num) / Double(timeBase.den)
                    // 如果一个 packet 解码出多个 frame，后续 frame 加上偏移
                    var offset: TimeInterval = 0
                    for i in 0..<index {
                        offset += audioBuffers[i].duration
                    }
                    let rawPTS = basePTS + offset
                    
                    // 记录首个 PTS 作为基准偏移（仅在非 seek 状态下）
                    let ptsOffset: TimeInterval = stateQueue.sync {
                        if self.audioPTSOffset == nil {
                            self.audioPTSOffset = rawPTS
                        }
                        return self.audioPTSOffset ?? 0
                    }
                    pts = rawPTS - ptsOffset
                } else {
                    // PTS 无效，退回 duration 累加（不太精确但可用）
                    pts = stateQueue.sync { self.currentTime } + audioBuffer.duration
                }

                syncController.updateAudioClock(pts)

                stateQueue.sync {
                    // seek 后，如果 PTS 还没到目标位置，不更新 decodedTime（防止进度条回跳）
                    if let target = self.seekTargetTime {
                        if pts >= target {
                            // 已到达或超过 seek 目标，清除标记，恢复正常更新
                            self.seekTargetTime = nil
                            self.decodedTime = pts
                        }
                        // PTS < target：跳过更新，保持 decodedTime 在 seek 目标位置
                    } else {
                        self.decodedTime = pts
                    }
                }

                // 更新歌词同步（在 stateQueue 外调用，避免阻塞）
                lyricSyncer.update(time: pts)

                // A-B 循环检测：到达 B 点时自动 seek 回 A 点（在 stateQueue 外操作 seekLock）
                let shouldSeekToA: TimeInterval? = stateQueue.sync {
                    if self.abLoopEnabled,
                       let a = self.loopPointA,
                       let b = self.loopPointB,
                       pts >= b {
                        return a
                    }
                    return nil
                }
                if let a = shouldSeekToA {
                    seekLock.lock()
                    pendingSeekTime = a
                    seekLock.unlock()
                }
            }

            return nil
        } catch let error as FFmpegError where error.isUnrecoverable {
            return error
        } catch {
            return nil
        }
    }

    /// Processes a single video packet: decode → sync → render.
    ///
    /// Recoverable errors (individual frame decoding failures) are caught and
    /// skipped. Unrecoverable errors (resource allocation failures, etc.) are
    /// propagated to trigger an automatic stop.
    /// Frames that are too far behind audio are dropped per A/V sync logic.
    ///
    /// - Returns: An unrecoverable `FFmpegError` if one occurred, or `nil` on success/skip.
    @discardableResult
    private func processVideoPacket(_ pkt: UnsafeMutablePointer<AVPacket>) -> FFmpegError? {
        defer {
            var packet: UnsafeMutablePointer<AVPacket>? = pkt
            av_packet_unref(pkt)
            av_packet_free(&packet)
        }

        guard let decoder = videoDecoder else { return nil }

        do {
            let frame = try decoder.decode(packet: pkt)

            // Check A/V sync
            let action = syncController.syncAction(for: frame.pts)

            switch action {
            case .display(let delay):
                if delay > 0 {
                    Thread.sleep(forTimeInterval: delay)
                }
                videoRenderer.render(frame)
                syncController.updateVideoClock(frame.pts)

            case .drop:
                // Frame is too far behind audio - skip it
                break

            case .repeatPrevious(let delay):
                // Video is ahead of audio - wait then display
                Thread.sleep(forTimeInterval: delay)
                videoRenderer.render(frame)
                syncController.updateVideoClock(frame.pts)
            }
            return nil
        } catch let error as FFmpegError where error.isUnrecoverable {
            // Unrecoverable error — propagate to trigger auto-stop
            return error
        } catch {
            // Recoverable error (e.g., single frame decode failure) — skip and continue
            return nil
        }
    }

    // MARK: - Helpers

    /// Checks whether the playback loop should continue.
    private func isActive() -> Bool {
        return stateQueue.sync { isPlaybackActive }
    }

    /// Transitions the player state and notifies the delegate.
    private func transitionState(to newState: PlaybackState) {
        stateQueue.sync {
            self.state = newState
        }
    }

    /// Handles an unrecoverable error by stopping playback and notifying the delegate.
    private func handleUnrecoverableError(_ error: Error) {
        let ffError: FFmpegError
        if let fe = error as? FFmpegError {
            ffError = fe
        } else {
            ffError = .connectionFailed(code: -1, message: error.localizedDescription)
        }

        stopInternal()
        transitionState(to: .error(ffError))

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.player(self, didEncounterError: ffError)
        }
    }

    /// Handles a network disconnection detected during the demux/decode loop.
    ///
    /// Updates the ConnectionManager state to reflect the disconnection,
    /// stops playback, transitions to the error state, and notifies the
    /// app layer via the StreamPlayerDelegate.
    private func handleNetworkDisconnection() {
        let error = FFmpegError.networkDisconnected

        // Notify the ConnectionManager about the disconnection so its delegate
        // (if any) also receives the state change.
        stateQueue.sync {
            connectionManager?.delegate?.connectionManager(connectionManager!, didFailWith: error)
        }

        stopInternal()
        transitionState(to: .error(error))

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.player(self, didEncounterError: error)
        }
    }

    /// Stops playback and cleans up all resources without changing state.
    private func stopInternal() {
        stateQueue.sync {
            isPlaybackActive = false
        }

        // 清除未处理的 seek 请求
        seekLock.lock()
        pendingSeekTime = nil
        seekLock.unlock()
        
        // 清除 seek 目标时间
        stateQueue.sync {
            seekTargetTime = nil
        }

        // Stop renderers
        audioRenderer.stop()
        videoRenderer.clear()

        // Reset sync controller
        syncController.reset()

        // Clean up decoders
        stateQueue.sync {
            audioDecoder = nil
            videoDecoder = nil
            demuxer = nil
            audioTimeBase = AVRational(num: 0, den: 1)
            audioPTSOffset = nil
            decodedTime = 0
        }

        // Disconnect
        stateQueue.sync {
            connectionManager?.disconnect()
            connectionManager = nil
        }
    }

    /// Creates an `AudioStreamBasicDescription` for Float32 interleaved PCM.
    private func makeAudioFormat(sampleRate: Int, channelCount: Int) -> AudioStreamBasicDescription {
        return AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channelCount * MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(channelCount * MemoryLayout<Float>.size),
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: UInt32(MemoryLayout<Float>.size * 8),
            mReserved: 0
        )
    }
}
