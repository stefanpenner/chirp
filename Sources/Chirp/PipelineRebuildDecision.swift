// PipelineRebuildDecision.swift — Pure gate for deferred pipeline rebuild.
// Mirrors specs/PipelineRebuild.tla: never rebuild mid session; apply on idle.

import Foundation

enum PipelineRebuildDecision {
    /// Whether a rebuild request should be deferred (session active).
    static func shouldDefer(phase: SessionPhase?) -> Bool {
        guard let phase else { return false }
        return phase == .recording || phase == .transcribing
    }

    /// Whether a pending rebuild may be applied now (session idle).
    static func canApply(phase: SessionPhase?, pending: Bool) -> Bool {
        pending && !shouldDefer(phase: phase)
    }
}
