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
}
