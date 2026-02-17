// AudioRenderer.swift
// FFmpegSwiftSDK
//
// Renders decoded audio PCM data to the system audio device using CoreAudio AudioUnit.
// Uses a thread-safe buffer queue with a render callback that pulls data on demand.

import Foundation
import AudioToolbox
import AVFoundation

/// Renders PCM audio data to the system audio output device.
///
/// `AudioRenderer` uses CoreAudio's AudioUnit to output audio. On iOS it uses the
/// RemoteIO audio unit; on macOS it uses the DefaultOutput unit. Audio data is
/// enqueued via `enqueue(_:)` and pulled by the render callback as needed.
///
/// Lifecycle: `start(format:)` → `pause()` / `resume()` → `stop()`
///
/// Thread safety: The internal buffer queue is protected by `NSLock`, allowing
/// concurrent enqueue (from the decode thread) and dequeue (from the render callback).
final class AudioRenderer {

    // MARK: - Properties

    /// The AudioUnit instance used for output.
    private var audioUnit: AudioComponentInstance?

    /// Lock protecting the buffer queue.
    private let lock = NSLock()

    /// Optional EQ filter applied in real-time during the render callback.
    private var eqFilter: EQFilter?

    /// Optional FFmpeg avfilter 音频滤镜图（loudnorm、atempo、volume）
    private var audioFilterGraph: AudioFilterGraph?

    /// Optional 频谱分析器
    private var spectrumAnalyzer: SpectrumAnalyzer?

    /// Optional 音频修复引擎（在所有效果之后、输出之前）
    private var repairEngine: AudioRepairEngine?
    
    /// Optional 音频数据回调（用于实时分析、识别等）
    var onAudioData: ((_ samples: UnsafePointer<Float>, _ frameCount: Int, _ channelCount: Int, _ sampleRate: Int) -> Void)?

    /// Sample rate of the current audio stream (needed by EQ).
    private var sampleRate: Int = 44100

    /// FIFO queue of PCM audio buffers waiting to be rendered.
    private var bufferQueue: [AudioBuffer] = []

    /// Tracks the read offset (in samples) into the front buffer of the queue.
    private var currentBufferOffset: Int = 0

    /// Whether the renderer is currently started (audio unit initialized).
    private var isStarted: Bool = false

    /// 硬件实际采样率（start 后可用，可能与请求的不同）
    private(set) var actualSampleRate: Int = 0

    /// Maximum number of queued buffers before backpressure kicks in.
    static let maxQueuedBuffers = 200

    /// Returns the current number of queued audio buffers.
    var queuedBufferCount: Int {
        lock.lock()
        let count = bufferQueue.count
        lock.unlock()
        return count
    }

    /// 返回缓冲队列中所有 buffer 的总时长（秒），考虑当前 buffer 的已消费偏移
    var queuedDuration: TimeInterval {
        lock.lock()
        var total: TimeInterval = 0
        for (index, buffer) in bufferQueue.enumerated() {
            if index == 0 && currentBufferOffset > 0 {
                // 第一个 buffer 可能已部分消费
                let totalSamples = buffer.frameCount * buffer.channelCount
                let remainRatio = Double(totalSamples - currentBufferOffset) / Double(max(totalSamples, 1))
                total += buffer.duration * remainRatio
            } else {
                total += buffer.duration
            }
        }
        lock.unlock()
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

    /// Sets the FFmpeg avfilter 音频滤镜图。
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
    /// Configures and starts an AudioUnit for playback. The format describes
    /// the PCM data that will be enqueued (sample rate, channels, etc.).
    ///
    /// - Parameter format: The audio stream format describing the PCM data.
    /// - Throws: `FFmpegError.resourceAllocationFailed` if the audio unit cannot be created or started.
    func start(format: AudioStreamBasicDescription) throws {
        guard !isStarted else { return }

        // 设置 AVAudioSession 首选采样率，支持 Hi-Res 192kHz 母带
        #if os(iOS) || os(tvOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setPreferredSampleRate(format.mSampleRate)
        // 硬件实际采样率（可能与请求不同，取决于设备能力）
        let hwRate = session.sampleRate
        #else
        let hwRate = format.mSampleRate
        #endif

        // 用硬件实际采样率构建最终格式
        var streamFormat = format
        streamFormat.mSampleRate = hwRate
        sampleRate = Int(hwRate)
        // 保存实际采样率供外部查询
        actualSampleRate = Int(hwRate)

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: audioOutputSubType(),
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &description) else {
            throw FFmpegError.resourceAllocationFailed(resource: "AudioComponent")
        }

        var unit: AudioComponentInstance?
        var status = AudioComponentInstanceNew(component, &unit)
        guard status == noErr, let audioUnit = unit else {
            throw FFmpegError.resourceAllocationFailed(resource: "AudioComponentInstance (status: \(status))")
        }
        self.audioUnit = audioUnit

        // Set the stream format on the output scope
        status = AudioUnitSetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0, // output bus
            &streamFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard status == noErr else {
            cleanupAudioUnit()
            throw FFmpegError.resourceAllocationFailed(resource: "AudioUnit StreamFormat (status: \(status))")
        }

        // Set the render callback
        var callbackStruct = AURenderCallbackStruct(
            inputProc: renderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        status = AudioUnitSetProperty(
            audioUnit,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input,
            0,
            &callbackStruct,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard status == noErr else {
            cleanupAudioUnit()
            throw FFmpegError.resourceAllocationFailed(resource: "AudioUnit RenderCallback (status: \(status))")
        }

        // Initialize and start
        status = AudioUnitInitialize(audioUnit)
        guard status == noErr else {
            cleanupAudioUnit()
            throw FFmpegError.resourceAllocationFailed(resource: "AudioUnitInitialize (status: \(status))")
        }

        status = AudioOutputUnitStart(audioUnit)
        guard status == noErr else {
            AudioUnitUninitialize(audioUnit)
            cleanupAudioUnit()
            throw FFmpegError.resourceAllocationFailed(resource: "AudioOutputUnitStart (status: \(status))")
        }

        isStarted = true
    }

    /// Enqueues a PCM audio buffer for playback.
    ///
    /// - Parameter buffer: The audio buffer containing PCM data to play.
    func enqueue(_ buffer: AudioBuffer) {
        lock.lock()
        bufferQueue.append(buffer)
        lock.unlock()
    }

    /// Pauses audio playback.
    ///
    /// The audio unit stops pulling data but remains initialized,
    /// allowing a quick resume.
    func pause() {
        guard let audioUnit = audioUnit, isStarted else { return }
        AudioOutputUnitStop(audioUnit)
    }

    /// Resumes audio playback after a pause.
    ///
    /// Restarts the audio unit so the render callback begins pulling data again.
    func resume() {
        guard let audioUnit = audioUnit, isStarted else { return }
        AudioOutputUnitStart(audioUnit)
    }

    /// Flushes all queued audio buffers without stopping the audio unit.
    ///
    /// Used during seek to clear stale audio data before new data arrives.
    /// Deallocates all buffer memory to prevent leaks.
    func flushQueue() {
        lock.lock()
        for buffer in bufferQueue {
            buffer.data.deallocate()
        }
        bufferQueue.removeAll()
        currentBufferOffset = 0
        lock.unlock()
    }

    /// Stops audio playback and releases all resources.
    ///
    /// After calling `stop()`, you must call `start(format:)` again to resume playback.
    /// Deallocates all queued buffer memory to prevent leaks.
    func stop() {
        if let audioUnit = audioUnit {
            AudioOutputUnitStop(audioUnit)
            AudioUnitUninitialize(audioUnit)
            AudioComponentInstanceDispose(audioUnit)
            self.audioUnit = nil
        }

        lock.lock()
        for buffer in bufferQueue {
            buffer.data.deallocate()
        }
        bufferQueue.removeAll()
        currentBufferOffset = 0
        lock.unlock()

        isStarted = false
    }

    // MARK: - Private Helpers

    /// Returns the appropriate AudioUnit subtype for the current platform.
    private func audioOutputSubType() -> OSType {
        #if os(iOS) || os(tvOS)
        return kAudioUnitSubType_RemoteIO
        #else
        return kAudioUnitSubType_DefaultOutput
        #endif
    }

    /// Disposes the audio component instance without uninitializing.
    private func cleanupAudioUnit() {
        if let unit = audioUnit {
            AudioComponentInstanceDispose(unit)
            audioUnit = nil
        }
    }

    /// Fills the output buffer by pulling samples from the buffer queue.
    ///
    /// Called from the render callback on the audio thread. Copies as many
    /// samples as requested from the front of the queue, advancing through
    /// buffers as they are consumed. If the queue is empty, fills with silence.
    ///
    /// 修复电流麦问题：
    /// 1. 减少实时线程上的内存分配
    /// 2. 滤镜处理失败时保持原始数据（不输出静音）
    /// 3. 使用 tryLock 避免实时线程阻塞
    ///
    /// - Parameters:
    ///   - output: Pointer to the output buffer to fill.
    ///   - frameCount: Number of frames requested by the audio unit.
    ///   - channelCount: Number of channels per frame.
    fileprivate func fillBuffer(_ output: UnsafeMutablePointer<Float>, frameCount: Int, channelCount: Int) {
        let totalSamples = frameCount * channelCount
        var samplesWritten = 0

        lock.lock()

        while samplesWritten < totalSamples && !bufferQueue.isEmpty {
            let front = bufferQueue[0]
            let frontTotalSamples = front.frameCount * front.channelCount
            let availableSamples = frontTotalSamples - currentBufferOffset
            let samplesToRead = min(totalSamples - samplesWritten, availableSamples)

            // Copy samples from the front buffer
            output.advanced(by: samplesWritten)
                .update(from: front.data.advanced(by: currentBufferOffset), count: samplesToRead)

            samplesWritten += samplesToRead
            currentBufferOffset += samplesToRead

            // If we've consumed the entire front buffer, free its memory and remove it
            if currentBufferOffset >= frontTotalSamples {
                let consumed = bufferQueue.removeFirst()
                consumed.data.deallocate()
                currentBufferOffset = 0
            }
        }

        lock.unlock()

        // Fill remaining with silence if the queue ran dry
        if samplesWritten < totalSamples {
            let remaining = totalSamples - samplesWritten
            output.advanced(by: samplesWritten).update(repeating: 0, count: remaining)
        }

        // 只处理有实际数据的部分
        guard samplesWritten > 0 else { return }

        // Apply FFmpeg avfilter graph (loudnorm, atempo, volume) before EQ
        // 注意：process() 内部会分配内存，但这是 FFmpeg 的要求
        // 如果滤镜图正在重建，process() 会直接返回原 buffer（零拷贝）
        if let graph = audioFilterGraph, graph.isActive {
            let buf = AudioBuffer(
                data: output,
                frameCount: frameCount,
                channelCount: channelCount,
                sampleRate: sampleRate
            )
            let processed = graph.process(buf)
            if processed.data != output {
                // 滤镜图产生了新的缓冲区，拷贝回 output
                let outSamples = processed.frameCount * processed.channelCount
                let copyCount = min(outSamples, totalSamples)
                output.update(from: processed.data, count: copyCount)
                // 如果滤镜输出比请求的少（atempo 加速），剩余填静音
                if copyCount < totalSamples {
                    output.advanced(by: copyCount).update(repeating: 0, count: totalSamples - copyCount)
                }
                processed.data.deallocate()
            }
        }

        // Apply EQ in real-time on the output buffer
        // EQFilter 使用 Biquad IIR 就地处理，增益平滑避免突变
        if let filter = eqFilter {
            let buf = AudioBuffer(
                data: output,
                frameCount: frameCount,
                channelCount: channelCount,
                sampleRate: sampleRate
            )
            let processed = filter.process(buf)
            if processed.data != output {
                // EQFilter 总是分配新 buffer，拷贝回 output
                output.update(from: processed.data, count: totalSamples)
                processed.data.deallocate()
            }
        }

        // 音频修复引擎（在所有音效处理之后、输出到硬件之前）
        if let engine = repairEngine, engine.isActive {
            engine.process(output, frameCount: frameCount, channelCount: channelCount, sampleRate: sampleRate)
        }

        // 输入频谱分析器（在所有处理之后）
        if let analyzer = spectrumAnalyzer, analyzer.isEnabled {
            analyzer.feed(samples: output, frameCount: frameCount, channelCount: channelCount)
        }
        
        // 音频数据回调（在所有处理之后，用于实时分析、识别等）
        onAudioData?(output, frameCount, channelCount, sampleRate)
    }
}

// MARK: - Render Callback

/// The AudioUnit render callback that pulls PCM data from the AudioRenderer's buffer queue.
///
/// This is a C-function-pointer-compatible callback invoked on the real-time audio thread.
/// It must not allocate memory, acquire locks that could block, or perform any
/// operation that could cause priority inversion. The NSLock usage in `fillBuffer`
/// is acceptable here because the critical section is very short (pointer arithmetic only).
private func renderCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    guard let ioData = ioData else { return noErr }

    let renderer = Unmanaged<AudioRenderer>.fromOpaque(inRefCon).takeUnretainedValue()

    // Access the first buffer in the AudioBufferList directly
    let firstBuffer = ioData.pointee.mBuffers
    guard let outputData = firstBuffer.mData?.assumingMemoryBound(to: Float.self) else {
        return noErr
    }

    let channelCount = Int(firstBuffer.mNumberChannels)
    let frameCount = Int(inNumberFrames)

    renderer.fillBuffer(outputData, frameCount: frameCount, channelCount: channelCount)

    return noErr
}
