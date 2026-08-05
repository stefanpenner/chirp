// AppStatusDecisionTests.swift — Dual-test pure gates against AppStatus.tla.

import Testing
@testable import Chirp

@Suite("AppStatusDecision (TLA+ dual)")
struct AppStatusDecisionTests {

    @Test("kind mapping strips payloads")
    func kindMapping() {
        #expect(AppStatusDecision.kind(from: .needsModel) == .needsModel)
        #expect(AppStatusDecision.kind(from: .downloading(0.4)) == .downloading)
        #expect(AppStatusDecision.kind(from: .loadingModel) == .loadingModel)
        #expect(AppStatusDecision.kind(from: .ready) == .ready)
        #expect(AppStatusDecision.kind(from: .recording) == .recording)
        #expect(AppStatusDecision.kind(from: .transcribing) == .transcribing)
        #expect(AppStatusDecision.kind(from: .error("x")) == .error)
    }

    @Test("Retry download only from needsModel or error")
    func retryDownload() {
        #expect(AppStatusDecision.canRetryDownload(.needsModel))
        #expect(AppStatusDecision.canRetryDownload(.error))
        #expect(!AppStatusDecision.canRetryDownload(.downloading))
        #expect(!AppStatusDecision.canRetryDownload(.loadingModel))
        #expect(!AppStatusDecision.canRetryDownload(.ready))
        #expect(!AppStatusDecision.canRetryDownload(.recording))
        #expect(!AppStatusDecision.canRetryDownload(.transcribing))
    }

    @Test("Cancel download only while downloading")
    func cancelDownload() {
        #expect(AppStatusDecision.canCancelDownload(.downloading))
        #expect(!AppStatusDecision.canCancelDownload(.needsModel))
        #expect(!AppStatusDecision.canCancelDownload(.error))
        #expect(!AppStatusDecision.canCancelDownload(.ready))
    }

    @Test("Nudge instead of record while downloading or loading")
    func nudge() {
        #expect(AppStatusDecision.shouldNudgeInsteadOfRecord(.downloading))
        #expect(AppStatusDecision.shouldNudgeInsteadOfRecord(.loadingModel))
        #expect(!AppStatusDecision.shouldNudgeInsteadOfRecord(.ready))
        #expect(!AppStatusDecision.shouldNudgeInsteadOfRecord(.needsModel))
    }

    @Test("Hotkey starts download/retry from needsModel or error")
    func hotkeyDownload() {
        #expect(AppStatusDecision.shouldStartDownloadOnHotkey(.needsModel))
        #expect(AppStatusDecision.shouldStartDownloadOnHotkey(.error))
        #expect(!AppStatusDecision.shouldStartDownloadOnHotkey(.ready))
        #expect(!AppStatusDecision.shouldStartDownloadOnHotkey(.downloading))
    }

    @Test("Session entry only from ready; rejoin from transcribing")
    func sessionEntry() {
        #expect(AppStatusDecision.canEnterSession(.ready))
        #expect(!AppStatusDecision.canEnterSession(.downloading))
        #expect(!AppStatusDecision.canEnterSession(.error))
        #expect(!AppStatusDecision.canEnterSession(.recording))
        #expect(AppStatusDecision.canRejoinSession(.transcribing))
        #expect(!AppStatusDecision.canRejoinSession(.ready))
    }

    @Test("Overlay visibility dual of AppStatus overlay invariants")
    func overlayVisibility() {
        #expect(AppStatusDecision.shouldShowOverlay(.downloading))
        #expect(AppStatusDecision.shouldShowOverlay(.recording))
        #expect(AppStatusDecision.shouldShowOverlay(.transcribing))
        #expect(AppStatusDecision.shouldShowOverlay(.error))
        #expect(!AppStatusDecision.shouldShowOverlay(.ready))
        #expect(!AppStatusDecision.shouldShowOverlay(.needsModel))
        // loadingModel may or may not show (Init false; post-download true)
        #expect(!AppStatusDecision.shouldShowOverlay(.loadingModel))
    }

    @Test("Status labels for boot/error; nil for session/ready")
    func labels() {
        #expect(AppStatusDecision.statusLabel(.needsModel) != nil)
        #expect(AppStatusDecision.statusLabel(.downloading) != nil)
        #expect(AppStatusDecision.statusLabel(.error) != nil)
        #expect(AppStatusDecision.statusLabel(.ready) == nil)
        #expect(AppStatusDecision.statusLabel(.recording) == nil)
    }
}
