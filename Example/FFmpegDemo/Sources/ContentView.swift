// ContentView.swift
// FFmpegDemo — HiFi Player

import SwiftUI
import FFmpegSwiftSDK

struct ContentView: View {
    @StateObject private var vm = PlayerViewModel()
    @State private var showEQ = false

    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [Color(hex: 0x0D0D0D), Color(hex: 0x1A1A2E)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                headerBar
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 24) {
                        nowPlayingCard
                        transportControls
                        if showEQ { eqPanel }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
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
                        .foregroundStyle(Color(hex: 0xBB86FC))
                }
            }
            Spacer()
            Button {
                withAnimation(.spring(response: 0.3)) { showEQ.toggle() }
            } label: {
                Image(systemName: "slider.vertical.3")
                    .font(.system(size: 18))
                    .foregroundStyle(showEQ ? Color(hex: 0xBB86FC) : .gray)
                    .padding(8)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Now Playing Card

    private var nowPlayingCard: some View {
        VStack(spacing: 16) {
            // Album art placeholder
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: 0x2D2D44), Color(hex: 0x1A1A2E)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .frame(height: 200)

                VStack(spacing: 12) {
                    Image(systemName: stateIcon)
                        .font(.system(size: 48))
                        .foregroundStyle(stateAccent)
                        .opacity(vm.state == "播放中" ? 1.0 : 0.6)

                    Text(vm.state)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))

                    if !vm.streamInfoText.isEmpty {
                        Text(vm.streamInfoText)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
            }

            // URL input
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .foregroundStyle(.gray)
                    .font(.system(size: 14))
                TextField("输入音源地址", text: $vm.urlText)
                    .font(.system(size: 14))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            .padding(12)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            // Progress
            if vm.duration > 0 {
                VStack(spacing: 4) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.1))
                                .frame(height: 3)
                            Capsule().fill(Color(hex: 0xBB86FC))
                                .frame(
                                    width: geo.size.width * min(vm.currentTime / vm.duration, 1),
                                    height: 3
                                )
                        }
                    }
                    .frame(height: 3)

                    HStack {
                        Text(fmt(vm.currentTime))
                        Spacer()
                        Text(fmt(vm.duration))
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                }
            }

            // Error
            if let error = vm.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Transport Controls

    private var transportControls: some View {
        HStack(spacing: 20) {
            Spacer()

            controlButton(icon: "stop.fill", size: 18) { vm.stop() }

            // Main play button
            Button(action: {
                if vm.state == "已暂停" { vm.resume() }
                else { vm.play() }
            }) {
                ZStack {
                    Circle()
                        .fill(Color(hex: 0xBB86FC))
                        .frame(width: 64, height: 64)
                    Image(systemName: vm.state == "播放中" ? "pause.fill" : "play.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.white)
                        .offset(x: vm.state == "播放中" ? 0 : 2)
                }
            }
            .buttonStyle(.plain)

            controlButton(icon: "pause.fill", size: 18) { vm.pause() }

            Spacer()
        }
    }

    private func controlButton(icon: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(0.06))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - EQ Panel

    private var eqPanel: some View {
        VStack(spacing: 12) {
            HStack {
                Text("均衡器")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Button("重置") { vm.resetEQ() }
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: 0xBB86FC))
            }

            // 10-band EQ
            HStack(alignment: .center, spacing: 0) {
                ForEach(EQBand.allCases, id: \.rawValue) { band in
                    eqColumn(band: band)
                }
            }
            .padding(.vertical, 8)

            // dB scale
            HStack {
                Text("+12 dB").font(.system(size: 8))
                Spacer()
                Text("0 dB").font(.system(size: 8))
                Spacer()
                Text("-12 dB").font(.system(size: 8))
            }
            .foregroundStyle(.white.opacity(0.3))
        }
        .padding(16)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func eqColumn(band: EQBand) -> some View {
        let gain = vm.eqGains[band] ?? 0
        return VStack(spacing: 4) {
            Text(gain == 0 ? "0" : String(format: "%+.1f", gain))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(
                    abs(gain) > 6 ? Color(hex: 0xBB86FC) : .white.opacity(0.5)
                )
                .frame(height: 14)

            VerticalEQSlider(
                value: Binding(
                    get: { vm.eqGains[band] ?? 0 },
                    set: { vm.updateGain($0, for: band) }
                ),
                range: -12...12,
                accentColor: Color(hex: 0xBB86FC)
            )
            .frame(width: 28, height: 140)

            Text(band.label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .frame(height: 12)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Helpers

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
        case "播放中":    return Color(hex: 0xBB86FC)
        case "连接中...": return .orange
        case "错误":      return .red
        default:          return .white.opacity(0.5)
        }
    }

    private func fmt(_ s: TimeInterval) -> String {
        String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}

// MARK: - Vertical EQ Slider

/// A custom vertical slider for EQ bands using DragGesture.
/// Avoids the broken rotated-Slider approach where touch input maps incorrectly.
struct VerticalEQSlider: View {
    @Binding var value: Float
    let range: ClosedRange<Float>
    let accentColor: Color

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let span = range.upperBound - range.lowerBound
            // normalized 0 (bottom = min) to 1 (top = max)
            let norm = CGFloat((value - range.lowerBound) / span)
            let thumbY = h * (1 - norm)

            ZStack {
                // Track background
                Capsule()
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 3)

                // Active fill from center
                let centerY = h * 0.5
                let fillTop = min(centerY, thumbY)
                let fillH = abs(thumbY - centerY)
                Capsule()
                    .fill(accentColor.opacity(0.6))
                    .frame(width: 3, height: fillH)
                    .position(x: geo.size.width / 2, y: fillTop + fillH / 2)

                // Center line
                Rectangle()
                    .fill(Color.white.opacity(0.2))
                    .frame(width: 10, height: 1)
                    .position(x: geo.size.width / 2, y: centerY)

                // Thumb
                Circle()
                    .fill(accentColor)
                    .frame(width: 14, height: 14)
                    .shadow(color: accentColor.opacity(0.4), radius: 4)
                    .position(x: geo.size.width / 2, y: thumbY)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let clamped = max(0, min(drag.location.y, h))
                        let newNorm = 1 - Float(clamped / h)
                        let raw = range.lowerBound + newNorm * span
                        // Snap to 0.5 dB steps
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
