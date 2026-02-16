// Main.swift — App entry point.
// Renders the menu bar extra (status, model picker, quit).
// All logic lives in AppState; this file is just the SwiftUI shell.

import Chirp
import Combine
@preconcurrency import Sparkle
import SwiftUI

// Catppuccin Mocha palette (matches OverlayPanel)
private let cBlue = Color(red: 0.35, green: 0.58, blue: 1.0)
private let cPurple = Color(red: 0.55, green: 0.40, blue: 0.95)
private let cCyan = Color(red: 0.30, green: 0.75, blue: 0.95)

@main
struct ChirpApp: App {
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    @State private var appState = AppState()
    @State private var hotkeyRecorder = InlineHotkeyRecorder()

    var body: some Scene {
        MenuBarExtra("Chirp", systemImage: "waveform") {
            VStack(spacing: 0) {
                modelSection
                hotkeySection
                CheckForUpdatesView(updater: updaterController.updater)

                SectionDivider()

                Text(Self.versionLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.25))
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

    // MARK: - Model Section

    /// Whether the active variant is mid-download or mid-load.
    private var activeVariantBusy: Bool {
        switch appState.status {
        case .downloading, .loadingModel: return true
        default: return false
        }
    }

    @ViewBuilder
    private var modelSection: some View {
        Text("Model")
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.white.opacity(0.7))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

        VStack(spacing: 0) {
            ForEach(ModelVariant.allCases, id: \.self) { variant in
                modelRow(variant: variant)
            }
        }

        SectionDivider()
    }

    @ViewBuilder
    private func modelRow(variant: ModelVariant) -> some View {
        let isActive = variant == appState.activeVariant
        let isDownloaded = appState.isModelDownloaded(variant)
        let isBackgroundDownloading = appState.backgroundDownloads[variant] != nil

        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // Model row button
                Button {
                    if isActive {
                        appState.retryDownload()
                    } else if isDownloaded {
                        appState.switchModel(to: variant)
                    } else {
                        appState.downloadModel(variant)
                    }
                } label: {
                    HStack(spacing: 6) {
                        modelIndicator(isActive: isActive, variant: variant)
                            .frame(width: 14)
                        Text(variant.displayName)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(isActive ? 0.9 : 0.5))
                            .lineLimit(1)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 4)
                    .padding(.leading, 8)
                    .padding(.vertical, 4)
                }
                .buttonStyle(MenuRowStyle())
                .disabled(isBackgroundDownloading
                    || (isActive && !isErrorOrNeedsModel && !appState.canSwitchModel))

                // Delete button on the right
                if isDownloaded && appState.canSwitchModel {
                    Button {
                        appState.deleteModel(variant)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundColor(.white.opacity(0.2))
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(DeleteButtonStyle())
                    .padding(.trailing, 12)
                }
            }

            // Inline error for active variant
            if isActive, case .error(let msg) = appState.status {
                HStack(spacing: 6) {
                    Text(msg)
                        .font(.system(size: 9))
                        .foregroundColor(Color(red: 0.95, green: 0.30, blue: 0.30))
                        .lineLimit(1)
                    Button("Retry") {
                        appState.retryDownload()
                    }
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(cBlue)
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 40)
                .padding(.top, 2)
                .padding(.bottom, 4)
            }
        }
    }

    private var isErrorOrNeedsModel: Bool {
        switch appState.status {
        case .error, .needsModel: return true
        default: return false
        }
    }

    @ViewBuilder
    private func modelIndicator(isActive: Bool, variant: ModelVariant) -> some View {
        let isDownloaded = appState.isModelDownloaded(variant)
        let isBackgroundDownloading = appState.backgroundDownloads[variant] != nil

        if isBackgroundDownloading {
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.6)
        } else if isActive {
            switch appState.status {
            case .downloading:
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.6)
            case .loadingModel:
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.6)
            case .needsModel:
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 10))
                    .foregroundColor(cCyan)
            case .error:
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 10))
                    .foregroundColor(Color(red: 0.95, green: 0.30, blue: 0.30))
            default:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(cBlue)
            }
        } else if !isDownloaded {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 10))
                .foregroundColor(cCyan.opacity(0.5))
        } else {
            Image(systemName: "circle")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.2))
        }
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
                            ? .white.opacity(0.4) : .white.opacity(0.9))
                    Spacer()
                    if hotkeyRecorder.isRecording {
                        Text("esc to cancel")
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.2))
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
                            .foregroundColor(.white.opacity(0.4))
                            .buttonStyle(.plain)
                        Spacer()
                        Button("Cancel") { hotkeyRecorder.cancel() }
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.4))
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
                        .foregroundColor(.white.opacity(0.7))
                    Spacer()
                    Text(appState.hotkeyConfig.label)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.4))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(.white.opacity(0.06))
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
        Divider().overlay(Color.white.opacity(0.06))
            .padding(.horizontal, 12).padding(.vertical, 6)
    }
}

private struct MenuRow: View {
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
                    .foregroundColor(.white.opacity(0.7))
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

private struct DeleteButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DeleteButtonBody(configuration: configuration)
    }
}

private struct DeleteButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(isHovered ? Color.red.opacity(0.2) : Color.clear)
            )
            .foregroundColor(isHovered ? .red.opacity(0.8) : nil)
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
