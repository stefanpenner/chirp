// Main.swift — App entry point.
// Renders the menu bar extra (status, model picker, quit).
// All logic lives in AppState; this file is just the SwiftUI shell.

import Chirp
import Combine
@preconcurrency import Sparkle
import SwiftUI

@main
struct ChirpApp: App {
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("Chirp", systemImage: "waveform") {
            statusView
            modelMenu
            Button("Change Hotkey (\(appState.hotkeyConfig.label))\u{2026}") {
                appState.showHotkeyRecorder()
            }
            Divider()
            CheckForUpdatesView(updater: updaterController.updater)
            Text(Self.versionLabel).font(.caption).foregroundColor(.secondary)
            Button("Quit Chirp") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }

    private static var versionLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Chirp v\(version) (\(build))"
    }

    @ViewBuilder
    private var modelMenu: some View {
        Menu("Model") {
            ForEach(ModelVariant.allCases, id: \.self) { variant in
                let isActive = variant == appState.activeVariant
                let isDownloaded = appState.isModelDownloaded(variant)
                let sizeLabel = appState.modelDiskSize(variant).map { " (\($0))" }
                    ?? (isDownloaded ? "" : " (\(variant.sizeDescription))")

                Button {
                    appState.switchModel(to: variant)
                } label: {
                    Text("\(isActive ? "✓ " : "   ")\(variant.displayName) — \(variant.languageDescription)\(sizeLabel)")
                }
                .disabled(!appState.canSwitchModel)
            }

            let downloadedVariants = ModelVariant.allCases.filter { appState.isModelDownloaded($0) }
            if !downloadedVariants.isEmpty {
                Divider()
                ForEach(downloadedVariants, id: \.self) { variant in
                    Button("Delete \(variant.displayName)\u{2026}") {
                        appState.deleteModel(variant)
                    }
                    .disabled(!appState.canSwitchModel)
                }
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch appState.status {
        case .needsModel:
            Text("No model loaded").font(.caption).foregroundColor(.secondary)
            Button("Download Model") { appState.retryDownload() }
            Divider()
        case .downloading:
            Text("Downloading model\u{2026}").font(.caption).foregroundColor(.secondary)
            Divider()
        case .loadingModel:
            Text("Loading model...").font(.caption).foregroundColor(.orange)
            Divider()
        case .ready:
            EmptyView()
        case .recording:
            Text("Recording...").font(.caption).foregroundColor(.red)
            Divider()
        case .transcribing:
            Text("Finalizing...").font(.caption).foregroundColor(.orange)
            Divider()
        case .error(let msg):
            Text("Error: \(msg)").font(.caption).foregroundColor(.red)
            Button("Retry Download") { appState.retryDownload() }
            Divider()
        }
    }
}

struct CheckForUpdatesView: View {
    @ObservedObject private var checkForUpdatesViewModel: CheckForUpdatesViewModel

    init(updater: SPUUpdater) {
        self.checkForUpdatesViewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates\u{2026}", action: checkForUpdatesViewModel.checkForUpdates)
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
