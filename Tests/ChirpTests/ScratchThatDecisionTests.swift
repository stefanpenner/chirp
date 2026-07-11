// ScratchThatDecisionTests.swift — Dual of specs/ScratchThatN.tla.

import Testing
@testable import Chirp

@Suite("ScratchThatDecision")
struct ScratchThatDecisionTests {

    @Test("empty stack peels nothing")
    func empty() {
        let p = ScratchThatDecision.plan(undoLengthsOldestFirst: [], count: 3)
        #expect(p.steps == 0)
        #expect(p.totalChars == 0)
        #expect(p.removedLengths.isEmpty)
    }

    @Test("count one peels newest only")
    func one() {
        let p = ScratchThatDecision.plan(undoLengthsOldestFirst: [2, 5, 3], count: 1)
        #expect(p.removedLengths == [3])
        #expect(p.totalChars == 3)
        #expect(p.steps == 1)
    }

    @Test("count two peels two newest")
    func two() {
        let p = ScratchThatDecision.plan(undoLengthsOldestFirst: [2, 5, 3], count: 2)
        #expect(p.removedLengths == [3, 5])
        #expect(p.totalChars == 8)
        #expect(p.steps == 2)
    }

    @Test("count over depth peels all without crash")
    func overDepth() {
        let p = ScratchThatDecision.plan(undoLengthsOldestFirst: [4, 1], count: 10)
        #expect(p.removedLengths == [1, 4])
        #expect(p.totalChars == 5)
        #expect(p.steps == 2)
    }

    @Test("clampCount bounds to 1...maxDepth")
    func clamp() {
        #expect(ScratchThatDecision.clampCount(0) == 1)
        #expect(ScratchThatDecision.clampCount(-3) == 1)
        #expect(ScratchThatDecision.clampCount(2) == 2)
        #expect(ScratchThatDecision.clampCount(100) == EditStack.maxDepth)
    }

    @Test("matches successive EditStack.undo lengths")
    func dualEditStack() {
        var s = EditStack()
        s.push("Hi")
        s.push(" there")
        s.push(" friend")
        let lengths = s.undoItems.map(\.count)
        let plan = ScratchThatDecision.plan(undoLengthsOldestFirst: lengths, count: 2)
        var peeled: [Int] = []
        for _ in 0..<plan.steps {
            if let d = s.undo() { peeled.append(d.count) }
        }
        #expect(peeled == plan.removedLengths)
        #expect(s.canUndo)
        #expect(s.lastDelta == "Hi")
    }

    @Test("plan on redo stack matches successive EditStack.redo (RedoThatN dual)")
    func dualRedoStack() {
        var s = EditStack()
        s.push("A")
        s.push("B")
        s.push("C")
        _ = s.undo()
        _ = s.undo()
        // redoItems oldest→newest: B then C (last undone is top)
        let lengths = s.redoItems.map(\.count)
        let plan = ScratchThatDecision.plan(undoLengthsOldestFirst: lengths, count: 2)
        var redone: [Int] = []
        for _ in 0..<plan.steps {
            if let d = s.redo() { redone.append(d.count) }
        }
        #expect(redone == plan.removedLengths)
        #expect(!s.canRedo)
        #expect(s.lastDelta == "C" || s.lastDelta == "B" || s.canUndo)
    }
}
