// PlayerViewModel.swift
// FFmpegDemo

import Foundation
import FFmpegSwiftSDK
import Combine

@MainActor
final class PlayerViewModel: ObservableObject {

    // MARK: - Published State

    @Published var urlText: String = ""
    @Published var state: String = "空闲"
    @Published var errorMessage: String?
    @Published var duration: TimeInterval = 0
    @Published var currentTime: TimeInterval = 0
    @Published var streamInfoText: String = ""
    @Published var hifiInfoText: String = ""

    // 10-band EQ gains
    @Published var eqGains: [EQBand: Float] = {
        var g = [EQBand: Float]()
        for band in EQBand.allCases { g[band] = 0.0 }
        return g
    }()
    @Published var clampMessage: String?

    // MARK: - Private

    private let player = StreamPlayer()
    private let delegateAdapter = PlayerDelegateAdapter()
    private var timer: Timer?

    init() {
        delegateAdapter.viewModel = self
        player.delegate = delegateAdapter
        player.equalizer.delegate = delegateAdapter
    }

    // MARK: - Playback

    func play() {
        errorMessage = nil
        clampMessage = nil
        player.play(url: urlText)
        startTimeUpdater()
    }

    func pause() { player.pause() }
    func resume() { player.resume() }

    func stop() {
        player.stop()
        stopTimeUpdater()
        currentTime = 0
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

    // MARK: - State

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
            streamInfoText = ""
            hifiInfoText = ""
            return
        }

        var parts: [String] = []
        if let codec = info.audioCodec { parts.append(codec.uppercased()) }
        if let sr = info.sampleRate {
            if sr >= 1000 {
                parts.append("\(sr / 1000).\(sr % 1000 / 100)kHz")
            } else {
                parts.append("\(sr)Hz")
            }
        }
        if let bits = info.bitDepth { parts.append("\(bits)bit") }
        if let ch = info.channelCount {
            parts.append(ch == 1 ? "Mono" : ch == 2 ? "Stereo" : "\(ch)ch")
        }
        streamInfoText = parts.joined(separator: " / ")

        // HiFi quality indicator
        let isLossless = ["flac", "alac", "ape", "wav", "pcm_s16le", "pcm_s24le", "pcm_s32le",
                          "pcm_f32le", "wavpack", "tak", "tta", "dsd_lsbf", "dsd_msbf"]
            .contains(info.audioCodec ?? "")
        let isHiRes = (info.sampleRate ?? 0) > 48000 || (info.bitDepth ?? 0) > 16
        if isHiRes {
            hifiInfoText = "🎵 Hi-Res 无损"
        } else if isLossless {
            hifiInfoText = "🎵 无损音质"
        } else {
            hifiInfoText = ""
        }
    }

    // MARK: - Timer

    private func startTimeUpdater() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
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
        Task { @MainActor [weak self] in
            self?.viewModel?.updateState(state)
        }
    }

    func player(_ player: StreamPlayer, didEncounterError error: FFmpegError) {
        Task { @MainActor [weak self] in
            self?.viewModel?.errorMessage = error.description
        }
    }

    func player(_ player: StreamPlayer, didUpdateDuration duration: TimeInterval) {
        Task { @MainActor [weak self] in
            self?.viewModel?.duration = duration
        }
    }

    func equalizer(_ eq: AudioEqualizer, didClampGain original: Float, to clamped: Float, for band: EQBand) {
        Task { @MainActor [weak self] in
            self?.viewModel?.clampMessage = "\(band.label)Hz 增益已限制: \(String(format: "%.1f", original)) → \(String(format: "%.1f", clamped)) dB"
        }
    }
}
