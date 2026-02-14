// PlayerViewModel.swift
// FFmpegDemo

import Foundation
import FFmpegSwiftSDK
import AVFoundation
import Combine

@MainActor
final class PlayerViewModel: ObservableObject {

    // MARK: - 播放状态

    @Published var urlText: String = ""
    @Published var state: String = "空闲"
    @Published var errorMessage: String?
    @Published var duration: TimeInterval = 0
    @Published var currentTime: TimeInterval = 0
    @Published var streamInfoText: String = ""
    @Published var hifiInfoText: String = ""
    @Published var videoInfoText: String = ""
    @Published var hasVideo: Bool = false

    // MARK: - 10 段 EQ

    @Published var eqGains: [EQBand: Float] = {
        var g = [EQBand: Float]()
        for band in EQBand.allCases { g[band] = 0.0 }
        return g
    }()
    @Published var clampMessage: String?

    // MARK: - 音频效果

    @Published var volume: Float = 0          // dB
    @Published var tempo: Float = 1.0         // 倍速
    @Published var pitch: Float = 0           // 半音
    @Published var bassGain: Float = 0        // dB
    @Published var trebleGain: Float = 0      // dB
    @Published var surroundLevel: Float = 0   // 0~1
    @Published var reverbLevel: Float = 0     // 0~1
    @Published var stereoWidth: Float = 1.0   // 0~2
    @Published var channelBalance: Float = 0  // -1~1
    @Published var vocalRemoval: Float = 0    // 0~1
    @Published var fadeInDuration: Float = 0  // 秒
    @Published var delayMs: Float = 0         // 毫秒
    
    // 开关效果
    @Published var loudnormEnabled: Bool = false
    @Published var nightModeEnabled: Bool = false
    @Published var limiterEnabled: Bool = false
    @Published var gateEnabled: Bool = false
    @Published var autoGainEnabled: Bool = false
    @Published var subboostEnabled: Bool = false
    @Published var monoEnabled: Bool = false
    @Published var channelSwapEnabled: Bool = false
    @Published var chorusEnabled: Bool = false
    @Published var flangerEnabled: Bool = false
    @Published var tremoloEnabled: Bool = false
    @Published var vibratoEnabled: Bool = false
    @Published var lofiEnabled: Bool = false
    @Published var telephoneEnabled: Bool = false
    @Published var underwaterEnabled: Bool = false
    @Published var radioEnabled: Bool = false

    // MARK: - 频谱

    @Published var spectrumData: [Float] = Array(repeating: 0, count: 32)
    @Published var spectrumEnabled: Bool = false {
        didSet { player.spectrumAnalyzer.isEnabled = spectrumEnabled }
    }

    // MARK: - 波形

    @Published var waveformSamples: [WaveformSample] = []
    @Published var waveformLoading: Bool = false

    // MARK: - 元数据

    @Published var metaTitle: String?
    @Published var metaArtist: String?
    @Published var metaAlbum: String?
    @Published var artworkData: Data?

    // MARK: - A-B 循环

    @Published var abLoopEnabled: Bool = false
    @Published var abPointA: TimeInterval = 0
    @Published var abPointB: TimeInterval = 0

    // MARK: - 歌词

    @Published var currentLyricLine: String = ""
    @Published var currentLyricTranslation: String?
    @Published var lyricProgress: Float = 0
    @Published var nearbyLyrics: [(index: Int, text: String, isCurrent: Bool)] = []
    @Published var lyricOffset: Double = 0 {
        didSet { player.lyricSyncer.offset = lyricOffset }
    }
    @Published var hasLyrics: Bool = false

    // MARK: - 音频分析

    @Published var isAnalyzing: Bool = false
    @Published var analysisResult: AnalysisResult?

    struct AnalysisResult {
        let bpm: Float
        let peakDB: Float
        let loudnessLUFS: Float
        let dynamicRange: Float
        let spectralCentroid: Float
        let hasClipping: Bool
        let phaseDescription: String
    }

    // MARK: - 歌曲识别

    @Published var isRecognizing: Bool = false
    @Published var recognitionResult: RecognitionResult?
    @Published var recognitionMessage: String?
    @Published var fingerprintDBCount: Int = 0

    struct RecognitionResult {
        let title: String
        let artist: String
        let score: Float
    }

    private let fingerprintDB = FingerprintDatabase()

    // MARK: - 内部

    let player = StreamPlayer()
    private let delegateAdapter = PlayerDelegateAdapter()
    private var timer: Timer?

    var videoLayer: AVSampleBufferDisplayLayer {
        player.videoDisplayLayer
    }

    init() {
        delegateAdapter.viewModel = self
        player.delegate = delegateAdapter
        player.equalizer.delegate = delegateAdapter

        // 频谱回调
        player.spectrumAnalyzer.onSpectrum = { [weak self] magnitudes in
            // 降采样到 32 段
            let target = 32
            let step = max(magnitudes.count / target, 1)
            var reduced = [Float]()
            for i in stride(from: 0, to: min(magnitudes.count, target * step), by: step) {
                let end = min(i + step, magnitudes.count)
                let avg = magnitudes[i..<end].reduce(0, +) / Float(end - i)
                reduced.append(avg)
            }
            while reduced.count < target { reduced.append(0) }
            Task { @MainActor [weak self] in
                self?.spectrumData = Array(reduced.prefix(target))
            }
        }

        // 歌词回调
        player.lyricSyncer.onSync = { [weak self] lineIndex, line, wordIndex, progress in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentLyricLine = line.text
                self.currentLyricTranslation = line.translation
                self.lyricProgress = progress
                // 附近歌词
                let nearby = self.player.lyricSyncer.nearbyLines(range: 3)
                self.nearbyLyrics = nearby.map { item in
                    (index: item.index, text: item.line.text, isCurrent: item.index == lineIndex)
                }
            }
        }
    }

    // MARK: - 播放控制

    func play() {
        errorMessage = nil
        clampMessage = nil
        player.play(url: urlText)
        startTimeUpdater()
        loadMetadata()
        loadWaveform()
    }

    func pause() { player.pause() }
    func resume() { player.resume() }

    func stop() {
        player.stop()
        stopTimeUpdater()
        currentTime = 0
        hasVideo = false
        videoInfoText = ""
        spectrumData = Array(repeating: 0, count: 32)
        waveformSamples = []
        currentLyricLine = ""
        nearbyLyrics = []
    }

    func seek(to time: TimeInterval) {
        player.seek(to: time)
        currentTime = time
    }

    // MARK: - EQ

    func updateGain(_ value: Float, for band: EQBand) {
        player.equalizer.setGain(value, for: band)
        eqGains[band] = player.equalizer.gain(for: band)
    }

    func resetEQ() {
        player.equalizer.reset()
        for band in EQBand.allCases { eqGains[band] = 0.0 }
        clampMessage = nil
    }

    // MARK: - 音频效果

    func updateVolume(_ db: Float) {
        volume = db
        player.audioEffects.setVolume(db)
    }

    func updateTempo(_ rate: Float) {
        tempo = rate
        player.audioEffects.setTempo(rate)
    }

    func updatePitch(_ semitones: Float) {
        pitch = semitones
        player.audioEffects.setPitch(semitones)
    }

    func updateBass(_ db: Float) {
        bassGain = db
        player.audioEffects.setBassGain(db)
    }

    func updateTreble(_ db: Float) {
        trebleGain = db
        player.audioEffects.setTrebleGain(db)
    }

    func updateSurround(_ level: Float) {
        surroundLevel = level
        player.audioEffects.setSurroundLevel(level)
    }

    func updateReverb(_ level: Float) {
        reverbLevel = level
        player.audioEffects.setReverbLevel(level)
    }

    func updateStereoWidth(_ width: Float) {
        stereoWidth = width
        player.audioEffects.setStereoWidth(width)
    }

    func updateChannelBalance(_ balance: Float) {
        channelBalance = balance
        player.audioEffects.setChannelBalance(balance)
    }

    func updateVocalRemoval(_ level: Float) {
        vocalRemoval = level
        player.audioEffects.setVocalRemoval(level)
    }

    func updateFadeIn(_ duration: Float) {
        fadeInDuration = duration
        player.audioEffects.setFadeIn(duration: duration)
    }

    func updateDelay(_ ms: Float) {
        delayMs = ms
        player.audioEffects.setDelay(ms)
    }

    func toggleLoudnorm() {
        loudnormEnabled.toggle()
        player.audioEffects.setLoudnormEnabled(loudnormEnabled)
    }

    func toggleNightMode() {
        nightModeEnabled.toggle()
        player.audioEffects.setNightModeEnabled(nightModeEnabled)
    }

    func toggleLimiter() {
        limiterEnabled.toggle()
        player.audioEffects.setLimiterEnabled(limiterEnabled)
    }

    func toggleGate() {
        gateEnabled.toggle()
        player.audioEffects.setGateEnabled(gateEnabled)
    }

    func toggleAutoGain() {
        autoGainEnabled.toggle()
        player.audioEffects.setAutoGainEnabled(autoGainEnabled)
    }

    func toggleSubboost() {
        subboostEnabled.toggle()
        player.audioEffects.setSubboostEnabled(subboostEnabled)
    }

    func toggleMono() {
        monoEnabled.toggle()
        player.audioEffects.setMonoEnabled(monoEnabled)
    }

    func toggleChannelSwap() {
        channelSwapEnabled.toggle()
        player.audioEffects.setChannelSwapEnabled(channelSwapEnabled)
    }

    func toggleChorus() {
        chorusEnabled.toggle()
        player.audioEffects.setChorusEnabled(chorusEnabled)
    }

    func toggleFlanger() {
        flangerEnabled.toggle()
        player.audioEffects.setFlangerEnabled(flangerEnabled)
    }

    func toggleTremolo() {
        tremoloEnabled.toggle()
        player.audioEffects.setTremoloEnabled(tremoloEnabled)
    }

    func toggleVibrato() {
        vibratoEnabled.toggle()
        player.audioEffects.setVibratoEnabled(vibratoEnabled)
    }

    func toggleLoFi() {
        lofiEnabled.toggle()
        player.audioEffects.setLoFiEnabled(lofiEnabled)
    }

    func toggleTelephone() {
        telephoneEnabled.toggle()
        player.audioEffects.setTelephoneEnabled(telephoneEnabled)
    }

    func toggleUnderwater() {
        underwaterEnabled.toggle()
        player.audioEffects.setUnderwaterEnabled(underwaterEnabled)
    }

    func toggleRadio() {
        radioEnabled.toggle()
        player.audioEffects.setRadioEnabled(radioEnabled)
    }

    func resetEffects() {
        player.audioEffects.reset()
        volume = 0; tempo = 1.0; pitch = 0
        bassGain = 0; trebleGain = 0
        surroundLevel = 0; reverbLevel = 0
        stereoWidth = 1.0; channelBalance = 0
        vocalRemoval = 0
        fadeInDuration = 0; delayMs = 0
        loudnormEnabled = false; nightModeEnabled = false
        limiterEnabled = false; gateEnabled = false
        autoGainEnabled = false; subboostEnabled = false
        monoEnabled = false; channelSwapEnabled = false
        chorusEnabled = false; flangerEnabled = false
        tremoloEnabled = false; vibratoEnabled = false
        lofiEnabled = false; telephoneEnabled = false
        underwaterEnabled = false; radioEnabled = false
    }

    // MARK: - A-B 循环

    func setABLoop() {
        guard abPointB > abPointA else { return }
        player.setABLoop(pointA: abPointA, pointB: abPointB)
        abLoopEnabled = true
    }

    func clearABLoop() {
        player.clearABLoop()
        abLoopEnabled = false
    }

    func setPointA() {
        abPointA = currentTime
    }

    func setPointB() {
        abPointB = currentTime
        if abPointB > abPointA {
            setABLoop()
        }
    }

    // MARK: - 歌词

    /// 加载示例歌词（实际使用时从文件或网络获取 LRC）
    func loadLyrics(_ lrcContent: String) {
        player.lyricSyncer.load(lrcContent: lrcContent)
        hasLyrics = player.lyricSyncer.isLoaded
    }

    func clearLyrics() {
        player.lyricSyncer.clear()
        hasLyrics = false
        currentLyricLine = ""
        currentLyricTranslation = nil
        nearbyLyrics = []
    }

    func adjustLyricOffset(_ delta: Double) {
        lyricOffset += delta
    }

    // MARK: - 音频分析

    func runAnalysis() {
        guard !waveformSamples.isEmpty else {
            // 需要先有波形数据
            return
        }

        isAnalyzing = true
        analysisResult = nil

        Task.detached { [weak self] in
            guard let self else { return }

            // 从波形数据生成采样（简化版，实际应从原始音频获取）
            let samples = self.waveformSamples.flatMap { [$0.positive, $0.negative] }
            let sampleRate = 44100

            // BPM 检测
            let bpmResult = AudioAnalyzer.detectBPM(samples: samples, sampleRate: sampleRate)

            // 峰值检测
            let peakResult = AudioAnalyzer.detectPeak(samples: samples, sampleRate: sampleRate)

            // 响度测量
            let loudnessResult = AudioAnalyzer.measureLoudness(samples: samples, sampleRate: sampleRate, channelCount: 1)

            // 动态范围
            let dynamicResult = AudioAnalyzer.analyzeDynamicRange(samples: samples, sampleRate: sampleRate)

            // 频率分析
            let freqResult = AudioAnalyzer.analyzeFrequency(samples: samples, sampleRate: sampleRate)

            // 削波检测
            let clippingResult = AudioAnalyzer.detectClipping(samples: samples, sampleRate: sampleRate)

            // 相位检测（需要立体声数据，这里简化处理）
            let phaseDesc = "单声道数据"

            await MainActor.run {
                self.analysisResult = AnalysisResult(
                    bpm: bpmResult.bpm,
                    peakDB: peakResult.peakDB,
                    loudnessLUFS: loudnessResult.integratedLUFS,
                    dynamicRange: dynamicResult.dynamicRange,
                    spectralCentroid: freqResult.spectralCentroid,
                    hasClipping: clippingResult.hasSevereClipping,
                    phaseDescription: phaseDesc
                )
                self.isAnalyzing = false
            }
        }
    }

    // MARK: - 歌曲识别

    func addToFingerprintDB() {
        guard !waveformSamples.isEmpty else {
            recognitionMessage = "请先播放音频"
            return
        }

        let title = metaTitle ?? "未知歌曲"
        let artist = metaArtist ?? "未知艺术家"

        // 从波形生成简化采样
        let samples = waveformSamples.flatMap { [$0.positive, $0.negative] }
        let fingerprint = AudioFingerprint.generate(samples: samples, sampleRate: 44100)

        let entry = FingerprintDatabase.Entry(
            id: UUID().uuidString,
            title: title,
            artist: artist,
            fingerprint: fingerprint
        )

        fingerprintDB.add(entry: entry)
        fingerprintDBCount = fingerprintDB.count
        recognitionMessage = "已添加: \(title)"
    }

    func recognizeSong() {
        guard !waveformSamples.isEmpty else {
            recognitionMessage = "请先播放音频"
            return
        }

        guard fingerprintDBCount > 0 else {
            recognitionMessage = "数据库为空，请先添加歌曲"
            return
        }

        isRecognizing = true
        recognitionResult = nil
        recognitionMessage = nil

        Task.detached { [weak self] in
            guard let self else { return }

            let samples = self.waveformSamples.flatMap { [$0.positive, $0.negative] }

            if let result = self.fingerprintDB.recognize(samples: samples, sampleRate: 44100) {
                await MainActor.run {
                    self.recognitionResult = RecognitionResult(
                        title: result.title,
                        artist: result.artist,
                        score: result.score
                    )
                    self.isRecognizing = false
                }
            } else {
                await MainActor.run {
                    self.recognitionMessage = "未能识别，请尝试其他片段"
                    self.isRecognizing = false
                }
            }
        }
    }

    // MARK: - 元数据

    private func loadMetadata() {
        let url = urlText
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                let meta = try self.player.metadataReader.read(url: url)
                await MainActor.run {
                    self.metaTitle = meta.title
                    self.metaArtist = meta.artist
                    self.metaAlbum = meta.album
                    self.artworkData = meta.artworkData
                }
            } catch {
                // 元数据读取失败，静默处理（网络流可能不支持）
            }
        }
    }

    // MARK: - 波形

    private func loadWaveform() {
        let url = urlText
        waveformLoading = true
        waveformSamples = []
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                let samples = try await self.player.waveformGenerator.generate(
                    url: url, samplesCount: 150
                )
                await MainActor.run {
                    self.waveformSamples = samples
                    self.waveformLoading = false
                }
            } catch {
                await MainActor.run {
                    self.waveformLoading = false
                }
            }
        }
    }

    // MARK: - 状态更新

    func updateState(_ playbackState: PlaybackState) {
        switch playbackState {
        case .idle:       state = "空闲"
        case .connecting: state = "连接中..."
        case .playing:    state = "播放中"
        case .paused:     state = "已暂停"
        case .stopped:    state = "已停止"
        case .error(let err):
            state = "错误"
            errorMessage = err.description
        }
    }

    func updateStreamInfo(_ info: StreamInfo?) {
        guard let info = info else {
            streamInfoText = ""; hifiInfoText = ""; videoInfoText = ""; hasVideo = false
            return
        }
        var parts: [String] = []
        if let codec = info.audioCodec { parts.append(codec.uppercased()) }
        if let sr = info.sampleRate {
            parts.append(sr >= 1000 ? "\(sr / 1000).\(sr % 1000 / 100)kHz" : "\(sr)Hz")
        }
        if let bits = info.bitDepth { parts.append("\(bits)bit") }
        if let ch = info.channelCount {
            parts.append(ch == 1 ? "Mono" : ch == 2 ? "Stereo" : "\(ch)ch")
        }
        streamInfoText = parts.joined(separator: " / ")

        hasVideo = info.hasVideo
        if info.hasVideo {
            var vp: [String] = []
            if let vc = info.videoCodec { vp.append(vc.uppercased()) }
            if let w = info.width, let h = info.height { vp.append("\(w)×\(h)") }
            videoInfoText = vp.joined(separator: " / ")
        } else { videoInfoText = "" }

        hifiInfoText = info.isHiRes ? "Hi-Res 无损" : info.isLossless ? "无损音质" : ""
    }

    // MARK: - 定时器

    private func startTimeUpdater() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentTime = self.player.currentTime
                self.updateStreamInfo(self.player.streamInfo)
            }
        }
    }

    private func stopTimeUpdater() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - Delegate Adapter

private final class PlayerDelegateAdapter: StreamPlayerDelegate, AudioEqualizerDelegate {
    weak var viewModel: PlayerViewModel?

    func player(_ player: StreamPlayer, didChangeState state: PlaybackState) {
        Task { @MainActor [weak self] in self?.viewModel?.updateState(state) }
    }
    func player(_ player: StreamPlayer, didEncounterError error: FFmpegError) {
        Task { @MainActor [weak self] in self?.viewModel?.errorMessage = error.description }
    }
    func player(_ player: StreamPlayer, didUpdateDuration duration: TimeInterval) {
        Task { @MainActor [weak self] in self?.viewModel?.duration = duration }
    }
    func playerDidTransitionToNextTrack(_ player: StreamPlayer) {}
    func equalizer(_ eq: AudioEqualizer, didClampGain original: Float, to clamped: Float, for band: EQBand) {
        Task { @MainActor [weak self] in
            self?.viewModel?.clampMessage = "\(band.label)Hz: \(String(format: "%.1f", original)) → \(String(format: "%.1f", clamped)) dB"
        }
    }
}
