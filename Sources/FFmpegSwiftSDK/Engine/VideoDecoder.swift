// VideoDecoder.swift
// FFmpegSwiftSDK
//
// Decodes compressed video packets into VideoFrame objects containing CVPixelBuffer.
// Uses FFmpeg's avcodec API for decoding and CoreVideo for pixel buffer creation.
// Copies YUV plane data from decoded AVFrame into CVPixelBuffer (NV12 format).

import Foundation
import CFFmpeg
import CoreVideo

// MARK: - VideoDecoder

/// Decodes compressed video packets into `VideoFrame` objects with `CVPixelBuffer` output.
///
/// `VideoDecoder` wraps an FFmpeg `AVCodecContext` for video decoding and converts
/// decoded YUV frames into `CVPixelBuffer` instances suitable for rendering.
///
/// Supported codecs: H.264, H.265/HEVC (per Requirement 3.5).
///
/// Usage:
/// ```swift
/// let decoder = try VideoDecoder(codecParameters: stream.codecpar, codecID: AV_CODEC_ID_H264)
/// let videoFrame = try decoder.decode(packet: videoPacket)
/// // Use videoFrame.pixelBuffer for rendering
/// ```
///
/// - Important: This is an internal type used by the engine layer.
///   It is not exposed as public API.
final class VideoDecoder: Decoder {
    typealias Output = VideoFrame

    // MARK: - Properties

    /// The codec context wrapper managing the underlying AVCodecContext.
    private let codecContext: FFmpegCodecContext

    /// The time base of the video stream, used for PTS conversion.
    private let timeBase: AVRational

    // MARK: - Initialization

    /// Creates a new `VideoDecoder` for the given codec parameters.
    ///
    /// Validates that the codec is supported (H.264 or H.265/HEVC), configures
    /// the codec context from the stream parameters, and opens the decoder.
    ///
    /// - Parameters:
    ///   - codecParameters: The codec parameters from the video stream.
    ///   - codecID: The codec ID to decode.
    ///   - timeBase: The time base of the video stream for PTS conversion.
    ///     Defaults to 1/90000 (common for MPEG-TS).
    /// - Throws: `FFmpegError.unsupportedFormat` if the codec is not supported,
    ///   or other `FFmpegError` variants if initialization fails.
    init(
        codecParameters: UnsafePointer<AVCodecParameters>,
        codecID: AVCodecID,
        timeBase: AVRational = AVRational(num: 1, den: 90000)
    ) throws {
        // Validate supported codec
        try validateCodecSupported(codecID, in: supportedVideoCodecIDs)

        // Find the decoder
        guard let decoder = avcodec_find_decoder(codecID) else {
            let codecName = String(cString: avcodec_get_name(codecID))
            throw FFmpegError.unsupportedFormat(codecName: codecName)
        }

        // Allocate and configure codec context
        codecContext = try FFmpegCodecContext(codec: decoder)
        try codecContext.setParameters(from: codecParameters)
        try codecContext.open(codec: decoder)

        self.timeBase = timeBase
    }

    // MARK: - Decoding

    /// Decodes a compressed video packet into a `VideoFrame`.
    ///
    /// Sends the packet to the decoder, receives the decoded frame, then
    /// converts the YUV data into a `CVPixelBuffer` wrapped in a `VideoFrame`.
    ///
    /// - Parameter packet: A pointer to the AVPacket containing compressed video data.
    /// - Returns: A `VideoFrame` containing the decoded pixel data and timing info.
    /// - Throws: `FFmpegError.decodingFailed` if decoding fails.
    func decode(packet: UnsafeMutablePointer<AVPacket>) throws -> VideoFrame {
        guard let ctx = codecContext.rawPointer else {
            throw FFmpegError.resourceAllocationFailed(resource: "AVCodecContext (nil)")
        }

        // Send packet to decoder
        let sendRet = avcodec_send_packet(ctx, packet)
        guard sendRet >= 0 else {
            throw FFmpegError.decodingFailed(code: sendRet, message: "avcodec_send_packet failed")
        }

        // Allocate frame for receiving decoded data
        guard let frame = av_frame_alloc() else {
            throw FFmpegError.resourceAllocationFailed(resource: "AVFrame")
        }
        defer {
            var framePtr: UnsafeMutablePointer<AVFrame>? = frame
            av_frame_free(&framePtr)
        }

        // Receive decoded frame
        let recvRet = avcodec_receive_frame(ctx, frame)
        guard recvRet >= 0 else {
            throw FFmpegError.decodingFailed(code: recvRet, message: "avcodec_receive_frame failed")
        }

        let width = Int(frame.pointee.width)
        let height = Int(frame.pointee.height)

        // Convert AVFrame to CVPixelBuffer
        let pixelBuffer = try createPixelBuffer(from: frame, width: width, height: height)

        // Calculate PTS in seconds
        let pts: TimeInterval
        if frame.pointee.pts != Int64(bitPattern: UInt64(0x8000000000000000)) {
            // AV_NOPTS_VALUE check
            pts = TimeInterval(frame.pointee.pts) * TimeInterval(timeBase.num) / TimeInterval(timeBase.den)
        } else {
            pts = 0
        }

        // Calculate duration in seconds
        let duration: TimeInterval
        if frame.pointee.duration > 0 {
            duration = TimeInterval(frame.pointee.duration) * TimeInterval(timeBase.num) / TimeInterval(timeBase.den)
        } else {
            // Estimate from frame rate if available
            duration = 0
        }

        return VideoFrame(
            pixelBuffer: pixelBuffer,
            pts: pts,
            duration: duration,
            width: width,
            height: height
        )
    }

    // MARK: - Pixel Buffer Creation

    /// Creates a `CVPixelBuffer` from a decoded AVFrame.
    ///
    /// Handles YUV420P (planar) format by copying Y, U, and V planes into
    /// an NV12 CVPixelBuffer. For other formats, copies the Y plane and
    /// interleaves UV data as needed.
    ///
    /// - Parameters:
    ///   - frame: The decoded AVFrame containing YUV data.
    ///   - width: The frame width in pixels.
    ///   - height: The frame height in pixels.
    /// - Returns: A `CVPixelBuffer` containing the frame's pixel data.
    /// - Throws: `FFmpegError.resourceAllocationFailed` if pixel buffer creation fails.
    private func createPixelBuffer(
        from frame: UnsafeMutablePointer<AVFrame>,
        width: Int,
        height: Int
    ) throws -> CVPixelBuffer {
        // Determine pixel format
        let pixelFormat = frame.pointee.format

        // Create CVPixelBuffer
        // Use NV12 (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) for YUV420P input
        // This is the most common format for video rendering on Apple platforms
        let cvPixelFormat: OSType
        if pixelFormat == AV_PIX_FMT_NV12.rawValue {
            cvPixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        } else {
            // For YUV420P and other formats, we'll convert to NV12
            cvPixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }

        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            cvPixelFormat,
            attrs as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw FFmpegError.resourceAllocationFailed(resource: "CVPixelBuffer")
        }

        // Lock the pixel buffer for writing
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        if pixelFormat == AV_PIX_FMT_NV12.rawValue {
            // NV12: Copy Y plane and interleaved UV plane directly
            copyNV12Data(from: frame, to: buffer, width: width, height: height)
        } else if pixelFormat == AV_PIX_FMT_YUV420P.rawValue {
            // YUV420P: Copy Y plane, interleave U and V into NV12 UV plane
            copyYUV420PToNV12(from: frame, to: buffer, width: width, height: height)
        } else {
            // Fallback: attempt YUV420P-style copy (most decoders output YUV420P)
            copyYUV420PToNV12(from: frame, to: buffer, width: width, height: height)
        }

        return buffer
    }

    /// Copies NV12 data from an AVFrame directly into a CVPixelBuffer.
    ///
    /// - Parameters:
    ///   - frame: The source AVFrame in NV12 format.
    ///   - buffer: The destination CVPixelBuffer.
    ///   - width: Frame width in pixels.
    ///   - height: Frame height in pixels.
    private func copyNV12Data(
        from frame: UnsafeMutablePointer<AVFrame>,
        to buffer: CVPixelBuffer,
        width: Int,
        height: Int
    ) {
        // Copy Y plane (plane 0)
        if let yDst = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
           let ySrc = frame.pointee.data.0 {
            let yDstStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let ySrcStride = Int(frame.pointee.linesize.0)
            let yDstPtr = yDst.assumingMemoryBound(to: UInt8.self)
            for row in 0..<height {
                memcpy(yDstPtr + row * yDstStride, ySrc + row * ySrcStride, min(width, ySrcStride))
            }
        }

        // Copy UV plane (plane 1) - already interleaved in NV12
        if let uvDst = CVPixelBufferGetBaseAddressOfPlane(buffer, 1),
           let uvSrc = frame.pointee.data.1 {
            let uvDstStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            let uvSrcStride = Int(frame.pointee.linesize.1)
            let uvHeight = height / 2
            let uvDstPtr = uvDst.assumingMemoryBound(to: UInt8.self)
            for row in 0..<uvHeight {
                memcpy(uvDstPtr + row * uvDstStride, uvSrc + row * uvSrcStride, min(width, uvSrcStride))
            }
        }
    }

    /// Copies YUV420P planar data from an AVFrame into an NV12 CVPixelBuffer.
    ///
    /// The Y plane is copied directly. The U and V planes are interleaved
    /// into the NV12 UV plane (UVUVUV...).
    ///
    /// - Parameters:
    ///   - frame: The source AVFrame in YUV420P format.
    ///   - buffer: The destination CVPixelBuffer in NV12 format.
    ///   - width: Frame width in pixels.
    ///   - height: Frame height in pixels.
    private func copyYUV420PToNV12(
        from frame: UnsafeMutablePointer<AVFrame>,
        to buffer: CVPixelBuffer,
        width: Int,
        height: Int
    ) {
        // Copy Y plane (plane 0)
        if let yDst = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
           let ySrc = frame.pointee.data.0 {
            let yDstStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let ySrcStride = Int(frame.pointee.linesize.0)
            let yDstPtr = yDst.assumingMemoryBound(to: UInt8.self)
            for row in 0..<height {
                memcpy(yDstPtr + row * yDstStride, ySrc + row * ySrcStride, min(width, ySrcStride))
            }
        }

        // Interleave U and V planes into NV12 UV plane
        if let uvDst = CVPixelBufferGetBaseAddressOfPlane(buffer, 1),
           let uSrc = frame.pointee.data.1,
           let vSrc = frame.pointee.data.2 {
            let uvDstStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            let uSrcStride = Int(frame.pointee.linesize.1)
            let vSrcStride = Int(frame.pointee.linesize.2)
            let uvHeight = height / 2
            let uvWidth = width / 2
            let uvDstPtr = uvDst.assumingMemoryBound(to: UInt8.self)

            for row in 0..<uvHeight {
                let dstRow = uvDstPtr + row * uvDstStride
                let uRow = uSrc + row * uSrcStride
                let vRow = vSrc + row * vSrcStride
                for col in 0..<uvWidth {
                    dstRow[col * 2] = uRow[col]
                    dstRow[col * 2 + 1] = vRow[col]
                }
            }
        }
    }

    // MARK: - Flush

    /// Flushes the decoder's internal buffers.
    ///
    /// Sends a flush signal to the codec context, discarding any buffered
    /// frames. Call this when seeking or at end-of-stream.
    func flush() {
        guard let ctx = codecContext.rawPointer else { return }
        avcodec_flush_buffers(ctx)
    }
}
