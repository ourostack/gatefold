import Testing
@testable import GatefoldCore

/// A book's page count lays its chapters out in six web views behind the page. Three books warm behind
/// the shelf counted at once on CI's iPad (13, 17 and 32 chapters, 168 to 219 s each, overlapping), and
/// the app stopped answering a UI query until it timed out (gatefold#113, job 129506115262).
@MainActor
private final class Book {
    let name: String
    var started = 0
    var yielded = 0
    init(_ name: String) { self.name = name }
}

@MainActor
private func ask(_ turns: CountingTurns, _ book: Book, opened: Bool = false) {
    turns.ask(book, opened: opened, start: { book.started += 1 }, yield: { book.yielded += 1 })
}

@MainActor
struct CountingTurnsTests {
    @Test func booksBehindTheShelfCountOneAfterAnother() {
        let turns = CountingTurns()
        let a = Book("a"), b = Book("b"), c = Book("c")
        ask(turns, a); ask(turns, b); ask(turns, c)
        #expect([a.started, b.started, c.started] == [1, 0, 0])
        turns.done(a)
        #expect([b.started, c.started] == [1, 0])
        turns.done(b)
        #expect(c.started == 1)
        #expect(turns.counting == ObjectIdentifier(c))
        turns.done(c)
        #expect(turns.counting == nil)
    }

    @Test func theBookHeTappedCountsFirstAndTheWarmOneWaits() {
        let turns = CountingTurns()
        let warm = Book("warm"), tapped = Book("tapped")
        ask(turns, warm)
        ask(turns, tapped)
        #expect(tapped.started == 0)
        // He taps the second warm book: its count goes ahead, and the one counting gives way.
        turns.opened(tapped)
        #expect(warm.yielded == 1)
        #expect(tapped.started == 1)
        #expect(turns.counting == ObjectIdentifier(tapped))
        // The one that gave way takes its turn again afterwards, from where it got to.
        turns.done(tapped)
        #expect(warm.started == 2)
    }

    @Test func anOpenedBooksAskGoesAheadOfTheWaitingWarmOnes() {
        let turns = CountingTurns()
        let first = Book("first"), waiting = Book("waiting"), opened = Book("opened")
        ask(turns, first); ask(turns, waiting)
        ask(turns, opened, opened: true)
        #expect(first.yielded == 1)
        #expect(opened.started == 1)
        turns.done(opened)
        // The warm ones in the order they asked: the one that gave way had asked first.
        #expect(first.started == 2)
        #expect(waiting.started == 0)
        turns.done(first)
        #expect(waiting.started == 1)
    }

    @Test func askingAgainWhileCountingStartsAgainAtOnce() {
        // A reflow or a run of turns stops a count and starts it again: the book keeps its turn.
        let turns = CountingTurns()
        let a = Book("a"), b = Book("b")
        ask(turns, a); ask(turns, b)
        ask(turns, a)
        #expect(a.started == 2)
        #expect(b.started == 0)
    }

    @Test func aBookThatGoesWhileWaitingIsNeverStarted() {
        let turns = CountingTurns()
        let a = Book("a"), b = Book("b"), c = Book("c")
        ask(turns, a); ask(turns, b); ask(turns, c)
        turns.done(b)
        turns.done(a)
        #expect(b.started == 0)
        #expect(c.started == 1)
    }

    @Test func aWaitingBooksSecondAskReplacesItsFirst() {
        let turns = CountingTurns()
        let a = Book("a"), b = Book("b")
        ask(turns, a); ask(turns, b); ask(turns, b)
        turns.done(a)
        #expect(b.started == 1)
    }

    @Test func twoOpenedBooksNeverStopEachOther() {
        let turns = CountingTurns()
        let a = Book("a"), b = Book("b")
        ask(turns, a, opened: true)
        ask(turns, b, opened: true)
        #expect(a.yielded == 0)
        #expect(b.started == 0)
        turns.done(a)
        #expect(b.started == 1)
    }
}
