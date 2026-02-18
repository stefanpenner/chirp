// Main.swift — App entry point.
// Renders the menu bar extra (hotkey, quit).
// All logic lives in AppState; this file is just the SwiftUI shell.

import Chirp
import Combine
@preconcurrency import Sparkle
import SwiftUI

// Catppuccin Mocha palette (matches OverlayPanel)
private let cBlue = Color(red: 0.35, green: 0.58, blue: 1.0)

@main
struct ChirpApp: App {
    // Don't auto-start Sparkle on dev builds (version stays at 0.1.0;
    // release builds stamp the real version via scripts/package.sh).
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String != "0.1.0",
        updaterDelegate: nil, userDriverDelegate: nil)
    @State private var appState = AppState()
    @State private var hotkeyRecorder = InlineHotkeyRecorder()

    var body: some Scene {
        MenuBarExtra("Chirp", systemImage: "waveform") {
            VStack(spacing: 0) {
                hotkeySection
                CheckForUpdatesView(updater: updaterController.updater)

                SectionDivider()

                Text(Self.versionLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.primary.opacity(0.25))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 4)

                MenuRow("Quit Chirp") { NSApplication.shared.terminate(nil) }
            }
            .padding(.vertical, 8)
            .frame(width: 260)
        }
        .menuBarExtraStyle(.window)
    }

    private static var versionLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "v\(version) (\(build))"
    }

    // MARK: - Hotkey Section

    @ViewBuilder
    private var hotkeySection: some View {
        if hotkeyRecorder.isRecording || hotkeyRecorder.capturedConfig != nil {
            // Recording or captured state
            VStack(spacing: 6) {
                HStack {
                    Text(hotkeyRecorder.isRecording
                        ? "Press a key\u{2026}"
                        : hotkeyRecorder.displayLabel)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(hotkeyRecorder.isRecording
                            ? .primary.opacity(0.4) : .primary.opacity(0.9))
                    Spacer()
                    if hotkeyRecorder.isRecording {
                        Text("esc to cancel")
                            .font(.system(size: 9))
                            .foregroundColor(.primary.opacity(0.2))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            hotkeyRecorder.isRecording ? cBlue.opacity(0.5) : cBlue.opacity(0.2),
                            lineWidth: hotkeyRecorder.isRecording ? 1 : 0.5
                        )
                        .padding(.horizontal, 4)
                )

                if hotkeyRecorder.canSave {
                    HStack(spacing: 8) {
                        Button("Reset to fn") { hotkeyRecorder.resetToFn() }
                            .font(.system(size: 10))
                            .foregroundColor(.primary.opacity(0.4))
                            .buttonStyle(.plain)
                        Spacer()
                        Button("Cancel") { hotkeyRecorder.cancel() }
                            .font(.system(size: 10))
                            .foregroundColor(.primary.opacity(0.4))
                            .buttonStyle(.plain)
                        Button("Save") { hotkeyRecorder.save() }
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(cBlue)
                            .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
                }
            }
        } else {
            // Normal state — show current hotkey
            Button {
                hotkeyRecorder.startRecording(appState: appState)
            } label: {
                HStack {
                    Text("Hotkey")
                        .font(.system(size: 13))
                        .foregroundColor(.primary.opacity(0.7))
                    Spacer()
                    Text(appState.hotkeyConfig.label)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(.primary.opacity(0.4))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(.primary.opacity(0.06))
                        )
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .buttonStyle(MenuRowStyle())
        }
    }
}

// MARK: - Shared Components

private struct SectionDivider: View {
    var body: some View {
        Divider().overlay(Color.primary.opacity(0.06))
            .padding(.horizontal, 12).padding(.vertical, 6)
    }
}

private struct MenuRow: View {
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundColor(.primary.opacity(isEnabled ? 0.7 : 0.3))
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .buttonStyle(MenuRowStyle())
    }
}

private struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MenuRowBody(configuration: configuration)
    }
}

private struct MenuRowBody: View {
    let configuration: ButtonStyle.Configuration
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered ? cBlue.opacity(0.15) : Color.clear)
                    .padding(.horizontal, 4)
            )
            .onHover { isHovered = $0 }
    }
}

struct CheckForUpdatesView: View {
    @ObservedObject private var checkForUpdatesViewModel: CheckForUpdatesViewModel

    init(updater: SPUUpdater) {
        self.checkForUpdatesViewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        MenuRow("Check for Updates\u{2026}", action: checkForUpdatesViewModel.checkForUpdates)
            .disabled(!checkForUpdatesViewModel.canCheckForUpdates)
    }
}

@MainActor
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        updater.checkForUpdates()
    }
}
