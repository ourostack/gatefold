import Testing
@testable import GatefoldCore

@Suite struct WordEdgeTests {
    @Test func finishesTheWord() {
        let r = WordEdge.complete(highlight: "a bow of superior courtesy, to compli", after: "ment him on")
        #expect(r.highlight == "a bow of superior courtesy, to compliment")
        #expect(r.after == " him on")
    }

    @Test func leavesAWholeWordAlone() {
        let r = WordEdge.complete(highlight: "to compliment", after: " him")
        #expect(r.highlight == "to compliment")
        #expect(r.after == " him")
    }

    @Test func leavesPunctuationAlone() {
        #expect(WordEdge.complete(highlight: "courtesy,", after: "to").highlight == "courtesy,")
    }

    @Test func noAfterText() {
        #expect(WordEdge.complete(highlight: "compli", after: nil).highlight == "compli")
    }

    @Test func keepsAnApostrophe() {
        #expect(WordEdge.complete(highlight: "Elizabeth", after: "’s eyes").highlight == "Elizabeth’s")
    }
}
