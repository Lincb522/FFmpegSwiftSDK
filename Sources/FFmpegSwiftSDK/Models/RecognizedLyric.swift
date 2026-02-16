// RecognizedLyric.swift
// FFmpegSwiftSDK
//
// 语音识别生成的逐字歌词数据模型。

import Foundation

/// 识别出的单个词/字，包含精确时间戳。
public struct RecognizedWord: Sendable {
    /// 文字内容
    public let text: String
    /// 开始时间（秒）
    public let startTime: TimeInterval
    /// 结束时间（秒）
    public let endTime: TimeInterval
    /// 识别置信度（0~1）
    public let confidence: Float

    public init(text: String, startTime: TimeInterval, endTime: TimeInterval, confidence: Float = 1.0) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
    }
}

/// 识别出的一个片段（通常对应一句话或一行歌词）。
public struct RecognizedSegment: Sendable {
    /// 片段文本
    public let text: String
    /// 开始时间（秒）
    public let startTime: TimeInterval
    /// 结束时间（秒）
    public let endTime: TimeInterval
    /// 逐字数据
    public let words: [RecognizedWord]
    /// 语言代码（如 "zh", "en"）
    public let language: String?

    public init(text: String, startTime: TimeInterval, endTime: TimeInterval, words: [RecognizedWord], language: String? = nil) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.words = words
        self.language = language
    }
}

/// 完整的识别结果。
public struct RecognizedLyric: Sendable {
    /// 所有片段
    public let segments: [RecognizedSegment]
    /// 检测到的语言
    public let language: String?
    /// 识别耗时（秒）
    public let processingTime: TimeInterval

    public init(segments: [RecognizedSegment], language: String? = nil, processingTime: TimeInterval = 0) {
        self.segments = segments
        self.language = language
        self.processingTime = processingTime
    }

    /// 所有逐字数据（扁平化）
    public var allWords: [RecognizedWord] {
        segments.flatMap { $0.words }
    }

    /// 转换为 LyricLine 数组，可直接用于 LyricSyncer
    public func toLyricLines() -> [LyricLine] {
        segments.map { segment in
            let words = segment.words.map { word in
                LyricWord(
                    startTime: word.startTime,
                    endTime: word.endTime,
                    text: word.text
                )
            }
            return LyricLine(
                time: segment.startTime,
                text: segment.text,
                words: words
            )
        }
    }

    /// 导出为增强 LRC 格式（带逐字时间戳）
    public func toEnhancedLRC() -> String {
        var lrc = "[re:FFmpegSwiftSDK LyricRecognizer]\n"
        if let lang = language {
            lrc += "[la:\(lang)]\n"
        }
        lrc += "\n"

        for segment in segments {
            let lineTime = formatLRCTime(segment.startTime)
            if segment.words.isEmpty {
                lrc += "[\(lineTime)]\(segment.text)\n"
            } else {
                var line = "[\(lineTime)]"
                for word in segment.words {
                    let wordTime = formatLRCTime(word.startTime)
                    line += "<\(wordTime)>\(word.text)"
                }
                lrc += line + "\n"
            }
        }
        return lrc
    }

    /// 格式化时间为 LRC 格式 mm:ss.xx
    private func formatLRCTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = time - Double(minutes * 60)
        return String(format: "%02d:%05.2f", minutes, seconds)
    }
}
