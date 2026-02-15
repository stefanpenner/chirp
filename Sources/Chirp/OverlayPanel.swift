// OverlayPanel.swift — Floating HUD that appears during recording.
// Shows live audio waveforms, committed + speculative transcript text,
// and a glowing border. Themed with a Catppuccin-inspired palette.
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
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
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
            panel.setFrameOrigin(NSPoint(x: f.midX - 210, y: f.maxY - 180))
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
    WaveConfig(freq: 3.5, speed: 1.6, opacity: 0.25, width: 1.5, c1: cPurple, c2: cCyan,   h2: 0.4,  h3: 0.2),
    WaveConfig(freq: 2.2, speed: 2.5, opacity: 0.45, width: 2.0, c1: cCyan,   c2: cBlue,   h2: 0.3,  h3: 0.15),
    WaveConfig(freq: 1.6, speed: 1.0, opacity: 0.75, width: 2.5, c1: cBlue,   c2: cPurple, h2: 0.35, h3: 0.2),
    WaveConfig(freq: 2.8, speed: 1.8, opacity: 0.15, width: 1.0, c1: cPurple, c2: cCyan,   h2: 0.5,  h3: 0.3),
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

    private func drawWaves(ctx: inout GraphicsContext, size: CGSize, t: Double) {
        let amp = Double(min(level * 3.0, 1))
        let midY = size.height / 2

        for (i, w) in waveConfigs.enumerated() {
            let phase = Double(i) * 1.3
            var path = Path()
            let steps = Int(size.width)
            for x in 0...steps {
                let xNorm = Double(x) / Double(steps)
                let envelope = sin(xNorm * .pi)
                let primary = sin(xNorm * w.freq * .pi * 2 + t * w.speed * 5 + phase)
                let harm2 = sin(xNorm * w.freq * 2.3 * .pi * 2 + t * w.speed * 3.7 + phase * 1.5) * w.h2
                let harm3 = sin(xNorm * w.freq * 3.7 * .pi * 2 + t * w.speed * 2.1 + phase * 2.0) * w.h3
                let y = midY + (primary + harm2 + harm3) * amp * midY * 0.85 * envelope
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

// MARK: - Island View

struct IslandView: View {
    var appState: AppState

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

    private var breathe: CGFloat {
        isRecording ? 1.0 + CGFloat(min(appState.audioLevel * 0.8, 1)) * 0.015 : 1.0
    }

    var body: some View {
        VStack(spacing: 0) {
            if isRecording {
                LiveWaves(level: appState.audioLevel)
                    .frame(height: 28)
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

            Group {
                if !appState.transcribedText.isEmpty || !appState.speculativeText.isEmpty {
                    Text("\(committed)\(speculative)")
                        .lineLimit(2)
                        .truncationMode(.head)
                } else {
                    Text(isRecording ? "Listening..." : isTranscribing ? "Finalizing..." : "Ready")
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .font(.system(size: 13, weight: .regular))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.bottom, isActive ? 4 : 10)

            if isRecording {
                Text("release fn")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.2))
                    .padding(.bottom, 8)
                    .transition(.opacity)
            } else if isTranscribing {
                Text("Finalizing...")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.2))
                    .padding(.bottom, 8)
                    .transition(.opacity)
            }
        }
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.black)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(isActive ? 0.03 : 0.06), lineWidth: 0.5)
        )
        .overlay(GlowBorder(active: isActive, level: isTranscribing ? 0.3 : appState.audioLevel))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .scaleEffect(breathe)
        .shadow(color: .black.opacity(0.3), radius: 20, y: 6)
        .animation(.easeInOut(duration: 0.1), value: breathe)
        .animation(.smooth(duration: 0.35), value: isActive)
        .padding(40)
    }

    private var committed: Text {
        Text(appState.transcribedText)
            .foregroundColor(.white)
    }

    private var speculative: Text {
        let pfx = appState.transcribedText.isEmpty ? "" : " "
        return Text(pfx + appState.speculativeText)
            .foregroundColor(.white.opacity(0.4))
    }
}
