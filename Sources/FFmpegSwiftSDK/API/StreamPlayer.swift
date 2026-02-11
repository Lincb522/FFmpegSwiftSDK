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
    public private(set) var currentTime: TimeInterval = 0

    /// Metadata about the currently playing stream, or `nil` if not connected.
    public private(set) var streamInfo: StreamInfo?

    /// The public audio equalizer for adjusting frequency band gains.
    public let equalizer: AudioEqualizer

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

    // MARK: - Internal Components

    /// The EQ filter used for audio processing.
    internal let eqFilter: EQFilter

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

    // MARK: - Initialization

    /// Creates a new `StreamPlayer` with default components.
    public init() {
        self.eqFilter = EQFilter()
        self.equalizer = AudioEqualizer(filter: eqFilter)
        self.audioRenderer = AudioRenderer()
        self.videoRenderer = VideoRenderer()
        self.syncController = AVSyncController()
        self.audioRenderer.setEQFilter(eqFilter)
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

        stateQueue.sync {
            self.isPlaybackActive = true
            self.currentURL = url
            self.currentTime = 0
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

    /// 在播放循环中安全执行 seek（仅在 playbackQueue 上调用）
    private func processPendingSeek(demuxer: Demuxer) {
        seekLock.lock()
        guard let seekTime = pendingSeekTime else {
            seekLock.unlock()
            return
        }
        pendingSeekTime = nil
        seekLock.unlock()

        // 暂停渲染，清空缓冲区
        audioRenderer.pause()
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
                self.currentTime = seekTime
            }
        } catch {
            // Seek 失败，静默处理
        }

        // 恢复渲染
        if state == .playing {
            audioRenderer.resume()
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

        // Step 3: Initialize decoders
        do {
            try initializeDecoders(formatContext: formatContext, demuxer: demuxer, streamInfo: info)
        } catch {
            handleUnrecoverableError(error)
            return
        }

        guard isActive() else { return }

        // Step 4: Start audio renderer if we have audio
        if info.hasAudio, let sampleRate = info.sampleRate, let channelCount = info.channelCount {
            do {
                let format = makeAudioFormat(sampleRate: sampleRate, channelCount: channelCount)
                try audioRenderer.start(format: format)
            } catch {
                handleUnrecoverableError(error)
                return
            }
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
        streamInfo: StreamInfo
    ) throws {
        // Initialize audio decoder
        if streamInfo.hasAudio, demuxer.currentAudioStreamIndex >= 0 {
            let streamIndex = Int(demuxer.currentAudioStreamIndex)
            if let stream = formatContext.stream(at: streamIndex),
               let codecpar = stream.pointee.codecpar {
                let codecID = codecpar.pointee.codec_id
                do {
                    let decoder = try AudioDecoder(codecParameters: codecpar, codecID: codecID)
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
    private func runPlaybackLoop(demuxer: Demuxer) {
        while isActive() {
            // 检查并处理 pending seek（线程安全，在 playbackQueue 上执行）
            processPendingSeek(demuxer: demuxer)

            // Check if paused - wait briefly and retry
            if state == .paused {
                Thread.sleep(forTimeInterval: 0.01)
                continue
            }

            // Backpressure: wait if the audio renderer has too many queued buffers
            while isActive() && audioRenderer.queuedBufferCount > AudioRenderer.maxQueuedBuffers {
                Thread.sleep(forTimeInterval: 0.01)
            }
            guard isActive() else { return }

            let packet: Demuxer.PacketType?
            do {
                packet = try demuxer.readNextPacket()
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
                // EOF reached — wait for the audio renderer to drain its buffer
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
    private func waitForRendererDrain() {
        while isActive() && audioRenderer.queuedBufferCount > 0 {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    /// Processes a single audio packet: decode → EQ → render.
    ///
    /// Recoverable errors (individual frame decoding failures) are caught and
    /// skipped. Unrecoverable errors (resource allocation failures, etc.) are
    /// propagated to trigger an automatic stop.
    ///
    /// - Returns: An unrecoverable `FFmpegError` if one occurred, or `nil` on success/skip.
    @discardableResult
    private func processAudioPacket(_ pkt: UnsafeMutablePointer<AVPacket>) -> FFmpegError? {
        defer {
            var packet: UnsafeMutablePointer<AVPacket>? = pkt
            av_packet_unref(pkt)
            av_packet_free(&packet)
        }

        guard let decoder = audioDecoder else { return nil }

        do {
            let audioBuffers = try decoder.decodeAll(packet: pkt)

            for audioBuffer in audioBuffers {
                // Enqueue raw PCM for rendering (EQ is applied in real-time by the renderer)
                audioRenderer.enqueue(audioBuffer)

                // Update audio clock for A/V sync
                let pts = currentTime + audioBuffer.duration
                syncController.updateAudioClock(pts)

                // Update current time
                stateQueue.sync {
                    self.currentTime = pts
                }
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
