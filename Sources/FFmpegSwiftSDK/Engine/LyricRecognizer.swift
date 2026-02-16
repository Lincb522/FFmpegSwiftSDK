// LyricRecognizer.swift
// FFmpegSwiftSDK
//
// 歌词识别引擎。使用 WhisperKit 将音频转换为逐字歌词。
// 内部用 FFmpeg 解码音频为 16kHz 单声道 PCM，再交给 WhisperKit 识别。

import Foundation
import CFFmpeg
import WhisperKit

// MARK: - 识别配置

/// 歌词识别配置。
public struct LyricRecognizerConfig {
    /// 语言代码（nil = 自动检测）。如 "zh", "en", "ja"
    public var language: String?

    /// Whisper 模型名称（nil = 自动选择推荐模型）
    /// 可选: "tiny", "base", "small", "medium", "large-v3"
    /// 模型越大识别越准，但速度越慢、占用内存越多
    public var modelName: String?

    /// 是否启用逐字时间戳（默认开启）
    public var wordTimestamps: Bool = true

    /// 进度回调（0~1）
    public var onProgress: ((Float) -> Void)?

    public init(language: String? = nil, modelName: String? = nil) {
        self.language = language
        self.modelName = modelName
    }
}

// MARK: - 歌词识别引擎

/// 歌词识别引擎。
///
/// 使用 WhisperKit 进行语音识别，生成带逐字时间戳的歌词。
/// 内部使用 FFmpeg 解码音频为 16kHz 单声道 PCM。
///
/// ```swift
/// let recognizer = LyricRecognizer()
/// try await recognizer.prepare()  // 下载并加载模型
///
/// let result = try await recognizer.recognize(url: "https://example.com/song.mp3")
///
/// // 转换为歌词行，直接用于 LyricSyncer
/// let lines = result.toLyricLines()
/// lyricSyncer.load(lines: lines)
///
/// // 或导出为增强 LRC 文件
/// let lrc = result.toEnhancedLRC()
/// ```
public final class LyricRecognizer {

    // MARK: - 属性

    /// WhisperKit 实例
    private var whisperKit: WhisperKit?

    /// 目标采样率（Whisper 要求 16kHz）
    private let targetSampleRate: Int = 16000

    /// 是否已准备就绪
    public var isReady: Bool { whisperKit != nil }

    // MARK: - 初始化

    public init() {}

    // MARK: - 准备

    /// 准备识别引擎（下载并加载 Whisper 模型）。
    /// 首次调用会下载模型文件，后续调用使用缓存。
    /// - Parameter modelName: 模型名称（nil = 自动选择推荐模型）
    public func prepare(modelName: String? = nil) async throws {
        if whisperKit != nil { return }

        let config = WhisperKitConfig(
            model: modelName,
            verbose: false,
            prewarm: true
        )
        whisperKit = try await WhisperKit(config)
    }

    // MARK: - 识别方法

    /// 从 URL 识别歌词（支持本地文件和网络流）。
    /// - Parameters:
    ///   - url: 音频 URL
    ///   - config: 识别配置
    /// - Returns: 识别结果
    public func recognize(url: String, config: LyricRecognizerConfig = LyricRecognizerConfig()) async throws -> RecognizedLyric {
        // 自动准备
        if whisperKit == nil {
            try await prepare(modelName: config.modelName)
        }
        guard let kit = whisperKit else {
            throw LyricRecognizerError.backendNotReady
        }

        // 使用 FFmpeg 解码音频为 16kHz 单声道 PCM
        config.onProgress?(0.1)
        let samples = try decodeAudioToPCM(url: url)
        config.onProgress?(0.3)

        // 执行识别
        let startTime = CFAbsoluteTimeGetCurrent()

        let options = DecodingOptions(
            language: config.language,
            wordTimestamps: config.wordTimestamps
        )

        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime

        config.onProgress?(1.0)

        // 转换结果
        return convertResults(results, processingTime: elapsed)
    }

    /// 从 PCM Float32 数据识别歌词。
    /// - Parameters:
    ///   - samples: 16kHz 单声道 Float32 PCM 数据
    ///   - config: 识别配置
    /// - Returns: 识别结果
    public func recognize(samples: [Float], config: LyricRecognizerConfig = LyricRecognizerConfig()) async throws -> RecognizedLyric {
        if whisperKit == nil {
            try await prepare(modelName: config.modelName)
        }
        guard let kit = whisperKit else {
            throw LyricRecognizerError.backendNotReady
        }

        let startTime = CFAbsoluteTimeGetCurrent()

        let options = DecodingOptions(
            language: config.language,
            wordTimestamps: config.wordTimestamps
        )

        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime

        return convertResults(results, processingTime: elapsed)
    }

    /// 从 AudioBuffer 识别歌词。
    /// - Parameters:
    ///   - buffer: SDK 的 AudioBuffer
    ///   - config: 识别配置
    /// - Returns: 识别结果
    public func recognize(buffer: AudioBuffer, config: LyricRecognizerConfig = LyricRecognizerConfig()) async throws -> RecognizedLyric {
        let samples = resampleBuffer(buffer)
        return try await recognize(samples: samples, config: config)
    }

    // MARK: - 结果转换

    /// 将 WhisperKit 结果转换为 RecognizedLyric
    private func convertResults(_ results: [TranscriptionResult], processingTime: TimeInterval) -> RecognizedLyric {
        var segments = [RecognizedSegment]()
        var detectedLanguage: String?

        for result in results {
            detectedLanguage = result.language

            for segment in result.segments {
                var words = [RecognizedWord]()

                if let wordTimings = segment.words {
                    for wordTiming in wordTimings {
                        words.append(RecognizedWord(
                            text: wordTiming.word,
                            startTime: TimeInterval(wordTiming.start),
                            endTime: TimeInterval(wordTiming.end),
                            confidence: wordTiming.probability
                        ))
                    }
                }

                segments.append(RecognizedSegment(
                    text: segment.text.trimmingCharacters(in: .whitespaces),
                    startTime: TimeInterval(segment.start),
                    endTime: TimeInterval(segment.end),
                    words: words,
                    language: detectedLanguage
                ))
            }
        }

        return RecognizedLyric(
            segments: segments,
            language: detectedLanguage,
            processingTime: processingTime
        )
    }

    // MARK: - FFmpeg 音频解码

    /// 使用 FFmpeg 解码音频为 16kHz 单声道 Float32 PCM
    private func decodeAudioToPCM(url: String) throws -> [Float] {
        var fmtCtx: UnsafeMutablePointer<AVFormatContext>?

        // 打开输入
        guard avformat_open_input(&fmtCtx, url, nil, nil) >= 0, let ctx = fmtCtx else {
            throw LyricRecognizerError.cannotOpenInput
        }
        defer { avformat_close_input(&fmtCtx) }

        guard avformat_find_stream_info(ctx, nil) >= 0 else {
            throw LyricRecognizerError.cannotFindStreamInfo
        }

        // 找到音频流
        var audioStreamIndex: Int32 = -1
        for i in 0..<Int32(ctx.pointee.nb_streams) {
            if ctx.pointee.streams[Int(i)]!.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO {
                audioStreamIndex = i
                break
            }
        }
        guard audioStreamIndex >= 0 else {
            throw LyricRecognizerError.noAudioStream
        }

        let codecpar = ctx.pointee.streams[Int(audioStreamIndex)]!.pointee.codecpar!

        // 打开解码器
        guard let codec = avcodec_find_decoder(codecpar.pointee.codec_id) else {
            throw LyricRecognizerError.codecNotFound
        }
        guard let codecCtx = avcodec_alloc_context3(codec) else {
            throw LyricRecognizerError.codecNotFound
        }
        var codecCtxPtr: UnsafeMutablePointer<AVCodecContext>? = codecCtx
        defer { avcodec_free_context(&codecCtxPtr) }

        guard avcodec_parameters_to_context(codecCtx, codecpar) >= 0 else {
            throw LyricRecognizerError.codecNotFound
        }
        guard avcodec_open2(codecCtx, codec, nil) >= 0 else {
            throw LyricRecognizerError.codecNotFound
        }

        // 设置重采样器：任意格式 → 16kHz 单声道 Float32
        guard let swrCtx = swr_alloc() else {
            throw LyricRecognizerError.resampleFailed
        }
        var swrCtxPtr: OpaquePointer? = swrCtx
        defer { swr_free(&swrCtxPtr) }

        // 输出格式：16kHz 单声道
        var outLayout = AVChannelLayout()
        av_channel_layout_default(&outLayout, 1)

        var inLayout = codecCtx.pointee.ch_layout
        let swrRaw = UnsafeMutableRawPointer(swrCtx)
        av_opt_set_chlayout(swrRaw, "in_chlayout", &inLayout, 0)
        av_opt_set_int(swrRaw, "in_sample_rate", Int64(codecCtx.pointee.sample_rate), 0)
        av_opt_set_sample_fmt(swrRaw, "in_sample_fmt", codecCtx.pointee.sample_fmt, 0)

        av_opt_set_chlayout(swrRaw, "out_chlayout", &outLayout, 0)
        av_opt_set_int(swrRaw, "out_sample_rate", Int64(targetSampleRate), 0)
        av_opt_set_sample_fmt(swrRaw, "out_sample_fmt", AV_SAMPLE_FMT_FLT, 0)

        guard swr_init(swrCtx) >= 0 else {
            throw LyricRecognizerError.resampleFailed
        }

        // 解码循环
        var allSamples = [Float]()
        var packet: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        defer { av_packet_free(&packet) }
        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&frame) }

        while av_read_frame(ctx, packet) >= 0 {
            defer { av_packet_unref(packet) }
            guard packet!.pointee.stream_index == audioStreamIndex else { continue }
            guard avcodec_send_packet(codecCtx, packet) >= 0 else { continue }

            while avcodec_receive_frame(codecCtx, frame) >= 0 {
                if let converted = resampleFrame(swrCtx: swrCtx, frame: frame!) {
                    allSamples.append(contentsOf: converted)
                }
                av_frame_unref(frame)
            }
        }

        // Flush 解码器
        let _ = avcodec_send_packet(codecCtx, nil)
        while avcodec_receive_frame(codecCtx, frame) >= 0 {
            if let converted = resampleFrame(swrCtx: swrCtx, frame: frame!) {
                allSamples.append(contentsOf: converted)
            }
            av_frame_unref(frame)
        }

        guard !allSamples.isEmpty else {
            throw LyricRecognizerError.noAudioData
        }

        return allSamples
    }

    /// 重采样单个 AVFrame
    private func resampleFrame(swrCtx: OpaquePointer, frame: UnsafeMutablePointer<AVFrame>) -> [Float]? {
        let outSamples = swr_get_out_samples(swrCtx, frame.pointee.nb_samples)
        guard outSamples > 0 else { return nil }

        let outBuf = UnsafeMutablePointer<Float>.allocate(capacity: Int(outSamples))
        defer { outBuf.deallocate() }

        var outPtr: UnsafeMutablePointer<UInt8>? = UnsafeMutableRawPointer(outBuf).assumingMemoryBound(to: UInt8.self)

        let converted = withUnsafePointer(to: frame.pointee.data) { dataPtr in
            dataPtr.withMemoryRebound(to: UnsafePointer<UInt8>?.self, capacity: 1) { srcPtr in
                swr_convert(swrCtx, &outPtr, outSamples, srcPtr, frame.pointee.nb_samples)
            }
        }

        guard converted > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: outBuf, count: Int(converted)))
    }

    /// 将 AudioBuffer 重采样为 16kHz 单声道
    private func resampleBuffer(_ buffer: AudioBuffer) -> [Float] {
        let data = UnsafeBufferPointer(start: buffer.data, count: buffer.frameCount * buffer.channelCount)

        if buffer.sampleRate == targetSampleRate && buffer.channelCount == 1 {
            return Array(data)
        }

        // 混合为单声道
        var mono: [Float]
        if buffer.channelCount > 1 {
            mono = [Float](repeating: 0, count: buffer.frameCount)
            let invChannels = 1.0 / Float(buffer.channelCount)
            for i in 0..<buffer.frameCount {
                var sum: Float = 0
                for ch in 0..<buffer.channelCount {
                    sum += data[i * buffer.channelCount + ch]
                }
                mono[i] = sum * invChannels
            }
        } else {
            mono = Array(data)
        }

        // 线性重采样
        if buffer.sampleRate != targetSampleRate {
            let ratio = Float(targetSampleRate) / Float(buffer.sampleRate)
            let outCount = Int(Float(mono.count) * ratio)
            var resampled = [Float](repeating: 0, count: outCount)
            for i in 0..<outCount {
                let srcIdx = Float(i) / ratio
                let idx0 = Int(srcIdx)
                let frac = srcIdx - Float(idx0)
                let idx1 = min(idx0 + 1, mono.count - 1)
                if idx0 < mono.count {
                    resampled[i] = mono[idx0] * (1.0 - frac) + mono[idx1] * frac
                }
            }
            return resampled
        }

        return mono
    }
}

// MARK: - 错误类型

/// 歌词识别错误。
public enum LyricRecognizerError: Error, CustomStringConvertible {
    case backendNotReady
    case cannotOpenInput
    case cannotFindStreamInfo
    case noAudioStream
    case codecNotFound
    case resampleFailed
    case noAudioData
    case recognitionFailed(String)

    public var description: String {
        switch self {
        case .backendNotReady: return "识别引擎未就绪（模型未加载）"
        case .cannotOpenInput: return "无法打开音频输入"
        case .cannotFindStreamInfo: return "无法获取流信息"
        case .noAudioStream: return "未找到音频流"
        case .codecNotFound: return "找不到解码器"
        case .resampleFailed: return "重采样失败"
        case .noAudioData: return "没有解码到音频数据"
        case .recognitionFailed(let msg): return "识别失败: \(msg)"
        }
    }
}
