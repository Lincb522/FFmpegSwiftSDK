// AudioRenderer.swift
// FFmpegSwiftSDK
//
// Renders decoded audio PCM data to the system audio device using AVAudioEngine.
// Uses AVAudioSourceNode as the data provider, reading from a thread-safe buffer queue.
// The FFmpeg decode thread enqueues buffers; AVAudioSourceNode's render block pulls them.

import Foundation
import AudioToolbox
import AVFoundation

/// Renders PCM audio data to the system audio output device.
///
/// `AudioRenderer` uses AVAudioEngine with an AVAudioSourceNode to output audio.
/// Audio data is enqueued via `enqueue(_:)` and pulled by the source node render block.
///
/// Lifecycle: `start(format:)` → `pause()` / `resume()` → `stop()`
///
/// Thread safety: The internal buffer queue is protected by `os_unfair_lock`, allowing
/// concurrent enqueue (from the decode thread) and dequeue (from the render block).
final class AudioRenderer {

    // MARK: - AVAudioEngine

    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?

    // MARK: - Properties

    /// Lock protecting the buffer queue.
    private var bufferLock = os_unfair_lock_s()

    /// Serializes start/stop lifecycle to prevent concurrent engine disposal.
    private let lifecycleLock = NSLock()

    /// Optional EQ filter applied in real-time during the render block.
    private var eqFilter: EQFilter?

    /// Optional FFmpeg avfilter audio filter graph (loudnorm, atempo, volume).
    private var audioFilterGraph: AudioFilterGraph?

    /// Optional spectrum analyzer.
    private var spectrumAnalyzer: SpectrumAnalyzer?

    /// Optional audio repair engine (after all effects, before output).
    private var repairEngine: AudioRepairEngine?

    /// Optional audio data callback for real-time analysis.
    var onAudioData: ((_ samples: UnsafePointer<Float>, _ frameCount: Int, _ channelCount: Int, _ sampleRate: Int) -> Void)?

    /// Sample rate of the current audio stream.
    private var sampleRate: Int = 44100

    /// Number of channels in the current audio stream.
    private var channelCount: Int = 2

    /// FIFO queue of PCM audio buffers waiting to be rendered.
    private var bufferQueue: [AudioBuffer] = []

    /// Tracks the read offset (in samples) into the front buffer of the queue.
    private var currentBufferOffset: Int = 0

    /// Pre-allocated interleaved scratch buffer for the render block.
    /// Avoids per-callback malloc/free on the real-time audio thread.
    private var interleavedScratch: UnsafeMutablePointer<Float>?
    private var interleavedScratchCapacity: Int = 0

    /// Whether the renderer is currently started.
    private var isStarted: Bool = false

    /// Set to `true` before tearing down so the render block outputs silence.
    private var _isStopping = false
    private var stopLock = os_unfair_lock_s()

    fileprivate var isStopping: Bool {
        os_unfair_lock_lock(&stopLock)
        let val = _isStopping
        os_unfair_lock_unlock(&stopLock)
        return val
    }

    private func setStopping(_ value: Bool) {
        os_unfair_lock_lock(&stopLock)
        _isStopping = value
        os_unfair_lock_unlock(&stopLock)
    }

    /// Hardware actual sample rate (available after start).
    private(set) var actualSampleRate: Int = 0

    /// Maximum number of queued buffers before backpressure kicks in.
    static let maxQueuedBuffers = 200

    /// Returns the current number of queued audio buffers.
    var queuedBufferCount: Int {
        os_unfair_lock_lock(&bufferLock)
        let count = bufferQueue.count
        os_unfair_lock_unlock(&bufferLock)
        return count
    }

    /// Returns total duration of all queued buffers in seconds.
    var queuedDuration: TimeInterval {
        os_unfair_lock_lock(&bufferLock)
        var total: TimeInterval = 0
        for (index, buffer) in bufferQueue.enumerated() {
            if index == 0 && currentBufferOffset > 0 {
                let totalSamples = buffer.frameCount * buffer.channelCount
                let remainRatio = Double(totalSamples - currentBufferOffset) / Double(max(totalSamples, 1))
                total += buffer.duration * remainRatio
            } else {
                total += buffer.duration
            }
        }
        os_unfair_lock_unlock(&bufferLock)
        return total
    }

    // MARK: - Initialization

    init() {}

    deinit {
        stop()
    }

    // MARK: - Public Interface

    /// Sets the EQ filter to apply in real-time during audio rendering.
    func setEQFilter(_ filter: EQFilter?) {
        eqFilter = filter
    }

    /// Sets the FFmpeg avfilter audio filter graph.
    func setAudioFilterGraph(_ graph: AudioFilterGraph?) {
        audioFilterGraph = graph
    }

    /// Sets the spectrum analyzer for real-time FFT analysis.
    func setSpectrumAnalyzer(_ analyzer: SpectrumAnalyzer?) {
        spectrumAnalyzer = analyzer
    }

    /// Sets the audio repair engine for automatic audio artifact fixing.
    func setRepairEngine(_ engine: AudioRepairEngine?) {
        repairEngine = engine
    }

    /// Starts the audio renderer with the given audio format.
    ///
    /// Creates and starts an AVAudioEngine with an AVAudioSourceNode.
    /// The format describes the PCM data that will be enqueued.
    ///
    /// - Parameter format: The audio stream format describing the PCM data.
    /// - Throws: `FFmpegError.resourceAllocationFailed` if the engine cannot be started.
    func start(format: AudioStreamBasicDescription) throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        guard !isStarted else { return }

        #if os(iOS) || os(tvOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setPreferredSampleRate(format.mSampleRate)
        try? session.setPreferredIOBufferDuration(0.005)
        let hwRate = session.sampleRate
        #else
        let hwRate = format.mSampleRate
        #endif

        sampleRate = Int(hwRate)
        channelCount = Int(format.mChannelsPerFrame)
        actualSampleRate = Int(hwRate)

        let audioEngine = AVAudioEngine()

        // AVAudioEngine internal nodes require non-interleaved (deinterleaved) format.
        guard let avFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: hwRate,
            channels: AVAudioChannelCount(channelCount),
            interleaved: false
        ) else {
            throw FFmpegError.resourceAllocationFailed(resource: "AVAudioFormat")
        }

        // Pre-allocate scratch buffer for deinterleaving.
        // iOS typical render callback: 512 or 1024 frames × 2 channels = 1024~2048 floats.
        // Allocate enough for the largest expected callback (4096 frames stereo).
        let initialCapacity = 4096 * channelCount
        interleavedScratch = .allocate(capacity: initialCapacity)
        interleavedScratchCapacity = initialCapacity

        // AVAudioSourceNode render block — pulls interleaved data from bufferQueue,
        // then deinterleaves into the non-interleaved AudioBufferList that
        // AVAudioEngine expects.
        let refCon = Unmanaged.passUnretained(self).toOpaque()
        let chCount = channelCount

        let node = AVAudioSourceNode(format: avFormat) { _, _, frameCount, audioBufferList -> OSStatus in
            let renderer = Unmanaged<AudioRenderer>.fromOpaque(refCon).takeUnretainedValue()
            let frames = Int(frameCount)
            let needed = frames * chCount

            // Use pre-allocated scratch; grow only if needed (rare)
            let interleaved: UnsafeMutablePointer<Float>
            if needed <= renderer.interleavedScratchCapacity, let scratch = renderer.interleavedScratch {
                interleaved = scratch
            } else {
                renderer.interleavedScratch?.deallocate()
                renderer.interleavedScratch = .allocate(capacity: needed)
                renderer.interleavedScratchCapacity = needed
                interleaved = renderer.interleavedScratch!
            }

            renderer.fillBuffer(interleaved, frameCount: frames, channelCount: chCount)

            // Deinterleave into separate channel buffers
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            if chCount == 1 {
                if let outData = ablPointer[0].mData?.assumingMemoryBound(to: Float.self) {
                    outData.update(from: interleaved, count: frames)
                }
            } else {
                for ch in 0..<min(chCount, ablPointer.count) {
                    guard let outData = ablPointer[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    for f in 0..<frames {
                        outData[f] = interleaved[f * chCount + ch]
                    }
                }
            }

            return noErr
        }

        audioEngine.attach(node)
        audioEngine.connect(node, to: audioEngine.mainMixerNode, format: avFormat)
        audioEngine.connect(audioEngine.mainMixerNode, to: audioEngine.outputNode, format: nil)

        // Install tap on mainMixerNode for spectrum analysis and audio data callbacks.
        // Runs on a separate (non-real-time) thread managed by AVAudioEngine.
        let tapBufferSize: AVAudioFrameCount = 2048
        audioEngine.mainMixerNode.installTap(onBus: 0, bufferSize: tapBufferSize, format: nil) { [weak self] pcmBuffer, _ in
            guard let self = self else { return }

            guard let floatData = pcmBuffer.floatChannelData else { return }
            let frames = Int(pcmBuffer.frameLength)
            let channels = Int(pcmBuffer.format.channelCount)

            if let analyzer = self.spectrumAnalyzer, analyzer.isEnabled {
                if pcmBuffer.format.isInterleaved {
                    analyzer.feed(samples: floatData[0], frameCount: frames, channelCount: channels)
                } else {
                    // Non-interleaved: feed left channel only (mono mix).
                    analyzer.feed(samples: floatData[0], frameCount: frames, channelCount: 1)
                }
            }

            if let callback = self.onAudioData {
                if pcmBuffer.format.isInterleaved {
                    callback(floatData[0], frames, channels, Int(pcmBuffer.format.sampleRate))
                } else {
                    callback(floatData[0], frames, 1, Int(pcmBuffer.format.sampleRate))
                }
            }
        }

        audioEngine.prepare()

        do {
            try audioEngine.start()
        } catch {
            throw FFmpegError.resourceAllocationFailed(resource: "AVAudioEngine.start: \(error.localizedDescription)")
        }

        self.engine = audioEngine
        self.sourceNode = node
        isStarted = true
    }

    /// Enqueues a PCM audio buffer for playback.
    private var lastLowWaterLogTime: UInt64 = 0

    func enqueue(_ buffer: AudioBuffer) {
        os_unfair_lock_lock(&bufferLock)
        bufferQueue.append(buffer)
        let count = bufferQueue.count
        os_unfair_lock_unlock(&bufferLock)

        if count <= 3 {
            let now = mach_absolute_time()
            if now - lastLowWaterLogTime > 1_000_000_000 {
                lastLowWaterLogTime = now
                print("[AudioRenderer] 📉 low buffer: \(count) queued, duration=\(String(format: "%.2f", buffer.duration))s")
            }
        }
    }

    /// Pauses audio playback.
    func pause() {
        guard let engine = engine, isStarted, engine.isRunning else { return }
        engine.pause()
    }

    /// Resumes audio playback after a pause.
    func resume() {
        guard let engine = engine, isStarted, !engine.isRunning else { return }
        do {
            try engine.start()
        } catch {
            print("[AudioRenderer] resume failed: \(error.localizedDescription)")
        }
    }

    /// Flushes all queued audio buffers without stopping the engine.
    ///
    /// Used during seek to clear stale audio data before new data arrives.
    func flushQueue() {
        setStopping(true)
        os_unfair_lock_lock(&bufferLock)
        let flushedCount = bufferQueue.count
        for buffer in bufferQueue {
            buffer.data.deallocate()
        }
        bufferQueue.removeAll()
        currentBufferOffset = 0
        os_unfair_lock_unlock(&bufferLock)
        setStopping(false)
        print("[AudioRenderer] 🗑️ flushed \(flushedCount) buffers (seek/stop)")
    }

    /// Stops audio playback and releases all resources.
    ///
    /// After calling `stop()`, you must call `start(format:)` again to resume playback.
    func stop() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        guard isStarted else { return }

        setStopping(true)

        if let engine = engine {
            engine.mainMixerNode.removeTap(onBus: 0)
            engine.stop()

            if let node = sourceNode {
                engine.detach(node)
            }

            self.sourceNode = nil
            self.engine = nil
        }

        interleavedScratch?.deallocate()
        interleavedScratch = nil
        interleavedScratchCapacity = 0

        os_unfair_lock_lock(&bufferLock)
        for buffer in bufferQueue {
            buffer.data.deallocate()
        }
        bufferQueue.removeAll()
        currentBufferOffset = 0
        os_unfair_lock_unlock(&bufferLock)

        isStarted = false
        setStopping(false)
    }

    // MARK: - Render Block Data Provider

    /// Underrun tracking for debug logging.
    private var underrunCount: Int = 0
    private var lastUnderrunLogTime: UInt64 = 0
    
    /// Whether the previous render callback had an underrun (used for fade-in on recovery).
    private var wasUnderrun: Bool = false
    
    /// Short crossfade ramp length in samples to prevent pops at underrun boundaries.
    private let fadeRampSamples: Int = 128

    /// Fills the output buffer by pulling samples from the buffer queue.
    ///
    /// Called from the AVAudioSourceNode render block on the audio thread.
    fileprivate func fillBuffer(_ output: UnsafeMutablePointer<Float>, frameCount: Int, channelCount: Int) {
        let totalSamples = frameCount * channelCount

        guard !isStopping else {
            output.update(repeating: 0, count: totalSamples)
            return
        }

        var samplesWritten = 0

        os_unfair_lock_lock(&bufferLock)

        while samplesWritten < totalSamples && !bufferQueue.isEmpty {
            let front = bufferQueue[0]
            let frontTotalSamples = front.frameCount * front.channelCount
            let availableSamples = frontTotalSamples - currentBufferOffset
            let samplesToRead = min(totalSamples - samplesWritten, availableSamples)

            output.advanced(by: samplesWritten)
                .update(from: front.data.advanced(by: currentBufferOffset), count: samplesToRead)

            samplesWritten += samplesToRead
            currentBufferOffset += samplesToRead

            if currentBufferOffset >= frontTotalSamples {
                let consumed = bufferQueue.removeFirst()
                consumed.data.deallocate()
                currentBufferOffset = 0
            }
        }

        os_unfair_lock_unlock(&bufferLock)

        if samplesWritten < totalSamples {
            // Fade out the tail of valid samples to avoid a hard cut to silence
            if samplesWritten > 0 {
                let fadeLen = min(fadeRampSamples * channelCount, samplesWritten)
                let fadeStart = samplesWritten - fadeLen
                for i in 0..<fadeLen {
                    let gain = Float(fadeLen - 1 - i) / Float(fadeLen)
                    output[fadeStart + i] *= gain
                }
            }
            
            let remaining = totalSamples - samplesWritten
            output.advanced(by: samplesWritten).update(repeating: 0, count: remaining)
            wasUnderrun = true

            underrunCount += 1
            let now = mach_absolute_time()
            if now - lastUnderrunLogTime > 1_000_000_000 {
                lastUnderrunLogTime = now
                print("[AudioRenderer] ⚠️ buffer underrun #\(underrunCount): requested=\(frameCount) frames, got=\(samplesWritten / max(channelCount, 1))")
            }
        } else {
            // Fade in after recovering from underrun to avoid a pop
            if wasUnderrun {
                let fadeLen = min(fadeRampSamples * channelCount, totalSamples)
                for i in 0..<fadeLen {
                    let gain = Float(i) / Float(fadeLen)
                    output[i] *= gain
                }
                wasUnderrun = false
            }
            underrunCount = 0
        }

        guard samplesWritten > 0 else { return }

        // Apply FFmpeg avfilter graph (loudnorm, atempo, volume)
        if let graph = audioFilterGraph, graph.isActive {
            let buf = AudioBuffer(
                data: output,
                frameCount: frameCount,
                channelCount: channelCount,
                sampleRate: sampleRate
            )
            let processed = graph.process(buf)
            if processed.data != output {
                let outSamples = processed.frameCount * processed.channelCount
                let copyCount = min(outSamples, totalSamples)
                output.update(from: processed.data, count: copyCount)
                if copyCount < totalSamples {
                    output.advanced(by: copyCount).update(repeating: 0, count: totalSamples - copyCount)
                }
                processed.data.deallocate()
            }
        }

        // Apply EQ filter
        if let filter = eqFilter {
            let buf = AudioBuffer(
                data: output,
                frameCount: frameCount,
                channelCount: channelCount,
                sampleRate: sampleRate
            )
            _ = filter.process(buf)
        }

        // Audio repair engine (after all effects, before output)
        if let engine = repairEngine, engine.isActive {
            engine.process(output, frameCount: frameCount, channelCount: channelCount, sampleRate: sampleRate)
        }
    }
}
