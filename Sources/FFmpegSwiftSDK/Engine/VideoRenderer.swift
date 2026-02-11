// VideoRenderer.swift
// FFmpegSwiftSDK
//
// Renders decoded video frames to a caller-provided display layer.
// Uses AVSampleBufferDisplayLayer for efficient CVPixelBuffer rendering
// on both macOS and iOS.

import Foundation
import CoreVideo
import QuartzCore
import AVFoundation

/// Renders decoded video frames onto a `CALayer` provided by the caller.
///
/// `VideoRenderer` wraps an `AVSampleBufferDisplayLayer` to efficiently display
/// `CVPixelBuffer` content from decoded `VideoFrame` instances. The display layer
/// is attached to a caller-provided `CALayer` via `attach(to:)`.
///
/// Usage:
/// ```swift
/// let renderer = VideoRenderer()
/// renderer.attach(to: someView.layer)
/// renderer.render(decodedFrame)
/// // ...
/// renderer.clear()
/// ```
///
/// Thread safety: All rendering operations are dispatched to the main thread
/// to comply with Core Animation's threading requirements.
final class VideoRenderer {

    // MARK: - Properties

    /// The caller-provided layer that hosts the display layer.
    private weak var displayLayer: CALayer?

    /// The sample buffer display layer used for efficient CVPixelBuffer rendering.
    private var sampleBufferLayer: AVSampleBufferDisplayLayer?

    // MARK: - Initialization

    init() {}

    deinit {
        clear()
    }

    // MARK: - Public Interface

    /// Attaches the renderer to a display layer.
    ///
    /// Creates an `AVSampleBufferDisplayLayer` and adds it as a sublayer of the
    /// provided layer. Any previously attached layer is cleared first.
    ///
    /// - Parameter layer: The `CALayer` to render video frames into.
    func attach(to layer: CALayer) {
        // Clean up any previous attachment
        clear()

        displayLayer = layer

        let sbLayer = AVSampleBufferDisplayLayer()
        sbLayer.videoGravity = .resizeAspect
        sbLayer.frame = layer.bounds

        let targetLayer = layer
        let targetSBLayer = sbLayer
        if Thread.isMainThread {
            targetLayer.addSublayer(targetSBLayer)
        } else {
            DispatchQueue.main.sync {
                targetLayer.addSublayer(targetSBLayer)
            }
        }

        sampleBufferLayer = sbLayer
    }

    /// Renders a decoded video frame to the attached display layer.
    ///
    /// Converts the frame's `CVPixelBuffer` into a `CMSampleBuffer` and enqueues
    /// it on the `AVSampleBufferDisplayLayer` for display.
    ///
    /// - Parameter frame: The decoded video frame to render.
    func render(_ frame: VideoFrame) {
        guard let sbLayer = sampleBufferLayer else { return }

        guard let sampleBuffer = createSampleBuffer(from: frame) else { return }

        let layer = sbLayer
        let buffer = sampleBuffer
        if Thread.isMainThread {
            layer.enqueue(buffer)
        } else {
            DispatchQueue.main.async {
                layer.enqueue(buffer)
            }
        }
    }

    /// Clears the display and removes the rendering layer.
    ///
    /// Flushes any pending frames and removes the sample buffer display layer
    /// from its parent. After calling `clear()`, you must call `attach(to:)`
    /// again before rendering.
    func clear() {
        if let sbLayer = sampleBufferLayer {
            let layer = sbLayer
            if Thread.isMainThread {
                layer.flushAndRemoveImage()
                layer.removeFromSuperlayer()
            } else {
                DispatchQueue.main.sync {
                    layer.flushAndRemoveImage()
                    layer.removeFromSuperlayer()
                }
            }
        }
        sampleBufferLayer = nil
        displayLayer = nil
    }

    // MARK: - Private Helpers

    /// Creates a `CMSampleBuffer` from a `VideoFrame`'s pixel buffer and timing info.
    ///
    /// - Parameter frame: The video frame to convert.
    /// - Returns: A `CMSampleBuffer` ready for display, or `nil` if creation fails.
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
