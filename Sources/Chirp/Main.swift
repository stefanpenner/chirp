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
        MenuBarExtra("Chirp", systemImage: "mic.fill") {
            statusView
            Divider()
            modelMenu
            Divider()
            CheckForUpdatesView(updater: updaterController.updater)
            Divider()
            Button("Quit Chirp") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }

    @ViewBuilder
    private var modelMenu: some View {
        Menu("Model") {
            ForEach(ModelVariant.allCases, id: \.self) { variant in
                let isActive = variant == appState.activeVariant
                let isDownloaded = appState.isModelDownloaded(variant)
                let sizeLabel = isDownloaded ? "" : " (\(variant.sizeDescription))"

                Button {
                    appState.switchModel(to: variant)
                } label: {
                    Text("\(isActive ? "✓ " : "   ")\(variant.displayName) — \(variant.languageDescription)\(sizeLabel)")
                }
                .disabled(!appState.canSwitchModel)

                if isDownloaded {
                    Button("   Delete \(variant.displayName)\u{2026}") {
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
        case .downloading:
            Text("Downloading model\u{2026}").font(.caption).foregroundColor(.secondary)
        case .loadingModel:
            Text("Loading model...").font(.caption).foregroundColor(.orange)
        case .ready:
            Text("Ready (hold fn)").font(.caption).foregroundColor(.secondary)
        case .recording:
            Text("Recording...").font(.caption).foregroundColor(.red)
        case .transcribing:
            Text("Finalizing...").font(.caption).foregroundColor(.orange)
        case .error(let msg):
            Text("Error: \(msg)").font(.caption).foregroundColor(.red)
            Button("Retry Download") { appState.retryDownload() }
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
