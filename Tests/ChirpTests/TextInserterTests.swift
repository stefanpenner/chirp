import Testing
@testable import Chirp

@Suite("TextInserter")
@MainActor
struct TextInserterTests {

    @Test("typeText with empty string is a no-op")
    func typeEmptyText() {
        let inserter = MockTextInserter()
        inserter.typeText("")
        #expect(inserter.typedTexts.isEmpty)
    }

    @Test("deleteBackward with count 0 is a no-op")
    func deleteZero() {
        let inserter = MockTextInserter()
        inserter.deleteBackward(count: 0)
        #expect(inserter.deletedCounts.isEmpty)
    }

    @Test("typeText records non-empty text")
    func typeNonEmpty() {
        let inserter = MockTextInserter()
        inserter.typeText("hello")
        #expect(inserter.typedTexts == ["hello"])
    }

    @Test("deleteBackward records positive count")
    func deletePositive() {
        let inserter = MockTextInserter()
        inserter.deleteBackward(count: 3)
        #expect(inserter.deletedCounts == [3])
    }

    @Test("selectBackward records positive count; zero is no-op")
    func selectBackward() {
        let inserter = MockTextInserter()
        inserter.selectBackward(count: 0)
        #expect(inserter.selectBackwardCounts.isEmpty)
        inserter.selectBackward(count: 5)
        #expect(inserter.selectBackwardCounts == [5])
    }

    @Test("selectForward records positive count; zero is no-op")
    func selectForward() {
        let inserter = MockTextInserter()
        inserter.selectForward(count: 0)
        #expect(inserter.selectForwardCounts.isEmpty)
        inserter.selectForward(count: 4)
        #expect(inserter.selectForwardCounts == [4])
    }

    @Test("selectAll records call")
    func selectAll() {
        let inserter = MockTextInserter()
        #expect(!inserter.selectAllCalled)
        inserter.selectAll()
        #expect(inserter.selectAllCalled)
    }

    @Test("moveWord records direction")
    func moveWord() {
        let inserter = MockTextInserter()
        inserter.moveWord(direction: .left)
        inserter.moveWord(direction: .right)
        #expect(inserter.moveWordDirections == [.left, .right])
    }

    @Test("moveLine records up/down direction")
    func moveLine() {
        let inserter = MockTextInserter()
        inserter.moveLine(direction: .up)
        inserter.moveLine(direction: .down)
        #expect(inserter.moveLineDirections == [.up, .down])
    }

    @Test("moveToLineStart / moveToLineEnd record calls")
    func moveToLineEdges() {
        let inserter = MockTextInserter()
        #expect(!inserter.moveToLineStartCalled)
        #expect(!inserter.moveToLineEndCalled)
        inserter.moveToLineStart()
        inserter.moveToLineEnd()
        #expect(inserter.moveToLineStartCalled)
        #expect(inserter.moveToLineEndCalled)
    }

    @Test("moveToDocumentStart / moveToDocumentEnd record calls")
    func moveToDocumentEdges() {
        let inserter = MockTextInserter()
        #expect(!inserter.moveToDocumentStartCalled)
        #expect(!inserter.moveToDocumentEndCalled)
        inserter.moveToDocumentStart()
        inserter.moveToDocumentEnd()
        #expect(inserter.moveToDocumentStartCalled)
        #expect(inserter.moveToDocumentEndCalled)
    }

    @Test("scrollPage records up/down direction")
    func scrollPage() {
        let inserter = MockTextInserter()
        inserter.scrollPage(direction: .up)
        inserter.scrollPage(direction: .down)
        #expect(inserter.scrollPageDirections == [.up, .down])
    }

    @Test("moveBackward / moveForward record positive counts; zero is no-op")
    func moveByCount() {
        let inserter = MockTextInserter()
        inserter.moveBackward(count: 0)
        inserter.moveForward(count: 0)
        #expect(inserter.moveBackwardCounts.isEmpty)
        #expect(inserter.moveForwardCounts.isEmpty)
        inserter.moveBackward(count: 4)
        inserter.moveForward(count: 2)
        #expect(inserter.moveBackwardCounts == [4])
        #expect(inserter.moveForwardCounts == [2])
    }

    @Test("applyFormat records bold / italic / underline")
    func applyFormat() {
        let inserter = MockTextInserter()
        inserter.applyFormat(.bold)
        inserter.applyFormat(.italic)
        inserter.applyFormat(.underline)
        #expect(inserter.appliedFormats == [.bold, .italic, .underline])
    }

    @Test("cutSelection records call")
    func cutSelection() {
        let inserter = MockTextInserter()
        #expect(inserter.cutCallCount == 0)
        inserter.cutSelection()
        #expect(inserter.cutCallCount == 1)
    }

    @Test("pressEscape records call")
    func pressEscape() {
        let inserter = MockTextInserter()
        #expect(inserter.pressEscapeCallCount == 0)
        inserter.pressEscape()
        #expect(inserter.pressEscapeCallCount == 1)
    }

    @Test("pressUndo records call")
    func pressUndo() {
        let inserter = MockTextInserter()
        #expect(inserter.pressUndoCallCount == 0)
        inserter.pressUndo()
        #expect(inserter.pressUndoCallCount == 1)
    }

    @Test("pressRedo records call")
    func pressRedo() {
        let inserter = MockTextInserter()
        #expect(inserter.pressRedoCallCount == 0)
        inserter.pressRedo()
        #expect(inserter.pressRedoCallCount == 1)
    }

    @Test("pressForwardDelete records call")
    func pressForwardDelete() {
        let inserter = MockTextInserter()
        #expect(inserter.pressForwardDeleteCallCount == 0)
        inserter.pressForwardDelete()
        #expect(inserter.pressForwardDeleteCallCount == 1)
    }

    @Test("selectWord records direction")
    func selectWord() {
        let inserter = MockTextInserter()
        inserter.selectWord(direction: .left)
        inserter.selectWord(direction: .right)
        #expect(inserter.selectWordDirections == [.left, .right])
    }

    @Test("deleteWord records direction")
    func deleteWord() {
        let inserter = MockTextInserter()
        inserter.deleteWord(direction: .left)
        inserter.deleteWord(direction: .right)
        #expect(inserter.deleteWordDirections == [.left, .right])
    }

    @Test("steps maps newlines to return keys")
    func newlineSteps() {
        #expect(TextInserter.steps(for: "") == [])
        #expect(TextInserter.steps(for: "hello") == [.text("hello")])
        #expect(TextInserter.steps(for: "a\nb") == [.text("a"), .returnKey, .text("b")])
        #expect(TextInserter.steps(for: "a\n\nb") == [
            .text("a"), .returnKey, .returnKey, .text("b")
        ])
        #expect(TextInserter.steps(for: "\n") == [.returnKey])
    }
}
