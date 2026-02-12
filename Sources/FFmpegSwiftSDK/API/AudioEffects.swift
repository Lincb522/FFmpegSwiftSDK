// AudioEffects.swift
// FFmpegSwiftSDK
//
// 公开 API：音频效果控制器，提供响度标准化、变速不变调、音量控制。
// 通过 StreamPlayer.audioEffects 访问。

import Foundation

/// 音频效果控制器，封装 FFmpeg avfilter 提供的实时音频处理能力。
///
/// 支持三种效果：
/// - 音量控制（volume）：增益/衰减，单位 dB
/// - 变速不变调（atempo）：0.5x ~ 4.0x 播放速度
/// - 响度标准化（loudnorm）：EBU R128 标准，解决不同歌曲音量差异
///
/// 通过 `StreamPlayer.audioEffects` 访问：
/// ```swift
/// let player = StreamPlayer()
/// player.audioEffects.setVolume(3.0)           // +3dB
/// player.audioEffects.setTempo(1.5)            // 1.5x 倍速
/// player.audioEffects.setLoudnormEnabled(true)  // 开启响度标准化
/// ```
public final class AudioEffects {

    /// 内部滤镜图引擎
    internal let filterGraph: AudioFilterGraph

    internal init(filterGraph: AudioFilterGraph) {
        self.filterGraph = filterGraph
    }

    // MARK: - 音量控制

    /// 设置音量增益。
    ///
    /// - Parameter db: 增益值（dB）。0 = 不变，正值增大，负值减小。
    ///   建议范围 [-20, +20]。
    public func setVolume(_ db: Float) {
        filterGraph.setVolume(db)
    }

    /// 当前音量增益（dB）。
    public var volume: Float {
        filterGraph.volumeDB
    }

    // MARK: - 变速不变调

    /// 设置播放速度倍率。
    ///
    /// 使用 FFmpeg atempo 滤镜实现变速不变调。
    /// 超过 2.0x 时自动级联多个 atempo 滤镜。
    ///
    /// - Parameter rate: 速度倍率，范围 [0.5, 4.0]。1.0 = 原速。
    ///   典型值：0.75（慢速）、1.0（原速）、1.25、1.5、2.0（倍速）
    public func setTempo(_ rate: Float) {
        filterGraph.setTempo(rate)
    }

    /// 当前播放速度倍率。
    public var tempo: Float {
        filterGraph.tempo
    }

    // MARK: - 响度标准化

    /// 启用/禁用响度标准化（EBU R128 / loudnorm）。
    ///
    /// 开启后，不同歌曲的音量会被标准化到统一响度，
    /// 解决切歌时音量忽大忽小的问题。
    ///
    /// - Parameter enabled: 是否启用。
    public func setLoudnormEnabled(_ enabled: Bool) {
        filterGraph.setLoudnormEnabled(enabled)
    }

    /// 响度标准化是否启用。
    public var isLoudnormEnabled: Bool {
        filterGraph.loudnormEnabled
    }

    /// 设置 loudnorm 参数。
    ///
    /// - Parameters:
    ///   - targetLUFS: 目标响度（LUFS），默认 -14.0（Spotify 标准）。
    ///   - lra: 响度范围（LRA），默认 11.0。
    ///   - truePeak: 真峰值限制（dBTP），默认 -1.0。
    public func setLoudnormParams(targetLUFS: Float = -14.0, lra: Float = 11.0, truePeak: Float = -1.0) {
        filterGraph.setLoudnormParams(targetLUFS: targetLUFS, lra: lra, truePeak: truePeak)
    }

    // MARK: - 重置

    /// 重置所有音频效果到默认值（音量 0dB、原速、关闭响度标准化）。
    public func reset() {
        filterGraph.reset()
    }

    /// 是否有任何效果处于激活状态。
    public var isActive: Bool {
        filterGraph.isActive
    }
}
