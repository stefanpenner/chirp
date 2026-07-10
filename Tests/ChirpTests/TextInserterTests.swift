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
