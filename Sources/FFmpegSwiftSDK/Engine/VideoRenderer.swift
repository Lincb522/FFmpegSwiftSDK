// VideoRenderer.swift
// FFmpegSwiftSDK
//
// Renders decoded video frames using AVSampleBufferDisplayLayer.
// The layer is exposed publicly so callers can embed it in their view hierarchy.

import Foundation
import CoreVideo
import QuartzCore
import AVFoundation

/// Renders decoded video frames via an `AVSampleBufferDisplayLayer`.
///
/// The `sampleBufferDisplayLayer` is created once at init and can be embedded
/// directly into a UIView/NSView layer hierarchy by the caller.
///
/// Thread safety: Enqueue operations are dispatched to the main thread
/// to comply with Core Animation's threading requirements.
final class VideoRenderer {

    // MARK: - Properties

    /// The display layer for video rendering. Embed this in your view hierarchy.
    let sampleBufferDisplayLayer: AVSampleBufferDisplayLayer

    // MARK: - Initialization

    init() {
        sampleBufferDisplayLayer = AVSampleBufferDisplayLayer()
        sampleBufferDisplayLayer.videoGravity = .resizeAspect
    }

    // MARK: - Rendering

    /// Renders a decoded video frame.
    ///
    /// Converts the frame's `CVPixelBuffer` into a `CMSampleBuffer` and enqueues
    /// it on the display layer.
    ///
    /// - Parameter frame: The decoded video frame to render.
    func render(_ frame: VideoFrame) {
        guard let sampleBuffer = createSampleBuffer(from: frame) else { return }

        let layer = sampleBufferDisplayLayer
        let buffer = sampleBuffer
        if Thread.isMainThread {
            layer.enqueue(buffer)
        } else {
            DispatchQueue.main.async {
                layer.enqueue(buffer)
            }
        }
    }

    /// Clears the display, flushing any pending frames.
    func clear() {
        let layer = sampleBufferDisplayLayer
        if Thread.isMainThread {
            layer.flushAndRemoveImage()
        } else {
            DispatchQueue.main.sync {
                layer.flushAndRemoveImage()
            }
        }
    }

    // MARK: - Private Helpers

    private func createSampleBuffer(from frame: VideoFrame) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: frame.pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let format = formatDescription else { return nil }

        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(seconds: frame.duration, preferredTimescale: 90000),
            presentationTimeStamp: CMTime(seconds: frame.pts, preferredTimescale: 90000),
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let createStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: frame.pixelBuffer,
            formatDescription: format,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )
        guard createStatus == noErr else { return nil }

        return sampleBuffer
    }
}
