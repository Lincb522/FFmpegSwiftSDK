// ContentView.swift
// FFmpegDemo — HiFi Player 全功能演示

import SwiftUI
import AVFoundation
import FFmpegSwiftSDK

struct ContentView: View {
    @StateObject private var vm = PlayerViewModel()
    @State private var activePanel: Panel? = nil

    enum Panel: String, CaseIterable {
        case eq = "均衡器"
        case effects = "音效"
        case lyrics = "歌词"
        case abloop = "A-B循环"
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: 0x0D0D0D), Color(hex: 0x1A1A2E)],
                startPoint: .top, endPoint: .bottom
            ).ignoresSafeArea()

            VStack(spacing: 0) {
                headerBar
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        nowPlayingCard
                        if vm.spectrumEnabled { spectrumView }
                        transportControls
                        panelSelector
                        if let panel = activePanel {
                            switch panel {
                            case .eq:      eqPanel
                            case .effects: effectsPanel
                            case .lyrics:  lyricsPanel
                            case .abloop:  abLoopPanel
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("HiFi Player")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                if !vm.hifiInfoText.isEmpty {
                    Text(vm.hifiInfoText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(accent)
                }
            }
            Spacer()
            // 频谱开关
            Button {
                vm.spectrumEnabled.toggle()
            } label: {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 16))
                    .foregroundStyle(vm.spectrumEnabled ? accent : .gray)
                    .padding(8)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: - Now Playing Card

    private var nowPlayingCard: some View {
        VStack(spacing: 14) {
            // 封面 / 视频 / 状态图标
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(LinearGradient(
                        colors: [Color(hex: 0x2D2D44), Color(hex: 0x1A1A2E)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .frame(height: vm.hasVideo ? 220 : 180)

                if vm.hasVideo {
                    VideoLayerView(layer: vm.videoLayer)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(4)
                } else if let data = vm.artworkData, let img = UIImage(data: data) {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(12)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: stateIcon)
                            .font(.system(size: 44))
                            .foregroundStyle(stateAccent)
                        Text(vm.state)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }

            // 元数据
            if vm.metaTitle != nil || vm.metaArtist != nil {
                VStack(spacing: 2) {
                    if let title = vm.metaTitle {
                        Text(title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    if let artist = vm.metaArtist {
                        Text(artist + (vm.metaAlbum.map { " — \($0)" } ?? ""))
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                }
            }

            // 流信息
            if !vm.streamInfoText.isEmpty {
                Text(vm.streamInfoText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
            }

            // URL 输入
            HStack(spacing: 8) {
                Image(systemName: "link").foregroundStyle(.gray).font(.system(size: 13))
                TextField("输入音视频地址", text: $vm.urlText)
                    .font(.system(size: 13))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            .padding(10)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            // 波形 + 进度条
            if vm.duration > 0 {
                waveformProgressView
            }

            if let error = vm.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - 波形进度条

    private var waveformProgressView: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width
                let progress = vm.duration > 0 ? vm.currentTime / vm.duration : 0

                ZStack(alignment: .leading) {
                    if !vm.waveformSamples.isEmpty {
                        // 波形图
                        HStack(spacing: 1) {
                            ForEach(0..<vm.waveformSamples.count, id: \.self) { i in
                                let sample = vm.waveformSamples[i]
                                let barProgress = Double(i) / Double(vm.waveformSamples.count)
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(barProgress <= progress ? accent : Color.white.opacity(0.15))
                                    .frame(height: max(2, CGFloat(sample.positive) * 30))
                            }
                        }
                        .frame(height: 30)
                    } else {
                        // 简单进度条
                        Capsule().fill(Color.white.opacity(0.1)).frame(height: 3)
                        Capsule().fill(accent)
                            .frame(width: w * min(progress, 1), height: 3)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onEnded { drag in
                            let ratio = max(0, min(drag.location.x / w, 1))
                            vm.seek(to: vm.duration * ratio)
                        }
                )
            }
            .frame(height: vm.waveformSamples.isEmpty ? 3 : 30)

            HStack {
                Text(fmt(vm.currentTime))
                Spacer()
                if vm.tempo != 1.0 {
                    Text("\(String(format: "%.1f", vm.tempo))x")
                        .foregroundStyle(accent)
                }
                Spacer()
                Text(fmt(vm.duration))
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.white.opacity(0.4))
        }
    }

    // MARK: - 频谱

    private var spectrumView: some View {
        HStack(spacing: 2) {
            ForEach(0..<vm.spectrumData.count, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(
                        LinearGradient(
                            colors: [accent, accent.opacity(0.3)],
                            startPoint: .bottom, endPoint: .top
                        )
                    )
                    .frame(height: max(2, CGFloat(vm.spectrumData[i]) * 50))
            }
        }
        .frame(height: 50)
        .animation(.easeOut(duration: 0.08), value: vm.spectrumData)
    }

    // MARK: - Transport Controls

    private var transportControls: some View {
        HStack(spacing: 20) {
            Spacer()
            ctrlBtn(icon: "stop.fill", size: 16) { vm.stop() }
            // 主播放按钮
            Button(action: {
                if vm.state == "已暂停" { vm.resume() }
                else { vm.play() }
            }) {
                ZStack {
                    Circle().fill(accent).frame(width: 60, height: 60)
                    Image(systemName: vm.state == "播放中" ? "pause.fill" : "play.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white)
                        .offset(x: vm.state == "播放中" ? 0 : 2)
                }
            }.buttonStyle(.plain)
            ctrlBtn(icon: "pause.fill", size: 16) { vm.pause() }
            Spacer()
        }
    }

    private func ctrlBtn(icon: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 40, height: 40)
                .background(Color.white.opacity(0.06))
                .clipShape(Circle())
        }.buttonStyle(.plain)
    }

    // MARK: - Panel Selector

    private var panelSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Panel.allCases, id: \.rawValue) { panel in
                    Button {
                        withAnimation(.spring(response: 0.3)) {
                            activePanel = activePanel == panel ? nil : panel
                        }
                    } label: {
                        Text(panel.rawValue)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(activePanel == panel ? .white : .white.opacity(0.5))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(activePanel == panel ? accent.opacity(0.3) : Color.white.opacity(0.06))
                            .clipShape(Capsule())
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - EQ Panel

    private var eqPanel: some View {
        panelCard {
            VStack(spacing: 12) {
                HStack {
                    Text("10 段均衡器")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Button("重置") { vm.resetEQ() }
                        .font(.system(size: 11)).foregroundStyle(accent)
                }
                HStack(alignment: .center, spacing: 0) {
                    ForEach(EQBand.allCases, id: \.rawValue) { band in
                        eqColumn(band: band)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func eqColumn(band: EQBand) -> some View {
        let gain = vm.eqGains[band] ?? 0
        return VStack(spacing: 3) {
            Text(gain == 0 ? "0" : String(format: "%+.0f", gain))
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(abs(gain) > 6 ? accent : .white.opacity(0.4))
                .frame(height: 12)
            VerticalEQSlider(
                value: Binding(
                    get: { vm.eqGains[band] ?? 0 },
                    set: { vm.updateGain($0, for: band) }
                ),
                range: -12...12, accentColor: accent
            )
            .frame(width: 24, height: 120)
            Text(band.label)
                .font(.system(size: 7, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Effects Panel

    private var effectsPanel: some View {
        panelCard {
            VStack(spacing: 14) {
                HStack {
                    Text("音频效果")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Button("重置") { vm.resetEffects() }
                        .font(.system(size: 11)).foregroundStyle(accent)
                }

                effectSlider(label: "音量", value: vm.volume, range: -20...20, unit: "dB") { vm.updateVolume($0) }
                effectSlider(label: "倍速", value: vm.tempo, range: 0.5...4.0, unit: "x") { vm.updateTempo($0) }
                effectSlider(label: "变调", value: vm.pitch, range: -12...12, unit: "半音") { vm.updatePitch($0) }
                effectSlider(label: "低音", value: vm.bassGain, range: -12...12, unit: "dB") { vm.updateBass($0) }
                effectSlider(label: "高音", value: vm.trebleGain, range: -12...12, unit: "dB") { vm.updateTreble($0) }
                effectSlider(label: "环绕", value: vm.surroundLevel, range: 0...1, unit: "") { vm.updateSurround($0) }
                effectSlider(label: "混响", value: vm.reverbLevel, range: 0...1, unit: "") { vm.updateReverb($0) }
                effectSlider(label: "淡入", value: vm.fadeInDuration, range: 0...10, unit: "秒") { vm.updateFadeIn($0) }

                // 响度标准化开关
                HStack {
                    Text("响度标准化")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { vm.loudnormEnabled },
                        set: { _ in vm.toggleLoudnorm() }
                    ))
                    .tint(accent)
                    .labelsHidden()
                }
            }
        }
    }

    private func effectSlider(label: String, value: Float, range: ClosedRange<Float>, unit: String, onChange: @escaping (Float) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 36, alignment: .leading)
            Slider(value: Binding(
                get: { value },
                set: { onChange($0) }
            ), in: range)
            .tint(accent)
            Text(String(format: "%.1f", value) + unit)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 52, alignment: .trailing)
        }
    }

    // MARK: - Lyrics Panel

    private var lyricsPanel: some View {
        panelCard {
            VStack(spacing: 12) {
                HStack {
                    Text("歌词同步")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    if vm.hasLyrics {
                        Button("清除") { vm.clearLyrics() }
                            .font(.system(size: 11)).foregroundStyle(accent)
                    }
                }

                if vm.hasLyrics {
                    // 歌词滚动显示
                    VStack(spacing: 6) {
                        ForEach(vm.nearbyLyrics, id: \.index) { item in
                            Text(item.text)
                                .font(.system(size: item.isCurrent ? 15 : 12, weight: item.isCurrent ? .semibold : .regular))
                                .foregroundStyle(item.isCurrent ? accent : .white.opacity(0.35))
                                .frame(maxWidth: .infinity, alignment: .center)
                                .animation(.easeOut(duration: 0.2), value: item.isCurrent)
                        }
                        if let trans = vm.currentLyricTranslation {
                            Text(trans)
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                    }
                    .frame(minHeight: 80)

                    // 偏移调整
                    HStack {
                        Text("偏移")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                        Button("-0.5s") { vm.adjustLyricOffset(-0.5) }
                            .font(.system(size: 10)).foregroundStyle(accent)
                        Text(String(format: "%+.1fs", vm.lyricOffset))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(width: 44)
                        Button("+0.5s") { vm.adjustLyricOffset(0.5) }
                            .font(.system(size: 10)).foregroundStyle(accent)
                        Spacer()
                    }
                } else {
                    // 加载示例歌词
                    VStack(spacing: 8) {
                        Text("粘贴 LRC 歌词内容")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.4))
                        Button("加载示例歌词") {
                            vm.loadLyrics(sampleLRC)
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(accent.opacity(0.15))
                        .clipShape(Capsule())
                    }
                    .frame(minHeight: 60)
                }
            }
        }
    }

    // MARK: - A-B Loop Panel

    private var abLoopPanel: some View {
        panelCard {
            VStack(spacing: 12) {
                HStack {
                    Text("A-B 循环")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    if vm.abLoopEnabled {
                        Button("清除") { vm.clearABLoop() }
                            .font(.system(size: 11)).foregroundStyle(accent)
                    }
                }

                HStack(spacing: 16) {
                    // A 点
                    VStack(spacing: 4) {
                        Text("A 点").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                        Text(fmt(vm.abPointA))
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .foregroundStyle(vm.abLoopEnabled ? accent : .white.opacity(0.6))
                        Button("设为当前") { vm.setPointA() }
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(accent.opacity(0.3))
                            .clipShape(Capsule())
                    }

                    Image(systemName: "arrow.right")
                        .foregroundStyle(.white.opacity(0.3))

                    // B 点
                    VStack(spacing: 4) {
                        Text("B 点").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                        Text(fmt(vm.abPointB))
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .foregroundStyle(vm.abLoopEnabled ? accent : .white.opacity(0.6))
                        Button("设为当前") { vm.setPointB() }
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(accent.opacity(0.3))
                            .clipShape(Capsule())
                    }
                }

                if vm.abLoopEnabled {
                    Text("循环中: \(fmt(vm.abPointA)) → \(fmt(vm.abPointB))")
                        .font(.system(size: 11))
                        .foregroundStyle(accent)
                }
            }
        }
    }

    // MARK: - 通用面板卡片

    private func panelCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(14)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Helpers

    private var accent: Color { Color(hex: 0xBB86FC) }

    private var stateIcon: String {
        switch vm.state {
        case "播放中":    return "waveform"
        case "连接中...": return "antenna.radiowaves.left.and.right"
        case "已暂停":    return "pause.circle"
        case "错误":      return "exclamationmark.triangle"
        case "已停止":    return "stop.circle"
        default:          return "music.note"
        }
    }

    private var stateAccent: Color {
        switch vm.state {
        case "播放中":    return accent
        case "连接中...": return .orange
        case "错误":      return .red
        default:          return .white.opacity(0.5)
        }
    }

    private func fmt(_ s: TimeInterval) -> String {
        String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}


// MARK: - 示例 LRC 歌词

private let sampleLRC = """
[ti:示例歌曲]
[ar:FFmpeg Demo]
[al:测试专辑]
[offset:0]
[00:00.00]♪ 前奏
[00:05.00]这是第一句歌词
[00:10.00]这是第二句歌词
[00:15.00]音乐在流淌
[00:20.00]旋律在飞扬
[00:25.00]每一个音符
[00:30.00]都是一段故事
[00:35.00]让我们一起
[00:40.00]感受音乐的力量
[00:45.00]♪ 间奏
[00:55.00]这是副歌部分
[01:00.00]跟着节奏摇摆
[01:05.00]让心灵自由飞翔
[01:10.00]在音乐的海洋里
[01:15.00]找到属于自己的方向
[01:20.00]♪ 尾奏
"""

// MARK: - VideoLayerView

struct VideoLayerView: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {
        layer.frame = uiView.bounds
    }
}

// MARK: - Vertical EQ Slider

struct VerticalEQSlider: View {
    @Binding var value: Float
    let range: ClosedRange<Float>
    let accentColor: Color

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let span = range.upperBound - range.lowerBound
            let norm = CGFloat((value - range.lowerBound) / span)
            let thumbY = h * (1 - norm)

            ZStack {
                Capsule().fill(Color.white.opacity(0.1)).frame(width: 3)
                let centerY = h * 0.5
                let fillTop = min(centerY, thumbY)
                let fillH = abs(thumbY - centerY)
                Capsule()
                    .fill(accentColor.opacity(0.6))
                    .frame(width: 3, height: fillH)
                    .position(x: geo.size.width / 2, y: fillTop + fillH / 2)
                Rectangle()
                    .fill(Color.white.opacity(0.2))
                    .frame(width: 10, height: 1)
                    .position(x: geo.size.width / 2, y: centerY)
                Circle()
                    .fill(accentColor)
                    .frame(width: 12, height: 12)
                    .shadow(color: accentColor.opacity(0.4), radius: 3)
                    .position(x: geo.size.width / 2, y: thumbY)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let clamped = max(0, min(drag.location.y, h))
                        let newNorm = 1 - Float(clamped / h)
                        let raw = range.lowerBound + newNorm * span
                        value = (raw * 2).rounded() / 2
                    }
            )
        }
    }
}

// MARK: - Color Extension

extension Color {
    init(hex: UInt, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

#Preview { ContentView() }
