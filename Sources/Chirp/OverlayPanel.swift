import AppKit
import SwiftUI

@MainActor
final class OverlayPanel {
    private var panel: NSPanel?
    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    func showOverlay() {
        if panel == nil {
            createPanel()
        }
        panel?.orderFront(nil)
    }

    func hideOverlay() {
        panel?.orderOut(nil)
    }

    private func createPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 72),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let hostingView = NSHostingView(rootView: OverlayView(appState: appState))
        panel.contentView = hostingView

        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - 140
            let y = screenFrame.maxY - 200
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        self.panel = panel
    }
}

struct OverlayView: View {
    @ObservedObject var appState: AppState
    @State private var isPulsing = false

    private var isRecording: Bool {
        if case .recording = appState.status { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(isRecording ? Color.red : Color.orange)
                .frame(width: 12, height: 12)
                .scaleEffect(isPulsing ? 1.3 : 1.0)
                .animation(
                    .easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                    value: isPulsing
                )

            Text(statusText)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.primary)

            Spacer()

            if isRecording {
                Text("⌥Space to stop")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(width: 280, height: 72)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onAppear { isPulsing = true }
    }

    private var statusText: String {
        switch appState.status {
        case .recording: return "Listening..."
        case .transcribing: return "Transcribing..."
        default: return "Ready"
        }
    }
}
