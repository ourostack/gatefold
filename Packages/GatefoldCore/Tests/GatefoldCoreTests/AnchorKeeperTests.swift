import Testing
@testable import GatefoldCore

/// A stand-in for the web view: one chapter of `length` characters, laid out `perPage` characters
/// to a page and `pagesPerScreen` pages side by side. Like Readium after a reflow, it reopens at
/// the old *progression*, which drifts when the page size changes.
private struct FakeBook {
    let href = "chapter-7.xhtml"
    let length = 60_000
    var perPage: Int
    var pagesPerScreen: Int
    var firstPage = 0

    var visible: VisibleRange {
        let start = firstPage * perPage
        let end = min(length, (firstPage + pagesPerScreen) * perPage)
        return VisibleRange(href: href, start: Double(start) / Double(length), end: Double(end) / Double(length))
    }

    func anchor(atCharacter c: Int) -> ReadingAnchor {
        ReadingAnchor(href: href, progression: Double(c) / Double(length), text: "char-\(c)")
    }

    /// The first visible character, as Readium's first-visible-element locator reports it.
    var firstVisibleAnchor: ReadingAnchor { anchor(atCharacter: firstPage * perPage) }

    /// Reflow the way Readium does: keep the progression of the screen's start, snapped to a screen.
    mutating func reflow(perPage: Int, pagesPerScreen: Int) {
        let progression = visible.start
        self.perPage = perPage
        self.pagesPerScreen = pagesPerScreen
        let page = Int(progression * Double(length)) / perPage
        firstPage = (page / pagesPerScreen) * pagesPerScreen
        // Readium's known drift (#645): it lands one screen early after a reflow.
        firstPage = max(0, firstPage - pagesPerScreen)
    }

    mutating func jump(to anchor: ReadingAnchor) {
        let c = Int(anchor.progression * Double(length))
        let page = c / perPage
        firstPage = (page / pagesPerScreen) * pagesPerScreen
    }

    mutating func turn() { firstPage += pagesPerScreen }
}

@Suite("The reading anchor holds the place through every reflow")
struct AnchorKeeperTests {
    /// Runs one layout change through the keeper and the fake book, the way ReaderHost does.
    private func change(_ book: inout FakeBook, _ keeper: inout AnchorKeeper, perPage: Int, pagesPerScreen: Int, reason: ReflowReason) {
        keeper.reflowWillBegin(reason)
        book.reflow(perPage: perPage, pagesPerScreen: pagesPerScreen)
        // Readium reports a location while settling; the keeper must not take it as the new place.
        keeper.userSettled(on: book.firstVisibleAnchor)
        if case let .jump(anchor) = keeper.reflowDidSettle(visible: book.visible) {
            book.jump(to: anchor)
        }
        keeper.restoreDidComplete()
    }

    private func readTo(page: Int, _ book: inout FakeBook, _ keeper: inout AnchorKeeper) {
        for _ in 0..<page { book.turn() }
        keeper.userSettled(on: book.firstVisibleAnchor)
    }

    @Test func unfoldingFromOnePageToASpreadKeepsTheAnchorOnScreen() {
        var book = FakeBook(perPage: 900, pagesPerScreen: 1)
        var keeper = AnchorKeeper()
        readTo(page: 23, &book, &keeper)
        let anchor = try! #require(keeper.anchor)
        change(&book, &keeper, perPage: 1100, pagesPerScreen: 2, reason: .posture)
        #expect(book.visible.contains(anchor))
    }

    @Test func foldingBackShowsThePageThatHoldsTheAnchor() {
        var book = FakeBook(perPage: 1100, pagesPerScreen: 2)
        var keeper = AnchorKeeper()
        readTo(page: 9, &book, &keeper)
        let anchor = try! #require(keeper.anchor)
        change(&book, &keeper, perPage: 900, pagesPerScreen: 1, reason: .posture)
        #expect(book.visible.contains(anchor))
    }

    @Test func aRoundTripThroughEveryPostureAndAFontChangeNeverLosesThePlace() {
        var book = FakeBook(perPage: 900, pagesPerScreen: 1)
        var keeper = AnchorKeeper()
        readTo(page: 31, &book, &keeper)
        let anchor = try! #require(keeper.anchor)
        let steps: [(Int, Int, ReflowReason)] = [
            (1100, 2, .posture), // unfold to a spread
            (1300, 1, .posture), // tabletop: one page above the fold
            (1100, 2, .posture), // back to flat
            (700, 2, .typography), // bigger font on the spread
            (600, 1, .rotation), // rotate
            (500, 1, .posture), // fold shut
        ]
        for (perPage, screen, reason) in steps {
            change(&book, &keeper, perPage: perPage, pagesPerScreen: screen, reason: reason)
            #expect(book.visible.contains(anchor), "lost the anchor after \(reason)")
            #expect(keeper.anchor == anchor, "the anchor itself drifted after \(reason)")
        }
    }

    @Test func noJumpWhenTheReflowAlreadyShowsTheAnchor() {
        var keeper = AnchorKeeper()
        let anchor = ReadingAnchor(href: "a.xhtml", progression: 0.40, text: "It was")
        keeper.userSettled(on: anchor)
        keeper.reflowWillBegin(.typography)
        let action = keeper.reflowDidSettle(visible: VisibleRange(href: "a.xhtml", start: 0.38, end: 0.45))
        #expect(action == .none)
    }

    @Test func theAnchorHoldsUntilTheRestoreCompletesEvenWithoutAJump() {
        // An unfold can still move the spread (to keep the sentence on the left page) after a settle
        // that needed no jump; the pages it passes on the way are not the reader's place.
        var keeper = AnchorKeeper()
        let anchor = ReadingAnchor(href: "a.xhtml", progression: 0.40, text: "It was")
        keeper.userSettled(on: anchor)
        keeper.reflowWillBegin(.posture)
        #expect(keeper.reflowDidSettle(visible: VisibleRange(href: "a.xhtml", start: 0.38, end: 0.45)) == .none)
        keeper.userSettled(on: ReadingAnchor(href: "a.xhtml", progression: 0.36, text: "tom of your"))
        #expect(keeper.anchor == anchor)
        keeper.restoreDidComplete()
        let next = ReadingAnchor(href: "a.xhtml", progression: 0.45, text: nil)
        keeper.userSettled(on: next)
        #expect(keeper.anchor == next)
    }

    @Test func aTurnAfterTheRestoreMovesTheAnchorAgain() {
        var keeper = AnchorKeeper()
        keeper.userSettled(on: ReadingAnchor(href: "a.xhtml", progression: 0.40, text: nil))
        keeper.reflowWillBegin(.rotation)
        _ = keeper.reflowDidSettle(visible: VisibleRange(href: "a.xhtml", start: 0.1, end: 0.2))
        keeper.restoreDidComplete()
        let next = ReadingAnchor(href: "a.xhtml", progression: 0.45, text: nil)
        keeper.userSettled(on: next)
        #expect(keeper.anchor == next)
    }

    /// The 12 s watchdog shows a page whose reflow never settled and runs the restore again. He turns in
    /// that window: his turn wins. The restore that began before it gives way and never brings the old
    /// place back, and his page becomes the anchor (Ari: "fucked my location with accidental navigation").
    @Test func aTurnDuringTheWatchdogWindowWinsOverTheRestore() {
        var keeper = AnchorKeeper()
        let old = ReadingAnchor(href: "a.xhtml", progression: 0.40, text: "It was")
        keeper.userSettled(on: old)
        keeper.reflowWillBegin(.rotation, move: 3)
        #expect(keeper.restoreMayMove(move: 3))
        // He turns: the model counts his move.
        #expect(!keeper.restoreMayMove(move: 4), "a restore begun before his turn still moved the page")
        keeper.restoreGaveWay()
        #expect(keeper.reflowing == nil)
        let his = ReadingAnchor(href: "a.xhtml", progression: 0.47, text: "words-47")
        keeper.userSettled(on: his)
        #expect(keeper.anchor == his)
        #expect(keeper.reflowDidSettle(visible: VisibleRange(href: "a.xhtml", start: 0.46, end: 0.52)) == .none)
    }

    @Test func anAnchorInAnotherChapterAlwaysJumps() {
        var keeper = AnchorKeeper()
        let anchor = ReadingAnchor(href: "b.xhtml", progression: 0.0, text: nil)
        keeper.userSettled(on: anchor)
        keeper.reflowWillBegin(.posture)
        #expect(keeper.reflowDidSettle(visible: VisibleRange(href: "a.xhtml", start: 0.9, end: 1.0)) == .jump(anchor))
    }

    @Test func visibleTextBeatsProgressionWhenTheWebViewReportsIt() {
        var keeper = AnchorKeeper()
        let anchor = ReadingAnchor(href: "a.xhtml", progression: 0.40, text: "the whale")
        keeper.userSettled(on: anchor)
        keeper.reflowWillBegin(.posture)
        let visible = VisibleRange(href: "a.xhtml", start: 0.41, end: 0.46, text: "…and there was the whale, rising…")
        #expect(keeper.reflowDidSettle(visible: visible) == .none)
    }
}

@Suite struct AnchorTextTests {
    let anchor = ReadingAnchor(href: "c.xhtml", progression: 0.40, text: "It is a truth universally")

    @Test func textOnScreenIsKept() {
        let visible = VisibleRange(href: "c.xhtml", start: 0.38, end: 0.41, text: "…in want of a wife. It is a truth universally acknowledged…")
        #expect(visible.contains(anchor))
    }

    @Test func textOffScreenIsLostEvenWhenProgressionOverlaps() {
        let visible = VisibleRange(href: "c.xhtml", start: 0.39, end: 0.42, text: "an entirely different page")
        #expect(!visible.contains(anchor))
    }

    @Test func pageWithoutTextFallsBackToProgression() {
        #expect(VisibleRange(href: "c.xhtml", start: 0.38, end: 0.45, text: nil).contains(anchor))
        #expect(!VisibleRange(href: "c.xhtml", start: 0.45, end: 0.5, text: nil).contains(anchor))
    }

    @Test func anchorOnThePagesLastLineCountsWhenItsOpeningWordsShow() {
        let long = ReadingAnchor(href: "c.xhtml", progression: 0.4, text: "It is a truth universally acknowledged, that a single man in possession")
        let visible = VisibleRange(href: "c.xhtml", start: 0.38, end: 0.40, text: "…the end of the page. It is a truth universally")
        #expect(visible.contains(long))
    }

    @Test func overlappingReflowsKeepTheFirstAnchor() {
        var keeper = AnchorKeeper(anchor: anchor)
        keeper.reflowWillBegin(.posture)
        // A second reflow starts before the first settles; Readium's drifted locations arrive meanwhile.
        keeper.reflowWillBegin(.typography)
        keeper.userSettled(on: ReadingAnchor(href: "c.xhtml", progression: 0.37, text: "drifted"))
        let drifted = VisibleRange(href: "c.xhtml", start: 0.36, end: 0.39, text: "drifted page")
        #expect(keeper.reflowDidSettle(visible: drifted) == .jump(anchor))
        keeper.restoreDidComplete()
        #expect(keeper.anchor == anchor)
    }
}
