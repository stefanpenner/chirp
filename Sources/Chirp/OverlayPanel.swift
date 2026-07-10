// OverlayPanel.swift — Floating HUD that appears during recording.
// Shows live audio waveforms, committed + speculative transcript text,
// and a glowing border. Adapts to system light/dark theme with Catppuccin-inspired accents.
// Managed by AppState.showOverlay() / hideOverlay().

import AppKit
import SwiftUI

private let cBlue   = Color(red: 0.35, green: 0.58, blue: 1.0)
private let cPurple = Color(red: 0.55, green: 0.40, blue: 0.95)
private let cCyan   = Color(red: 0.30, green: 0.75, blue: 0.95)

// MARK: - Panel

@MainActor
final class OverlayPanel {
    private var panel: NSPanel?
    private let appState: AppState

    init(appState: AppState) { self.appState = appState }

    func showOverlay() {
        if panel == nil { createPanel() }
        panel?.orderFront(nil)
    }

    func hideOverlay() { panel?.orderOut(nil) }

    private func createPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 600),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: IslandView(appState: appState))

        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - 210, y: f.maxY - 570))
        }
        self.panel = panel
    }
}

// MARK: - Waves

private struct WaveConfig {
    let freq: Double, speed: Double, opacity: Double, width: Double
    let c1: Color, c2: Color, h2: Double, h3: Double
}

/// Four layered sine waves with harmonics, creating an organic waveform effect.
private let waveConfigs: [WaveConfig] = [
    WaveConfig(freq: 4.0, speed: 1.8, opacity: 0.25, width: 1.5, c1: cPurple, c2: cCyan,   h2: 0.45, h3: 0.25),
    WaveConfig(freq: 2.5, speed: 2.8, opacity: 0.45, width: 2.0, c1: cCyan,   c2: cBlue,   h2: 0.35, h3: 0.2),
    WaveConfig(freq: 1.8, speed: 1.2, opacity: 0.75, width: 2.5, c1: cBlue,   c2: cPurple, h2: 0.4,  h3: 0.25),
    WaveConfig(freq: 3.2, speed: 2.0, opacity: 0.15, width: 1.0, c1: cPurple, c2: cCyan,   h2: 0.55, h3: 0.35),
]

struct LiveWaves: View {
    let level: Float

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                drawWaves(ctx: &ctx, size: size, t: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    /// Smooth envelope that fades in/out gently at the edges using a raised cosine.
    /// The `margin` parameter (0–0.5) controls what fraction of each side tapers.
    private static func envelope(_ xNorm: Double, margin: Double = 0.15) -> Double {
        if xNorm < margin {
            return 0.5 * (1 - cos(.pi * xNorm / margin))
        } else if xNorm > 1 - margin {
            return 0.5 * (1 - cos(.pi * (1 - xNorm) / margin))
        }
        return 1.0
    }

    private func drawWaves(ctx: inout GraphicsContext, size: CGSize, t: Double) {
        let voiceAmp = Double(min(level * 3.0, 1))
        // Gentle breathing idle animation so the waves are never completely flat
        let idle = 0.06 + 0.04 * sin(t * 0.8)
        let amp = max(voiceAmp, idle)
        let midY = size.height / 2
        // Keep waves within 60% of half-height so they never clip
        let maxDisplacement = midY * 0.6

        for (i, w) in waveConfigs.enumerated() {
            let phase = Double(i) * 1.3
            var path = Path()
            let steps = Int(size.width)
            for x in 0...steps {
                let xNorm = Double(x) / Double(steps)
                let env = Self.envelope(xNorm)
                let primary = sin(xNorm * w.freq * .pi * 2 + t * w.speed * 5 + phase)
                let harm2 = sin(xNorm * w.freq * 2.3 * .pi * 2 + t * w.speed * 3.7 + phase * 1.5) * w.h2
                let harm3 = sin(xNorm * w.freq * 3.7 * .pi * 2 + t * w.speed * 2.1 + phase * 2.0) * w.h3
                let y = midY + (primary + harm2 + harm3) * amp * maxDisplacement * env
                if x == 0 { path.move(to: CGPoint(x: Double(x), y: y)) }
                else { path.addLine(to: CGPoint(x: Double(x), y: y)) }
            }

            ctx.opacity = w.opacity * (0.15 + amp * 0.85)
            ctx.stroke(path, with: .linearGradient(
                Gradient(colors: [w.c1, w.c2]),
                startPoint: CGPoint(x: 0, y: midY),
                endPoint: CGPoint(x: size.width, y: midY)
            ), style: StrokeStyle(lineWidth: w.width, lineCap: .round))
        }
    }
}

// MARK: - Animated Border

struct GlowBorder: View {
    let active: Bool
    let level: Float

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                guard active else { return }
                let t = timeline.date.timeIntervalSinceReferenceDate
                let amp = Double(min(level * 2.5, 1))
                let rect = CGRect(origin: .zero, size: size)
                let path = RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .path(in: rect)

                ctx.opacity = 0.15 + amp * 0.4
                ctx.stroke(path, with: .conicGradient(
                    Gradient(colors: [cBlue, cPurple, cCyan, cBlue]),
                    center: CGPoint(x: size.width / 2, y: size.height / 2),
                    angle: .degrees(t * 40)
                ), style: StrokeStyle(lineWidth: 1.5))
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Text Height Measurement

private struct TextHeightKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Island View

struct IslandView: View {
    @Environment(\.colorScheme) private var colorScheme
    var appState: AppState
    @State private var textHeight: CGFloat = 0
    @State private var pulseOpacity: Double = 1.0

    /// True for `.recording` or `.transcribing` — drives glow border, padding, border opacity.
    private var isActive: Bool {
        switch appState.status {
        case .recording, .transcribing: return true
        default: return false
        }
    }

    private var isRecording: Bool {
        if case .recording = appState.status { return true }
        return false
    }

    private var isTranscribing: Bool {
        if case .transcribing = appState.status { return true }
        return false
    }

    private var isDownloading: Bool {
        if case .downloading = appState.status { return true }
        return false
    }

    private var downloadProgress: Double {
        if case .downloading(let p) = appState.status { return p }
        return 0
    }

    private var isLoadingModel: Bool {
        if case .loadingModel = appState.status { return true }
        return false
    }

    /// Label shown during the transcribing state, reflecting the current processing phase.
    private var transcribingLabel: String {
        switch appState.processingPhase {
        case .fixing: return "Fixing\u{2026}"
        case .transcribing: return "Transcribing\u{2026}"
        case .none: return appState.pipelineTypesIncrementally ? "Finalizing\u{2026}" : "Processing\u{2026}"
        }
    }

    /// Show the text area once any text has appeared during an active session,
    /// even if speculative text is momentarily empty between segments.
    private var hasTextToShow: Bool {
        if !appState.transcribedText.isEmpty || !appState.speculativeText.isEmpty {
            return true
        }
        // Keep text area visible during active session if we've already measured content
        if isActive && textHeight > 0 {
            return true
        }
        return false
    }

    private var breathe: CGFloat {
        isRecording ? 1.0 + CGFloat(min(appState.audioLevel * 0.8, 1)) * 0.015 : 1.0
    }

    var body: some View {
        VStack(spacing: 0) {
            if isActive {
                HStack(spacing: 6) {
                    Text(appState.aiSettings.activeMode?.name ?? "Offline")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.25))
                    if let capsLabel = appState.capsMode.overlayLabel {
                        Text(capsLabel)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary.opacity(0.55))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(.primary.opacity(0.08))
                            )
                            .accessibilityLabel("Capitalization mode: \(capsLabel)")
                    }
                    if appState.awaitingReplace {
                        Text("Replace…")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.orange.opacity(0.85))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(.orange.opacity(0.12))
                            )
                            .accessibilityLabel("Waiting for replacement phrase")
                    }
                }
                .padding(.top, 10)
                .transition(.opacity)
            }

            if isDownloading && downloadProgress >= 0.9 {
                // Extraction phase — full pulsing bar
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [cBlue, cCyan],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 6)
                    .phaseAnimator([false, true]) { content, phase in
                        content.opacity(phase ? 1.0 : 0.4)
                    } animation: { _ in
                        .easeInOut(duration: 0.8)
                    }
                    .clipShape(Capsule())
                    .padding(.horizontal, 24)
                    .padding(.top, 14)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            } else if isDownloading {
                // Download phase — determinate progress bar (rescaled 0-0.9 → 0-1.0)
                Capsule()
                    .fill(.primary.opacity(0.08))
                    .frame(height: 6)
                    .overlay(alignment: .leading) {
                        GeometryReader { geo in
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [cBlue, cCyan],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: max(geo.size.width * min(downloadProgress / 0.9, 1.0), 0))
                                .animation(.easeInOut(duration: 0.3), value: downloadProgress)
                        }
                    }
                    .clipShape(Capsule())
                    .padding(.horizontal, 24)
                    .padding(.top, 14)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            } else if isLoadingModel {
                ProgressView()
                    .controlSize(.small)
                    .tint(cBlue)
                    .padding(.top, 12)
                    .padding(.bottom, 6)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            } else if isRecording {
                LiveWaves(level: appState.audioLevel)
                    .frame(height: 52)
                    .padding(.vertical, -6)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            } else if isTranscribing {
                Circle()
                    .fill(cBlue.opacity(0.6))
                    .frame(width: 8, height: 8)
                    .phaseAnimator([false, true]) { content, phase in
                        content.opacity(phase ? 1.0 : 0.4)
                    } animation: { _ in
                        .easeInOut(duration: 0.6)
                    }
                    .padding(.top, 10)
                    .padding(.bottom, 6)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            } else {
                Circle()
                    .fill(cBlue.opacity(0.5))
                    .frame(width: 6, height: 6)
                    .padding(.top, 12)
                    .padding(.bottom, 6)
                    .transition(.opacity.combined(with: .scale(scale: 0.5)))
            }

            if isDownloading || isLoadingModel {
                VStack(spacing: 4) {
                    if isDownloading && downloadProgress >= 0.9 {
                        Text("Extracting\u{2026}")
                            .foregroundStyle(.primary.opacity(0.7))
                    } else if isDownloading {
                        HStack(spacing: 0) {
                            Text("Downloading")
                                .foregroundStyle(.primary.opacity(0.7))
                            Text("  \(Int(downloadProgress / 0.9 * 100))%")
                                .foregroundStyle(.primary.opacity(0.35))
                        }
                    } else {
                        Text("Loading\u{2026}")
                            .foregroundStyle(.primary.opacity(0.7))
                    }

                    Text(ModelVariant.displayName)
                        .foregroundStyle(cBlue.opacity(0.8))
                        .underline(color: cBlue.opacity(0.3))
                        .onTapGesture { NSWorkspace.shared.open(ModelVariant.infoURL) }

                    Text("\(ModelVariant.sizeDescription) compressed")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.primary.opacity(0.25))
                }
                .font(.system(size: 15, weight: .regular))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            } else {
                Group {
                    if hasTextToShow {
                        ScrollViewReader { proxy in
                            ScrollView(.vertical, showsIndicators: false) {
                                Text("\(committed)\(speculative)")
                                    .lineLimit(nil)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .opacity(isTranscribing ? pulseOpacity : 1.0)
                                    .background(GeometryReader { geo in
                                        Color.clear.preference(key: TextHeightKey.self, value: geo.size.height)
                                    })
                                    .id("transcriptionEnd")
                            }
                            .frame(height: min(textHeight, 300))
                            .onPreferenceChange(TextHeightKey.self) { height in
                                withAnimation(.easeOut(duration: 0.2)) {
                                    textHeight = height
                                }
                            }
                            .onChange(of: appState.transcribedText) {
                                withAnimation(.easeOut(duration: 0.15)) {
                                    proxy.scrollTo("transcriptionEnd", anchor: .bottom)
                                }
                            }
                            .onChange(of: appState.speculativeText) {
                                withAnimation(.easeOut(duration: 0.15)) {
                                    proxy.scrollTo("transcriptionEnd", anchor: .bottom)
                                }
                            }
                        }
                    } else {
                        Text(isRecording ? "Listening..." : isTranscribing ? transcribingLabel : "Ready")
                            .foregroundStyle(.primary.opacity(0.4))
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .font(.system(size: 15, weight: .regular))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.bottom, isActive ? 4 : 10)
                .onChange(of: isTranscribing) { _, transcribing in
                    if transcribing {
                        withAnimation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true)) {
                            pulseOpacity = 0.4
                        }
                    } else {
                        withAnimation(.easeOut(duration: 0.15)) {
                            pulseOpacity = 1.0
                        }
                    }
                }
            }

            if isDownloading {
                Text("Cancel")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.35))
                    .onTapGesture { appState.cancelDownload() }
                    .onHover { inside in
                        if inside {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .padding(.bottom, 8)
                    .transition(.opacity)
            } else if isRecording {
                Text("release \(appState.hotkeyConfig.label) to finish")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.2))
                    .padding(.bottom, 8)
                    .transition(.opacity)
            } else if isTranscribing {
                Text("esc to discard")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.2))
                    .padding(.bottom, 8)
                    .transition(.opacity)
            }
        }
        .frame(width: 360)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(colorScheme == .dark ? Color.black : Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.primary.opacity((isActive || isDownloading) ? 0.03 : 0.06), lineWidth: 0.5)
        )
        .overlay(GlowBorder(active: isActive || isDownloading, level: isDownloading ? 0.15 : isTranscribing ? 0.3 : appState.audioLevel))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .scaleEffect(appState.downloadNudge ? 1.03 : breathe)
        .shadow(color: .black.opacity(0.3), radius: 20, y: 6)
        .animation(.easeInOut(duration: 0.15), value: appState.downloadNudge)
        .animation(.easeInOut(duration: 0.1), value: breathe)
        .animation(.smooth(duration: 0.35), value: isActive)
        .padding(40)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var committed: Text {
        Text(appState.transcribedText)
            .foregroundColor(.primary)
    }

    private var speculative: Text {
        let pfx = appState.transcribedText.isEmpty ? "" : " "
        return Text(pfx + appState.speculativeText)
            .foregroundColor(.primary.opacity(0.4))
    }
}
