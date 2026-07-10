// EditStackTests.swift — Multi-level undo/redo (dual of specs/EditStack.tla).

import Testing
@testable import Chirp

@Suite("EditStack")
struct EditStackTests {

    @Test("empty stack cannot undo or redo")
    func empty() {
        var s = EditStack()
        #expect(!s.canUndo)
        #expect(!s.canRedo)
        #expect(s.undo() == nil)
        #expect(s.redo() == nil)
    }

    @Test("push then undo returns delta and enables redo")
    func pushUndoRedo() {
        var s = EditStack()
        s.push("Hello")
        #expect(s.canUndo)
        #expect(!s.canRedo)

        let undone = s.undo()
        #expect(undone == "Hello")
        #expect(!s.canUndo)
        #expect(s.canRedo)

        let redone = s.redo()
        #expect(redone == "Hello")
        #expect(s.canUndo)
        #expect(!s.canRedo)
    }

    @Test("multi-level undo pops newest first")
    func multiLevel() {
        var s = EditStack()
        s.push("Hello")
        s.push(" world")
        s.push("!")

        #expect(s.undo() == "!")
        #expect(s.undo() == " world")
        #expect(s.undo() == "Hello")
        #expect(s.undo() == nil)
    }

    @Test("multi-level redo restores newest scratched first")
    func multiRedo() {
        var s = EditStack()
        s.push("A")
        s.push("B")
        s.push("C")
        _ = s.undo() // C
        _ = s.undo() // B
        #expect(s.redo() == "B")
        #expect(s.redo() == "C")
        #expect(s.redo() == nil)
    }

    @Test("new push clears redo branch")
    func pushClearsRedo() {
        var s = EditStack()
        s.push("one")
        s.push("two")
        _ = s.undo()
        #expect(s.canRedo)
        s.push("three")
        #expect(!s.canRedo)
        #expect(s.undo() == "three")
        #expect(s.undo() == "one")
    }

    @Test("empty push is ignored")
    func emptyPushIgnored() {
        var s = EditStack()
        s.push("")
        #expect(!s.canUndo)
    }

    @Test("maxDepth drops oldest entries")
    func maxDepth() {
        var s = EditStack()
        for i in 0..<EditStack.maxDepth + 3 {
            s.push("d\(i)")
        }
        var undos: [String] = []
        while let d = s.undo() {
            undos.append(d)
        }
        #expect(undos.count == EditStack.maxDepth)
        // Newest first; oldest of the retained window is maxDepth+3-maxDepth = 3
        #expect(undos.first == "d\(EditStack.maxDepth + 2)")
        #expect(undos.last == "d3")
    }

    @Test("clear wipes both stacks")
    func clear() {
        var s = EditStack()
        s.push("x")
        s.push("y")
        _ = s.undo()
        s.clear()
        #expect(!s.canUndo)
        #expect(!s.canRedo)
    }

    @Test("undo/redo round-trip preserves stack order")
    func roundTrip() {
        var s = EditStack()
        s.push("Hello")
        s.push(" world")
        // Simulate double scratch then double redo → original stack
        _ = s.undo()
        _ = s.undo()
        _ = s.redo()
        _ = s.redo()
        #expect(s.undo() == " world")
        #expect(s.undo() == "Hello")
    }
}
