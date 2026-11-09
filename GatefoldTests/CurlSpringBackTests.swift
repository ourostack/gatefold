import Foundation
import ReadiumShared
import Testing
@testable import Gatefold

/// A curl that springs back leaves him on the page he started from. Stepping back a page across a chapter's
/// start lands at the start of the chapter before, not its last page (the Duo, #110 walk run 42512799887: a
/// drag let go on h-4's last page sprang back and the place became h-4 @0.00000).
@MainActor struct CurlSpringBackTests {
    /// Two chapters of five pages; stepping back from a chapter's first page lands at the previous chapter's
    /// first page, as Readium's did.
    @MainActor final class Book {
        var chapter = 0, page = 0
        var location: Locator { Self.locator(chapter, page) }

        static func locator(_ chapter: Int, _ page: Int) -> Locator {
            Locator(href: AnyURL(string: "h-\(chapter + 4).htm.html")!, mediaType: .xhtml,
                    locations: .init(progression: Double(page) / 5))
        }

        func go(to locator: Locator) -> Bool {
            chapter = Int(locator.href.string.dropFirst(2).prefix(while: \.isNumber))! - 4
            page = Int(((locator.locations.progression ?? 0) * 5).rounded())
            return true
        }

        func step(forward: Bool) -> Bool {
            if forward {
                if page < 4 { page += 1 } else if chapter < 1 { chapter += 1; page = 0 } else { return false }
            } else {
                if page > 0 { page -= 1 } else if chapter > 0 { chapter -= 1; page = 0 } else { return false }
            }
            return true
        }
    }

    private func turnAndSpringBack(_ book: Book, forward: Bool) async {
        let start = book.location
        _ = book.step(forward: forward)
        await CurlRelease.springBack(to: start, mirrored: !forward,
                                     go: { book.go(to: $0) }, step: { book.step(forward: $0) })
    }

    @Test func aTurnFromAChaptersLastPageSpringsBackToThatPage() async {
        let book = Book()
        book.chapter = 0; book.page = 4
        await turnAndSpringBack(book, forward: true)
        #expect(book.location == Book.locator(0, 4), "sprang back to \(book.location.href.string) @\(book.location.locations.progression ?? -1)")
    }

    @Test func aTurnInsideAChapterSpringsBackToThatPage() async {
        let book = Book()
        book.chapter = 1; book.page = 2
        await turnAndSpringBack(book, forward: true)
        #expect(book.location == Book.locator(1, 2))
        await turnAndSpringBack(book, forward: false)
        #expect(book.location == Book.locator(1, 2))
    }

    @Test func aTurnBackFromAChaptersFirstPageSpringsBackToThatPage() async {
        let book = Book()
        book.chapter = 1; book.page = 0
        await turnAndSpringBack(book, forward: false)
        #expect(book.location == Book.locator(1, 0))
    }

    /// A turn whose start wasn't read steps back a page, as before.
    @Test func anUnknownStartStepsBack() async {
        let book = Book()
        book.chapter = 1; book.page = 2
        _ = book.step(forward: true)
        await CurlRelease.springBack(to: nil, mirrored: false, go: { book.go(to: $0) }, step: { book.step(forward: $0) })
        #expect(book.location == Book.locator(1, 2))
    }

    /// A jump back that fails falls back to the step.
    @Test func aFailedJumpStepsBack() async {
        let book = Book()
        book.chapter = 1; book.page = 2
        let start = book.location
        _ = book.step(forward: true)
        var tried = false
        await CurlRelease.springBack(to: start, mirrored: false, go: { _ in tried = true; return false }, step: { book.step(forward: $0) })
        #expect(tried)
        #expect(book.location == Book.locator(1, 2))
    }

    /// The jump back lands on the page it was read from, through Readium's rounding: the read starts two pixels
    /// early, and a jump adds a pixel and rounds down to its page (`snapOffset`). The read's start would land a
    /// page early.
    @Test func theJumpBackLandsOnThePageReadThroughReadiumsRounding() {
        let width = 466.0, pages = 37.0, scroll = width * pages
        func read(_ k: Double) -> (s: Double, e: Double) {
            let l = k * width
            return (max(0, (l - 2) / scroll), min(1, (l + width) / scroll))
        }
        func landing(_ progression: Double) -> Double { ((progression * scroll + 1) / width).rounded(.down) }
        for k in [1.0, 2, 18, 35, 36] {
            let r = read(k)
            #expect(landing(CurlRelease.jumpTarget(start: r.s, end: r.e)) == k, "page \(k)")
            #expect(CurlRelease.isOn(CurlRelease.jumpTarget(start: r.s, end: r.e), page: r.s...r.e))
            #expect(!CurlRelease.isOn(CurlRelease.jumpTarget(start: r.s, end: r.e), page: read(k - 1).s...read(k - 1).e))
        }
        #expect(landing(read(18).s) == 17, "the read's own start lands a page early")
    }
    /// The page a spring back left, read live: nil until the reloaded start's document is the one on screen.
    @MainActor final class Reads {
        var answers: [ClosedRange<Double>?]
        var jumps = 0
        init(_ answers: [ClosedRange<Double>?]) { self.answers = answers }
        func read() -> ClosedRange<Double>? { answers.count > 1 ? answers.removeFirst() : answers.first ?? nil }
    }

    /// A file just reloaded can't be read in its own document for a few reads after the jump back lands on it.
    /// Those reads aren't a miss: the check reads again and finds the page, without a second jump (#110 walk
    /// 42536069772: a spring back into a reloaded h-4 took a second jump and 35 s).
    @Test func aPageNotYetReadableIsReadAgainNotJumpedTo() async {
        let reads = Reads([nil, nil, 0.986428...1.0])
        let found = await CurlRelease.confirm(0.993214, read: { reads.read() }, jump: { reads.jumps += 1 })
        #expect(found.page == 0.986428...1.0)
        #expect(!found.jumpedAgain && reads.jumps == 0, "a page it couldn't read yet was taken for a miss")
    }

    /// A page read elsewhere is a miss: one more jump.
    @Test func aPageReadElsewhereTakesOneMoreJump() async {
        let reads = Reads([0.0...0.0135, 0.986428...1.0])
        let found = await CurlRelease.confirm(0.993214, read: { reads.read() }, jump: { reads.jumps += 1 })
        #expect(found.jumpedAgain && reads.jumps == 1)
        #expect(found.page == 0.986428...1.0)
    }

    /// A page that never becomes readable stops after a bounded number of reads and jumps once more, never spins.
    @Test func aPageNeverReadableStopsReadingAndJumpsOnce() async {
        let reads = Reads([nil])
        let found = await CurlRelease.confirm(0.993214, read: { reads.read() }, jump: { reads.jumps += 1 })
        #expect(found.jumpedAgain && reads.jumps == 1)
        #expect(found.reads <= CurlRelease.readsBeforeJumpingAgain * 2 + 2, "read \(found.reads) times")
    }
}
