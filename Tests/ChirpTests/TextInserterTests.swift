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
}
