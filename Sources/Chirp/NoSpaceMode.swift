// NoSpaceMode.swift — Sticky no-space mode for dictation segment joins.
// Pure mode label; session stickiness lives in AppState.
// Dual-tested against specs/NoSpaceMode.tla.
// Does NOT pack letters (that is SpellMode) — only empty separators between segments.

import Foundation

/// Sticky no-space mode for newly committed segments.
enum NoSpaceMode: Equatable, Sendable {
    /// Normal dictation spacing between segments.
    case off
    /// Join multi-segment commits with no separator (compound words across VAD splits).
    case on

    /// Short HUD label when mode is active; nil when off (hide badge).
    var overlayLabel: String? {
        switch self {
        case .off: return nil
        case .on: return "no space"
        }
    }

    var isOn: Bool { self == .on }
}
