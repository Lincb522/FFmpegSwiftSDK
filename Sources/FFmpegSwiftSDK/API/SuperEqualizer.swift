// SuperEqualizer.swift
// FFmpegSwiftSDK
//
// 公开 API：18 段高精度均衡器，基于 FFmpeg superequalizer 滤镜。
// 使用 16383 阶 FIR 滤波器 + FFT，频段之间几乎无重叠和滚降，
// 精度远高于传统 biquad IIR 均衡器。
//
// 通过 StreamPlayer.superEQ 访问。

import Foundation

/// 18 段 SuperEqualizer 频段定义。
///
/// 中心频率从 65Hz 到 20kHz，覆盖完整可听频谱。
/// FFmpeg superequalizer 使用 16383 阶 FIR 滤波器，
/// 频段之间几乎无重叠，精度远高于传统参数 EQ。
public enum SuperEQBand: Int, CaseIterable, Comparable {
    case hz65   = 0   // 65 Hz
    case hz92   = 1   // 92 Hz
    case hz131  = 2   // 131 Hz
    case hz185  = 3   // 185 Hz
    case hz262  = 4   // 262 Hz
    case hz370  = 5   // 370 Hz
    case hz523  = 6   // 523 Hz
    case hz740  = 7   // 740 Hz
    case hz1047 = 8   // 1047 Hz
    case hz1480 = 9   // 1480 Hz
    case hz2093 = 10  // 2093 Hz
    case hz2960 = 11  // 2960 Hz
    case hz4186 = 12  // 4186 Hz
    case hz5920 = 13  // 5920 Hz
    case hz8372 = 14  // 8372 Hz
    case hz11840 = 15 // 11840 Hz
    case hz16744 = 16 // 16744 Hz
    case hz20000 = 17 // 20000 Hz

    /// 中心频率（Hz）
    public var centerFrequency: Float {
        switch self {
        case .hz65:    return 65
        case .hz92:    return 92
        case .hz131:   return 131
        case .hz185:   return 185
        case .hz262:   return 262
        case .hz370:   return 370
        case .hz523:   return 523
        case .hz740:   return 740
        case .hz1047:  return 1047
        case .hz1480:  return 1480
        case .hz2093:  return 2093
        case .hz2960:  return 2960
        case .hz4186:  return 4186
        case .hz5920:  return 5920
        case .hz8372:  return 8372
        case .hz11840: return 11840
        case .hz16744: return 16744
        case .hz20000: return 20000
        }
    }

    /// 显示标签
    public var label: String {
        switch self {
        case .hz65:    return "65"
        case .hz92:    return "92"
        case .hz131:   return "131"
        case .hz185:   return "185"
        case .hz262:   return "262"
        case .hz370:   return "370"
        case .hz523:   return "523"
        case .hz740:   return "740"
        case .hz1047:  return "1k"
        case .hz1480:  return "1.5k"
        case .hz2093:  return "2k"
        case .hz2960:  return "3k"
        case .hz4186:  return "4k"
        case .hz5920:  return "6k"
        case .hz8372:  return "8k"
        case .hz11840: return "12k"
        case .hz16744: return "17k"
        case .hz20000: return "20k"
        }
    }

    public static func < (lhs: SuperEQBand, rhs: SuperEQBand) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// 18 段高精度均衡器控制器。
///
/// 基于 FFmpeg superequalizer 滤镜（16383 阶 FIR + FFT），
/// 提供比传统 biquad EQ 更精确的频率响应控制。
///
/// 增益使用 dB 单位（-12 ~ +12），内部自动转换为 superequalizer
/// 的线性增益参数（0 ~ 20，1.0 = 0dB）。
///
/// ```swift
/// let player = StreamPlayer()
/// player.superEQ.setGain(6.0, for: .hz65)    // 低频 +6dB
/// player.superEQ.setGain(-3.0, for: .hz4186)  // 4kHz -3dB
/// player.superEQ.setEnabled(true)
/// ```
public final class SuperEqualizer {

    internal let filterGraph: SuperEQFilterGraph

    internal init(filterGraph: SuperEQFilterGraph) {
        self.filterGraph = filterGraph
    }

    // MARK: - 启用/禁用

    /// 启用/禁用 SuperEqualizer。
    /// 禁用时不消耗 CPU，音频直通。
    public func setEnabled(_ enabled: Bool) {
        filterGraph.setEnabled(enabled)
    }

    /// 是否启用。
    public var isEnabled: Bool {
        filterGraph.isEnabled
    }

    // MARK: - 增益控制

    /// 设置指定频段的增益（dB）。
    ///
    /// - Parameters:
    ///   - gainDB: 增益值，范围 [-12, +12] dB。超出范围会被 clamp。
    ///   - band: 目标频段。
    public func setGain(_ gainDB: Float, for band: SuperEQBand) {
        filterGraph.setGain(gainDB, for: band)
    }

    /// 获取指定频段的当前增益（dB）。
    public func gain(for band: SuperEQBand) -> Float {
        filterGraph.gain(for: band)
    }

    /// 批量设置所有 18 个频段的增益。
    ///
    /// - Parameter gains: 字典，key 为频段，value 为增益（dB）。
    ///   未包含的频段保持不变。
    public func setGains(_ gains: [SuperEQBand: Float]) {
        filterGraph.setGains(gains)
    }

    /// 获取所有频段的当前增益。
    public func allGains() -> [SuperEQBand: Float] {
        filterGraph.allGains()
    }

    /// 重置所有频段到 0 dB。
    public func reset() {
        filterGraph.reset()
    }
}
