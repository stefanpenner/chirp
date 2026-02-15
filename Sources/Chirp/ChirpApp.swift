// ChirpApp.swift — App entry point and core state machine.
// AppState owns the full lifecycle: model download → loading → ready ⇄ recording.
// ChirpApp renders the menu bar extra (status, model picker, quit).
//
// State machine (AppState.Status):
//
//   ┌──────────────┐   model found   ┌───────────────┐  success  ┌───────┐
//   │ downloading  │───────────────→ │ loadingModel  │─────────→ │ ready │
//   │  (progress)  │                 └───────────────┘  failure  │       │
//   └──────────────┘                         │         ┌────────→│       │
//         │ failure                          ▼         │         └───┬───┘
//         ▼                             ┌────────┐     │     fn press│
//     ┌────────┐                        │ error  │     │            ▼
//     │ error  │                        └────────┘     │     ┌───────────┐
//     └────────┘                                       │     │ recording │
//                                                      │     └─────┬─────┘
//                                                      │     fn release
//                                                      │           ▼
//                                                      │   ┌──────────────┐
//                                                      └───│ transcribing │
//                                                          └──────────────┘

import SwiftUI
import Foundation

// MARK: - AppState

@MainActor
@Observable
public final class AppState {
    public enum Status {
        case downloading(Double)   // 0.0 … 1.0
        case loadingModel
        case ready
        case recording
        case transcribing
        case error(String)
    }

    public var status: Status = .loadingModel
    public var transcribedText: String = ""
    public var speculativeText: String = ""
    public var audioLevel: Float = 0
    let audioRecorder: any AudioRecording
    private(set) var transcriber: any TranscriberProtocol
    let textInserter: any TextInserting
    public var downloadNudge: Bool = false
    var hotkeyManager: HotkeyManager?
    var overlayPanel: OverlayPanel?
    private var modelManager: ModelManager?
    private var peekTask: Task<Void, Never>?
    private var nudgeTask: Task<Void, Never>?
    private var audioConsumerTask: Task<Void, Never>?
    private var audioContinuation: AsyncStream<[Float]>.Continuation?

    /// Monotonically increasing session counter. Incremented each time
    /// startRecording() is called. Checked after every await to discard
    /// work from a previous recording session.
    private var recordingSession: UInt64 = 0

    /// How long the overlay lingers after final text before hiding (nanoseconds).
    /// Injectable for tests.
    var lingerDuration: UInt64 = 800_000_000

    /// Generation counter — incremented each time a committed segment arrives.
    /// Peek previews that were started before the latest commit are discarded.
    private var commitGen = 0

    public convenience init() {
        self.init(audioRecorder: AudioRecorder(), transcriber: Transcriber(), textInserter: TextInserter())
    }

    init(
        audioRecorder: any AudioRecording,
        transcriber: any TranscriberProtocol,
        textInserter: any TextInserting,
        startListening: Bool = true
    ) {
        self.audioRecorder = audioRecorder
        self.transcriber = transcriber
        self.textInserter = textInserter
        guard startListening else { return }
        overlayPanel = OverlayPanel(appState: self)
        hotkeyManager = HotkeyManager(
            onPress: { [weak self] in self?.startRecording() },
            onRelease: { [weak self] in self?.stopRecording() }
        )
        textInserter.checkAccessibilityPermission()
        ensureModel()
    }

    // MARK: - Model lifecycle

    /// If the model is on disk, load it immediately; otherwise download first.
    private func ensureModel() {
        let variant = ModelVariant.tdt
        if let paths = ModelManager.findExisting(variant: variant) {
            loadTranscriber(paths: paths)
            return
        }

        status = .downloading(0)
        overlayPanel?.showOverlay()
        modelManager = ModelManager(
            variant: variant,
            onProgress: { [weak self] progress in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.status = .downloading(progress) }
                }
            },
            onComplete: { [weak self] result in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        switch result {
                        case .success(let paths):
                            self?.loadTranscriber(paths: paths)
                        case .failure(let error):
                            self?.status = .error(error.localizedDescription)
                        }
                        self?.modelManager = nil
                    }
                }
            }
        )
        modelManager?.download()
    }

    func loadTranscriber(paths: ModelPaths) {
        status = .loadingModel
        let transcriber = self.transcriber
        Task { [weak self] in
            let ok = await transcriber.initialize(paths: paths)
            if ok {
                self?.status = .ready
                self?.overlayPanel?.hideOverlay()
                self?.audioRecorder.prepare()
            } else {
                self?.status = .error("Failed to initialize transcriber")
            }
        }
    }

    var modelFileCheck: () -> Bool = {
        ModelManager.findExisting(variant: ModelVariant.tdt) != nil
    }

    // MARK: - Recording

    private func triggerDownloadNudge() {
        nudgeTask?.cancel()
        downloadNudge = true
        nudgeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            self?.downloadNudge = false
        }
    }

    func startRecording() {
        switch status {
        case .downloading, .loadingModel:
            triggerDownloadNudge()
            return
        case .ready:
            break
        default:
            return
        }
        if !modelFileCheck() {
            ensureModel()
            return
        }
        audioConsumerTask?.cancel()
        audioConsumerTask = nil
        transcribedText = ""
        speculativeText = ""
        commitGen = 0
        recordingSession &+= 1
        let session = recordingSession
        status = .recording
        overlayPanel?.showOverlay()

        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        audioContinuation = continuation

        audioRecorder.startRecording { samples in
            continuation.yield(samples)
        }

        let transcriber = self.transcriber
        audioConsumerTask = Task { [weak self] in
            // Guaranteed to run before first feedAudio — no ordering race.
            await transcriber.resetVAD()

            for await samples in stream {
                guard !Task.isCancelled else { break }

                let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1)))
                let level = min(rms * 6, 1)

                let segments = await transcriber.feedAudio(samples: samples)

                // Session guard is sufficient — status may be .transcribing if
                // stopRecording() ran mid-feedAudio, and we must still process
                // those results (the VAD already popped them).
                guard let self, self.recordingSession == session else { break }

                self.audioLevel = level
                for raw in segments {
                    let text = TextPostProcessor.process(raw)
                    guard !text.isEmpty else { continue }
                    self.commitGen += 1
                    self.speculativeText = ""
                    let needsSpace = !self.transcribedText.isEmpty
                    if needsSpace { self.transcribedText += " " }
                    self.transcribedText += text
                    self.textInserter.typeText(needsSpace ? " \(text)" : text)
                }
            }

            // Stream ended (stopRecording finished the continuation).
            // Flush any remaining audio the VAD hasn't emitted yet.
            guard !Task.isCancelled else { return }
            guard let self, self.recordingSession == session else { return }

            let raw = await transcriber.flush()
            guard !Task.isCancelled else { return }
            guard self.recordingSession == session else { return }
            let remaining = TextPostProcessor.process(raw)
            if !remaining.isEmpty {
                let needsSpace = !self.transcribedText.isEmpty
                if needsSpace { self.transcribedText += " " }
                self.transcribedText += remaining
                self.textInserter.typeText(needsSpace ? " \(remaining)" : remaining)
            }
            self.audioLevel = 0
            if !self.transcribedText.isEmpty {
                try? await Task.sleep(nanoseconds: self.lingerDuration)
                guard !Task.isCancelled else { return }
                guard self.recordingSession == session else { return }
            }
            self.status = .ready
            self.overlayPanel?.hideOverlay()
        }

        startPeeking()
    }

    /// Polls the transcriber every 400 ms for a speculative preview of
    /// the current (uncommitted) audio. Discarded if a committed segment
    /// arrives in the meantime (checked via commitGen and recordingSession).
    private func startPeeking() {
        let transcriber = self.transcriber
        let session = recordingSession
        peekTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { break }
                guard let self, self.recordingSession == session else { break }
                guard case .recording = self.status else { break }
                let gen = self.commitGen
                let preview = await transcriber.peekTranscription()
                guard self.recordingSession == session else { break }
                guard case .recording = self.status else { break }
                guard self.commitGen == gen else { continue }
                self.speculativeText = preview.map { TextPostProcessor.process($0) } ?? ""
            }
        }
    }

    func stopRecording() {
        guard case .recording = status else { return }

        peekTask?.cancel()
        peekTask = nil
        // Don't cancel audioConsumerTask — it will process any in-flight
        // feedAudio results, then flush remaining audio after the stream ends.
        audioContinuation?.finish()
        audioContinuation = nil
        audioRecorder.stopRecording()

        status = .transcribing
        speculativeText = ""
    }
}

