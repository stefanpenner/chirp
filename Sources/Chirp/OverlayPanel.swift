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
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 120),
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
            panel.setFrameOrigin(NSPoint(x: f.midX - 170, y: f.maxY - 140))
        }
        self.panel = panel
    }
}

// MARK: - Waves

private struct WaveConfig {
    let freq: Double, speed: Double, opacity: Double, width: Double
    let c1: Color, c2: Color, h2: Double, h3: Double
}

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

// MARK: - Island View

struct IslandView: View {
    @ObservedObject var appState: AppState

    private var isRecording: Bool {
        if case .recording = appState.status { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            if isRecording {
                LiveWaves(level: appState.audioLevel)
                    .frame(height: 28)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
            } else {
                Circle()
                    .fill(cBlue.opacity(0.5))
                    .frame(width: 6, height: 6)
                    .padding(.top, 12)
                    .padding(.bottom, 6)
            }

            Group {
                if !appState.transcribedText.isEmpty || !appState.speculativeText.isEmpty {
                    (committed + speculative)
                        .lineLimit(2)
                        .truncationMode(.head)
                } else {
                    Text(isRecording ? "Listening..." : "Ready")
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .font(.system(size: 13, weight: .regular))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.bottom, isRecording ? 4 : 10)

            if isRecording {
                Text("release fn")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.2))
                    .padding(.bottom, 8)
            }
        }
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.black)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.06), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 20, y: 6)
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
