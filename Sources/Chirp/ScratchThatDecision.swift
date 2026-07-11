// ScratchThatDecision.swift — Pure multi-scratch plan (Dragon "scratch that N times").
// Dual of specs/ScratchThatN.tla. Peels up to N newest EditStack deltas.

import Foundation

enum ScratchThatDecision {
    /// Plan for undoing up to `count` segments (count ≥ 1). Empty stack → empty plan.
    struct Plan: Equatable, Sendable {
        /// Delta lengths peeled, newest first (order of successive `undo()` calls).
        let removedLengths: [Int]
        var totalChars: Int { removedLengths.reduce(0, +) }
        var steps: Int { removedLengths.count }
    }

    /// Given undo stack lengths oldest→newest, peel min(count, depth) from the top.
    static func plan(undoLengthsOldestFirst: [Int], count: Int) -> Plan {
        let n = max(0, count)
        guard n > 0, !undoLengthsOldestFirst.isEmpty else {
            return Plan(removedLengths: [])
        }
        var stack = undoLengthsOldestFirst
        var removed: [Int] = []
        removed.reserveCapacity(min(n, stack.count))
        for _ in 0..<n {
            guard let top = stack.popLast() else { break }
            removed.append(top)
        }
        return Plan(removedLengths: removed)
    }

    /// Clamp spoken count into a safe execution range (Dragon-style).
    static func clampCount(_ raw: Int) -> Int {
        min(max(raw, 1), EditStack.maxDepth)
    }
}
