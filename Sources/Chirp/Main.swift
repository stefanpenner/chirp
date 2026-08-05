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
    @State private var isMicPickerExpanded = false
    @State private var isAIPickerExpanded = false

    private var statusKind: AppStatusKind {
        AppStatusDecision.kind(from: appState.status)
    }

    var body: some Scene {
        MenuBarExtra(
            AppStatusDecision.menuBarAccessibilityLabel(statusKind),
            systemImage: AppStatusDecision.menuBarSystemImage(statusKind)
        ) {
            VStack(spacing: 0) {
                statusSection
                hotkeySection
                aiModeLabel
                microphoneSection

                SectionDivider()

                MenuRow(
                    appState.isCleaningUp ? "AI Cleanup\u{2026}" : "AI Cleanup",
                    shortcut: appState.aiCleanupChordLabel
                ) { appState.runAICleanup() }
                    .disabled(appState.transcribedText.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty || appState.isCleaningUp)

                CheckForUpdatesView(updater: updaterController.updater)
                MenuRow("Settings\u{2026}") { appState.showSettings() }

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
            // ESC closes the popover (the InlineHotkeyRecorder's local monitor
            // consumes ESC during recording first, so there's no conflict).
            .background {
                Button("") { NSApp.keyWindow?.orderOut(nil) }
                    .keyboardShortcut(.cancelAction)
                    .hidden()
            }
        }
        .menuBarExtraStyle(.window)
    }

    /// Boot / error status strip (hidden when ready or in a session).
    /// Dual labels from AppStatusDecision; actions use retry/cancel gates.
    @ViewBuilder
    private var statusSection: some View {
        let kind = AppStatusDecision.kind(from: appState.status)
        switch kind {
        case .needsModel:
            MenuRow("Download Speech Model\u{2026}") { appState.retryDownload() }
            SectionDivider()
        case .downloading:
            if case .downloading(let progress) = appState.status {
                HStack {
                    Text("Downloading model")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary.opacity(0.55))
                    Spacer()
                    Text("\(Int(min(progress / 0.9, 1.0) * 100))%")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(cBlue.opacity(0.85))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            MenuRow("Cancel Download") { appState.cancelDownload() }
            SectionDivider()
        case .loadingModel:
            Text("Loading model\u{2026}")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary.opacity(0.45))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .accessibilityLabel("Loading speech model")
            SectionDivider()
        case .error:
            if case .error(let message) = appState.status {
                Text(message)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(.primary.opacity(0.65))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
                    .accessibilityLabel("Setup error: \(message)")
            }
            MenuRow("Retry Setup") { appState.retryDownload() }
            SectionDivider()
        case .ready, .recording, .transcribing:
            EmptyView()
        }
    }

    private static var versionLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "v\(version) (\(build))"
    }

    // MARK: - AI Mode Picker

    private var activeModeLabel: String {
        appState.aiSettings.activeMode?.name ?? "Offline"
    }

    @ViewBuilder
    private var aiModeLabel: some View {
        SectionDivider()

        Button {
            if appState.aiSettings.modes.count > 1 {
                isAIPickerExpanded.toggle()
            }
        } label: {
            HStack {
                Text("AI Mode")
                    .font(.system(size: 13))
                    .foregroundColor(.primary.opacity(0.7))
                Spacer()
                Text(activeModeLabel)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(.primary.opacity(0.45))
                    .lineLimit(1)
                    .accessibilityHidden(true)
                if appState.aiSettings.modes.count > 1 {
                    Image(systemName: isAIPickerExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.primary.opacity(0.35))
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .buttonStyle(MenuRowStyle())
        .disabled(appState.aiSettings.modes.count <= 1)
        .accessibilityLabel("AI Mode, \(activeModeLabel)")
        .accessibilityHint(
            appState.aiSettings.modes.count > 1
                ? (isAIPickerExpanded ? "Collapses mode list" : "Shows available AI modes")
                : "Only one mode configured"
        )
        .accessibilityValue(isAIPickerExpanded ? "Expanded" : "Collapsed")

        if isAIPickerExpanded {
            ForEach(appState.aiSettings.modes) { mode in
                let selected = appState.aiSettings.activeModeID == mode.id
                Button {
                    appState.aiSettings.activeModeID = mode.id
                    appState.aiSettings.save()
                    appState.rebuildPipeline()
                    isAIPickerExpanded = false
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(selected ? cBlue : .clear)
                            .frame(width: 14)
                            .accessibilityHidden(true)
                        Text(mode.name)
                            .font(.system(size: 13))
                            .foregroundColor(.primary.opacity(0.7))
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                }
                .buttonStyle(MenuRowStyle())
                .accessibilityLabel(mode.name)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
    }

    // MARK: - Microphone Section

    private func selectedInputDeviceName(manager: InputDeviceManager, devices: [InputDevice]) -> String {
        if let uid = manager.selectedDeviceUID,
           let device = devices.first(where: { $0.uid == uid }) {
            return device.name
        }
        return "System Default"
    }

    @ViewBuilder
    private var microphoneSection: some View {
        let manager = appState.inputDeviceManager
        let devices = manager.devices
        if !devices.isEmpty {
            SectionDivider()

            let selectedName = selectedInputDeviceName(manager: manager, devices: devices)
            let canExpand = devices.count > 1

            // Summary row — always visible
            Button {
                if canExpand { isMicPickerExpanded.toggle() }
            } label: {
                HStack {
                    Text("Microphone")
                        .font(.system(size: 13))
                        .foregroundColor(.primary.opacity(0.7))
                    Spacer()
                    Text(selectedName)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(.primary.opacity(0.45))
                        .lineLimit(1)
                        .accessibilityHidden(true)
                    if canExpand {
                        Image(systemName: isMicPickerExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.primary.opacity(0.35))
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }
            .buttonStyle(MenuRowStyle())
            .disabled(!canExpand)
            .accessibilityLabel("Microphone, \(selectedName)")
            .accessibilityHint(
                canExpand
                    ? (isMicPickerExpanded ? "Collapses device list" : "Shows available microphones")
                    : "Only one microphone available"
            )
            .accessibilityValue(isMicPickerExpanded ? "Expanded" : "Collapsed")

            // Expanded device picker
            if isMicPickerExpanded {
                DeviceRow(
                    name: "System Default",
                    tag: nil,
                    isSelected: manager.selectedDeviceUID == nil
                ) {
                    appState.updateInputDevice(uid: nil)
                    isMicPickerExpanded = false
                }
                ForEach(devices) { device in
                    DeviceRow(
                        name: device.name,
                        tag: device.isDefault ? "default" : nil,
                        isSelected: manager.selectedDeviceUID == device.uid
                    ) {
                        appState.updateInputDevice(uid: device.uid)
                        isMicPickerExpanded = false
                    }
                }
            }
        }
    }

    // MARK: - Hotkey Section

    @ViewBuilder
    private var hotkeySection: some View {
        if hotkeyRecorder.isRecording {
            // Recording state — press any key to set; Esc to cancel
            HStack {
                Text("Press a key\u{2026}")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary.opacity(0.55))
                Spacer()
                Text("Esc to cancel")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(.primary.opacity(0.4))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(cBlue.opacity(0.5), lineWidth: 1)
                    .padding(.horizontal, 4)
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Recording hotkey. Press a key to set, or Escape to cancel.")
            .accessibilityAddTraits(.updatesFrequently)
        } else {
            // Normal state — show current hotkey, click to change
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
                        .foregroundColor(.primary.opacity(0.45))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(.primary.opacity(0.06))
                        )
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }
            .buttonStyle(MenuRowStyle())
            .accessibilityLabel("Hotkey, \(appState.hotkeyConfig.label)")
            .accessibilityHint("Records a new dictation hotkey")
        }
    }
}

// MARK: - Shared Components

private struct DeviceRow: View {
    let name: String
    let tag: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(isSelected ? cBlue : .clear)
                    .frame(width: 14)
                    .accessibilityHidden(true)
                Text(name)
                    .font(.system(size: 13))
                    .foregroundColor(.primary.opacity(0.7))
                Spacer()
                if let tag {
                    Text(tag)
                        .font(.system(size: 10))
                        .foregroundColor(.primary.opacity(0.35))
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .buttonStyle(MenuRowStyle())
        .accessibilityLabel(tag.map { "\(name), \($0)" } ?? name)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

private struct SectionDivider: View {
    var body: some View {
        Divider().overlay(Color.primary.opacity(0.06))
            .padding(.horizontal, 12).padding(.vertical, 6)
    }
}

private struct MenuRow: View {
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    let shortcut: String?
    let action: () -> Void

    init(_ title: String, shortcut: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundColor(.primary.opacity(isEnabled ? 0.7 : 0.3))
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(.primary.opacity(isEnabled ? 0.4 : 0.2))
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .buttonStyle(MenuRowStyle())
        .accessibilityLabel(title)
        .accessibilityHint(shortcut.map { "Shortcut \($0)" } ?? "")
        .accessibilityInputLabels([title])
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
