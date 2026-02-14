// Main.swift — App entry point.
// Renders the menu bar extra (status, model picker, quit).
// All logic lives in AppState; this file is just the SwiftUI shell.

#if BAZEL_BUILD
import Chirp
#endif
import SwiftUI

@main
struct ChirpApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("Chirp", systemImage: "mic.fill") {
            statusView
            Divider()
            modelPicker
            Divider()
            Button("Quit Chirp") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch appState.status {
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 4) {
                Text("Downloading model...")
                    .font(.caption)
                ProgressView(value: progress)
                Text("\(Int(progress * 100))%")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 4)
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
        }
    }

    @ViewBuilder
    private var modelPicker: some View {
        Text("Model").font(.caption).foregroundColor(.secondary)
        ForEach(ModelVariant.allCases, id: \.self) { variant in
            Button {
                appState.switchVariant(variant)
            } label: {
                HStack {
                    Text(variant.displayName)
                    if variant == appState.selectedVariant {
                        Spacer()
                        Image(systemName: "checkmark")
                    }
                }
            }
            .disabled(!isReady)
        }
    }

    private var isReady: Bool {
        if case .ready = appState.status { return true }
        return false
    }
}
