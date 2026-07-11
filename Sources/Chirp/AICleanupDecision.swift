// AICleanupDecision.swift — Pure scope resolution for on-demand AI cleanup.
// Dual of tests in AICleanupDecisionTests. No I/O.

import Foundation

/// Which span of the session buffer to clean.
enum AICleanupScope: Equatable, Sendable {
    /// Active session selection (select that / select X / …).
    case selection(start: Int, length: Int, text: String)
    /// Last typed stack delta, when it is still a trailing suffix of the buffer.
    case lastPhrase(text: String)
    /// Whole session buffer.
    case fullBuffer(text: String)
    /// Nothing to clean.
    case empty
}

enum AICleanupDecision {
    /// Prefer selection → last phrase (if still a suffix) → full buffer.
    static func resolve(
        buffer: String,
        selectionStart: Int?,
        selectionLength: Int?,
        lastDelta: String?
    ) -> AICleanupScope {
        if let start = selectionStart,
           let length = selectionLength,
           length > 0,
           start >= 0,
           start + length <= buffer.count {
            let idx = buffer.index(buffer.startIndex, offsetBy: start)
            let end = buffer.index(idx, offsetBy: length)
            let text = String(buffer[idx..<end])
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .selection(start: start, length: length, text: text)
            }
        }

        if let delta = lastDelta, !delta.isEmpty, buffer.hasSuffix(delta) {
            let trimmed = delta.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return .lastPhrase(text: delta)
            }
        }

        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return .fullBuffer(text: buffer)
        }

        return .empty
    }

    /// Whether cleanup should rewrite the host (text already typed there).
    /// Always true for menu/hotkey after typing; for mid-session batch mode,
    /// host may not have the text yet.
    static func shouldRewriteHost(typesIncrementally: Bool) -> Bool {
        typesIncrementally
    }
}
