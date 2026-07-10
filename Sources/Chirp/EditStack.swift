// EditStack.swift — Multi-level undo/redo for typed dictation segments.
// Pure value type; dual-tested against specs/EditStack.tla.
// Each entry is a typed delta (including join separators).

import Foundation

struct EditStack: Equatable, Sendable {
    private(set) var undoItems: [String] = []
    private(set) var redoItems: [String] = []

    /// Max depth to bound memory (Dragon-style multi-step undo).
    static let maxDepth = 32

    var canUndo: Bool { !undoItems.isEmpty }
    var canRedo: Bool { !redoItems.isEmpty }

    /// Most recent typed delta (last phrase), if any.
    var lastDelta: String? { undoItems.last }

    /// Record a newly typed delta. Clears the redo branch.
    mutating func push(_ delta: String) {
        guard !delta.isEmpty else { return }
        undoItems.append(delta)
        if undoItems.count > Self.maxDepth {
            undoItems.removeFirst(undoItems.count - Self.maxDepth)
        }
        redoItems.removeAll()
    }

    /// Pop last undo delta onto redo. Returns the delta to delete from the app.
    mutating func undo() -> String? {
        guard let delta = undoItems.popLast() else { return nil }
        redoItems.append(delta)
        return delta
    }

    /// Pop last redo delta onto undo. Returns the delta to re-type.
    mutating func redo() -> String? {
        guard let delta = redoItems.popLast() else { return nil }
        undoItems.append(delta)
        return delta
    }

    mutating func clear() {
        undoItems.removeAll()
        redoItems.removeAll()
    }

    /// Adjust the undo stack after a trailing suffix was deleted from the buffer
    /// (e.g. "delete last word"). Peels complete or partial top deltas.
    /// On success, replaces the redo branch with `suffix` so "redo that"
    /// can restore the deleted text. Returns false if the stack cannot
    /// explain the suffix — caller should `clear()`.
    @discardableResult
    mutating func dropTrailingSuffix(_ suffix: String) -> Bool {
        guard !suffix.isEmpty else { return true }
        var remaining = suffix
        var newUndo = undoItems
        while !remaining.isEmpty {
            guard let top = newUndo.last else { return false }
            if top == remaining {
                newUndo.removeLast()
                remaining = ""
            } else if top.hasSuffix(remaining) {
                var trimmed = top
                trimmed.removeLast(remaining.count)
                if trimmed.isEmpty {
                    newUndo.removeLast()
                } else {
                    newUndo[newUndo.count - 1] = trimmed
                }
                remaining = ""
            } else if remaining.hasSuffix(top) {
                remaining = String(remaining.dropLast(top.count))
                newUndo.removeLast()
            } else {
                return false
            }
        }
        undoItems = newUndo
        // New edit branch: redo restores exactly the deleted suffix
        redoItems = [suffix]
        return true
    }
}
