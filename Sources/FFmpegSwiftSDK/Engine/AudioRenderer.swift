// AudioRenderer.swift
// FFmpegSwiftSDK
//
// Renders decoded audio PCM data to the system audio device using CoreAudio AudioUnit.
// Uses a thread-safe buffer queue with a render callback that pulls data on demand.

import Foundation
import AudioToolbox

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

    /// Sample rate of the current audio stream (needed by EQ).
    private var sampleRate: Int = 44100

    /// FIFO queue of PCM audio buffers waiting to be rendered.
    private var bufferQueue: [AudioBuffer] = []

    /// Tracks the read offset (in samples) into the front buffer of the queue.
    private var currentBufferOffset: Int = 0

    /// Whether the renderer is currently started (audio unit initialized).
    private var isStarted: Bool = false

    /// Maximum number of queued buffers before backpressure kicks in.
    static let maxQueuedBuffers = 200

    /// Returns the current number of queued audio buffers.
    var queuedBufferCount: Int {
        lock.lock()
        let count = bufferQueue.count
        lock.unlock()
        return count
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

    /// Starts the audio renderer with the given audio format.
    ///
    /// Configures and starts an AudioUnit for playback. The format describes
    /// the PCM data that will be enqueued (sample rate, channels, etc.).
    ///
    /// - Parameter format: The audio stream format describing the PCM data.
    /// - Throws: `FFmpegError.resourceAllocationFailed` if the audio unit cannot be created or started.
    func start(format: AudioStreamBasicDescription) throws {
        guard !isStarted else { return }
        sampleRate = Int(format.mSampleRate)

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
        var streamFormat = format
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
    /// The buffer is appended to the internal FIFO queue and will be consumed
    /// by the render callback. This method is thread-safe.
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

    /// Stops audio playback and releases all resources.
    ///
    /// After calling `stop()`, you must call `start(format:)` again to resume playback.
    func stop() {
        if let audioUnit = audioUnit {
            AudioOutputUnitStop(audioUnit)
            AudioUnitUninitialize(audioUnit)
            AudioComponentInstanceDispose(audioUnit)
            self.audioUnit = nil
        }

        lock.lock()
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

            // If we've consumed the entire front buffer, remove it
            if currentBufferOffset >= frontTotalSamples {
                bufferQueue.removeFirst()
                currentBufferOffset = 0
            }
        }

        lock.unlock()

        // Fill remaining with silence if the queue ran dry
        if samplesWritten < totalSamples {
            let remaining = totalSamples - samplesWritten
            output.advanced(by: samplesWritten).update(repeating: 0, count: remaining)
        }

        // Apply EQ in real-time on the output buffer
        if let filter = eqFilter, samplesWritten > 0 {
            let buf = AudioBuffer(
                data: output,
                frameCount: frameCount,
                channelCount: channelCount,
                sampleRate: sampleRate
            )
            let processed = filter.process(buf)
            // Copy processed data back to output
            output.update(from: processed.data, count: totalSamples)
            // Free the processed buffer's allocation
            processed.data.deallocate()
            // Do NOT deallocate buf.data — it points to the output buffer we don't own
        }
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
