// LyricAligner.swift
// FFmpegSwiftSDK
//
// 歌词对齐引擎。将语音识别的逐字时间戳对齐到已有的歌词文本。
// 用于将网易云等平台的行级歌词升级为逐字歌词。

import Foundation

// MARK: - 对齐配置

/// 歌词对齐配置
public struct LyricAlignerConfig {
    /// 文本相似度阈值（0~1），低于此值认为不匹配
    public var similarityThreshold: Float = 0.6
    
    /// 最大时间偏移（秒），超过此值认为时间不匹配
    public var maxTimeOffset: TimeInterval = 5.0
    
    /// 是否启用模糊匹配（容忍标点、空格差异）
    public var fuzzyMatch: Bool = true
    
    public init() {}
}

// MARK: - 对齐结果

/// 对齐后的歌词行
public struct AlignedLyricLine {
    /// 原始歌词文本
    public let text: String
    /// 行开始时间
    public let startTime: TimeInterval
    /// 行结束时间
    public let endTime: TimeInterval
    /// 逐字数据（对齐后）
    public let words: [LyricWord]
    /// 对齐置信度（0~1）
    public let confidence: Float
    
    public init(text: String, startTime: TimeInterval, endTime: TimeInterval, words: [LyricWord], confidence: Float) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.words = words
        self.confidence = confidence
    }
}

/// 对齐结果
public struct AlignmentResult {
    /// 对齐后的歌词行
    public let lines: [AlignedLyricLine]
    /// 平均置信度
    public let averageConfidence: Float
    /// 成功对齐的行数
    public let alignedCount: Int
    /// 总行数
    public let totalCount: Int
    
    public init(lines: [AlignedLyricLine]) {
        self.lines = lines
        self.totalCount = lines.count
        self.alignedCount = lines.filter { $0.confidence > 0.5 }.count
        self.averageConfidence = lines.isEmpty ? 0 : lines.map { $0.confidence }.reduce(0, +) / Float(lines.count)
    }
    
    /// 导出为增强 LRC 格式
    public func toEnhancedLRC() -> String {
        var lrc = "[re:AsideMusic LyricAligner]\n"
        lrc += "[ve:1.0]\n\n"
        
        for line in lines {
            let lineTime = formatLRCTime(line.startTime)
            if line.words.isEmpty {
                lrc += "[\(lineTime)]\(line.text)\n"
            } else {
                var lrcLine = "[\(lineTime)]"
                for word in line.words {
                    let wordTime = formatLRCTime(word.startTime)
                    lrcLine += "<\(wordTime)>\(word.text)"
                }
                lrc += lrcLine + "\n"
            }
        }
        return lrc
    }
    
    private func formatLRCTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = time - Double(minutes * 60)
        return String(format: "%02d:%05.2f", minutes, seconds)
    }
}

// MARK: - 歌词对齐引擎

/// 歌词对齐引擎。
///
/// 将语音识别的逐字时间戳对齐到已有的歌词文本（如网易云歌词）。
///
/// **工作原理：**
/// 1. 使用动态时间规整（DTW）算法匹配识别文本和歌词文本
/// 2. 将识别的逐字时间戳映射到歌词文本的每个字
/// 3. 处理标点、空格、繁简体等差异
///
/// **使用场景：**
/// ```swift
/// // 1. 识别音频获得逐字时间戳
/// let recognizer = LyricRecognizer()
/// let recognized = try await recognizer.recognize(url: audioURL)
///
/// // 2. 从网易云获取歌词文本
/// let ncmLyrics = try await fetchNCMLyrics(songId: songId)
///
/// // 3. 对齐
/// let aligner = LyricAligner()
/// let result = aligner.align(
///     recognized: recognized,
///     targetLyrics: ncmLyrics
/// )
///
/// // 4. 使用对齐后的逐字歌词
/// let enhancedLRC = result.toEnhancedLRC()
/// ```
public final class LyricAligner {
    
    private let config: LyricAlignerConfig
    
    public init(config: LyricAlignerConfig = LyricAlignerConfig()) {
        self.config = config
    }
    
    // MARK: - 主要对齐方法
    
    /// 将识别结果对齐到目标歌词。
    ///
    /// - Parameters:
    ///   - recognized: 语音识别结果（带逐字时间戳）
    ///   - targetLyrics: 目标歌词行（通常来自网易云，只有行级时间戳）
    /// - Returns: 对齐结果
    public func align(
        recognized: RecognizedLyric,
        targetLyrics: [LyricLine]
    ) -> AlignmentResult {
        var alignedLines = [AlignedLyricLine]()
        
        // 提取识别的所有词
        let recognizedWords = recognized.allWords
        
        for targetLine in targetLyrics {
            let aligned = alignLine(
                targetLine: targetLine,
                recognizedWords: recognizedWords
            )
            alignedLines.append(aligned)
        }
        
        return AlignmentResult(lines: alignedLines)
    }
    
    /// 将识别结果对齐到 LRC 格式歌词。
    ///
    /// - Parameters:
    ///   - recognized: 语音识别结果
    ///   - lrcContent: LRC 格式歌词字符串
    /// - Returns: 对齐结果
    public func align(
        recognized: RecognizedLyric,
        lrcContent: String
    ) -> AlignmentResult {
        let parser = LyricParser()
        let (_, lines) = parser.parse(lrcContent)
        return align(recognized: recognized, targetLyrics: lines)
    }
    
    // MARK: - 单行对齐
    
    /// 对齐单行歌词
    private func alignLine(
        targetLine: LyricLine,
        recognizedWords: [RecognizedWord]
    ) -> AlignedLyricLine {
        // 清理目标文本（去除标点、空格）
        let cleanTarget = cleanText(targetLine.text)
        
        // 在识别结果中查找时间窗口内的词
        let timeWindow = findTimeWindow(
            around: targetLine.time,
            in: recognizedWords
        )
        
        // 如果时间窗口内没有词，返回未对齐的行
        guard !timeWindow.isEmpty else {
            return AlignedLyricLine(
                text: targetLine.text,
                startTime: targetLine.time,
                endTime: targetLine.time + 3.0,
                words: [],
                confidence: 0
            )
        }
        
        // 拼接时间窗口内的文本
        let windowText = timeWindow.map { cleanText($0.text) }.joined()
        
        // 使用编辑距离算法找到最佳匹配
        let (matchedWords, confidence) = findBestMatch(
            target: cleanTarget,
            windowText: windowText,
            windowWords: timeWindow
        )
        
        // 将匹配的词映射回原始文本的字符
        let alignedWords = mapWordsToOriginalText(
            originalText: targetLine.text,
            matchedWords: matchedWords
        )
        
        // 计算行的结束时间
        let endTime = alignedWords.last?.endTime ?? (targetLine.time + 3.0)
        
        return AlignedLyricLine(
            text: targetLine.text,
            startTime: targetLine.time,
            endTime: endTime,
            words: alignedWords,
            confidence: confidence
        )
    }
    
    // MARK: - 辅助方法
    
    /// 查找时间窗口内的词
    private func findTimeWindow(
        around time: TimeInterval,
        in words: [RecognizedWord]
    ) -> [RecognizedWord] {
        let windowStart = time - config.maxTimeOffset
        let windowEnd = time + config.maxTimeOffset * 2  // 向后多看一些
        
        return words.filter { word in
            word.startTime >= windowStart && word.startTime <= windowEnd
        }
    }
    
    /// 清理文本（去除标点、空格、转小写）
    private func cleanText(_ text: String) -> String {
        if !config.fuzzyMatch {
            return text
        }
        
        // 去除标点符号
        let punctuation = CharacterSet.punctuationCharacters
            .union(.whitespaces)
            .union(.symbols)
        
        return text.components(separatedBy: punctuation)
            .joined()
            .lowercased()
    }
    
    /// 使用编辑距离找到最佳匹配
    private func findBestMatch(
        target: String,
        windowText: String,
        windowWords: [RecognizedWord]
    ) -> (words: [RecognizedWord], confidence: Float) {
        // 如果目标文本为空，返回空结果
        guard !target.isEmpty else {
            return ([], 0)
        }
        
        // 计算相似度
        let similarity = calculateSimilarity(target, windowText)
        
        // 如果相似度太低，返回低置信度结果
        guard similarity >= config.similarityThreshold else {
            return ([], similarity)
        }
        
        // 使用动态规划找到最佳匹配的词序列
        let matchedWords = findMatchingSequence(
            target: target,
            windowWords: windowWords
        )
        
        return (matchedWords, similarity)
    }
    
    /// 计算两个字符串的相似度（Levenshtein 距离）
    private func calculateSimilarity(_ s1: String, _ s2: String) -> Float {
        let len1 = s1.count
        let len2 = s2.count
        
        guard len1 > 0 && len2 > 0 else { return 0 }
        
        let distance = levenshteinDistance(s1, s2)
        let maxLen = max(len1, len2)
        
        return 1.0 - Float(distance) / Float(maxLen)
    }
    
    /// Levenshtein 编辑距离
    private func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        let a1 = Array(s1)
        let a2 = Array(s2)
        let len1 = a1.count
        let len2 = a2.count
        
        var dp = Array(repeating: Array(repeating: 0, count: len2 + 1), count: len1 + 1)
        
        for i in 0...len1 { dp[i][0] = i }
        for j in 0...len2 { dp[0][j] = j }
        
        for i in 1...len1 {
            for j in 1...len2 {
                let cost = a1[i - 1] == a2[j - 1] ? 0 : 1
                dp[i][j] = min(
                    dp[i - 1][j] + 1,      // 删除
                    dp[i][j - 1] + 1,      // 插入
                    dp[i - 1][j - 1] + cost // 替换
                )
            }
        }
        
        return dp[len1][len2]
    }
    
    /// 找到匹配的词序列
    private func findMatchingSequence(
        target: String,
        windowWords: [RecognizedWord]
    ) -> [RecognizedWord] {
        // 简化版：按顺序匹配
        // TODO: 可以使用更复杂的序列对齐算法（如 Smith-Waterman）
        
        var result = [RecognizedWord]()
        var targetIndex = target.startIndex
        
        for word in windowWords {
            let cleanWord = cleanText(word.text)
            
            // 尝试在目标文本中找到这个词
            if let range = target[targetIndex...].range(of: cleanWord) {
                result.append(word)
                targetIndex = range.upperBound
                
                // 如果已经匹配完整个目标文本，停止
                if targetIndex >= target.endIndex {
                    break
                }
            }
        }
        
        return result
    }
    
    /// 将匹配的词映射回原始文本的字符
    private func mapWordsToOriginalText(
        originalText: String,
        matchedWords: [RecognizedWord]
    ) -> [LyricWord] {
        guard !matchedWords.isEmpty else { return [] }
        
        var result = [LyricWord]()
        var textIndex = originalText.startIndex
        var wordIndex = 0
        
        // 遍历原始文本的每个字符
        while textIndex < originalText.endIndex && wordIndex < matchedWords.count {
            let char = originalText[textIndex]
            
            // 跳过标点和空格
            if char.isPunctuation || char.isWhitespace {
                textIndex = originalText.index(after: textIndex)
                continue
            }
            
            // 获取当前识别词
            let recognizedWord = matchedWords[wordIndex]
            let cleanRecognized = cleanText(recognizedWord.text)
            
            // 计算这个词在原始文本中占多少个字符
            var charCount = 0
            var tempIndex = textIndex
            
            while tempIndex < originalText.endIndex && charCount < cleanRecognized.count {
                let c = originalText[tempIndex]
                if !c.isPunctuation && !c.isWhitespace {
                    charCount += 1
                }
                tempIndex = originalText.index(after: tempIndex)
            }
            
            // 提取原始文本中的这段
            let wordText = String(originalText[textIndex..<tempIndex])
            
            // 计算时间分配
            let wordDuration = recognizedWord.endTime - recognizedWord.startTime
            let charDuration = wordDuration / Double(max(charCount, 1))
            
            // 为每个字符创建 LyricWord
            var charIndex = 0
            var currentIndex = textIndex
            
            while currentIndex < tempIndex {
                let c = originalText[currentIndex]
                
                if !c.isPunctuation && !c.isWhitespace {
                    let startTime = recognizedWord.startTime + charDuration * Double(charIndex)
                    let endTime = startTime + charDuration
                    
                    result.append(LyricWord(
                        startTime: startTime,
                        endTime: endTime,
                        text: String(c)
                    ))
                    
                    charIndex += 1
                }
                
                currentIndex = originalText.index(after: currentIndex)
            }
            
            textIndex = tempIndex
            wordIndex += 1
        }
        
        return result
    }
}
