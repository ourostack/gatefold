import Foundation
import GatefoldCore
import ReadiumShared
import Testing
@testable import Gatefold

/// A page whose words on screen and whose reported place can part: Readium can report a new page
/// boundary after the layout shifts (page numbers coming on, a number replacing "Counting pages…")
/// while the words he is reading stay where they were.
@MainActor
final class DriftingPage: ReaderPage {
    var currentLocation: Locator?
    /// The words at the top of the page on screen.
    var words: String

    init(at location: Locator, words: String) {
        currentLocation = location
        self.words = words
    }

    @discardableResult func go(to locator: Locator) async -> Bool { currentLocation = locator; return true }
    func go(to link: ReadiumShared.Link) async {}

    func visibleRange() async -> VisibleRange? {
        guard let here = currentLocation else { return nil }
        let start = here.locations.progression ?? 0
        return VisibleRange(href: here.href.string, start: start, end: min(1, start + 0.03), text: words + " and on down the page")
    }

    func progression(of quote: String) async -> Double? { currentLocation?.locations.progression }

    func currentAnchor() async -> (ReadingAnchor, Locator)? {
        guard let here = currentLocation else { return nil }
        let anchor = ReadingAnchor(href: here.href.string, progression: here.locations.progression ?? 0, text: ReaderJS.normalize(words))
        return (anchor, here.copy(text: { $0 = Locator.Text(highlight: self.words) }))
    }

    /// The words the model asked the page to look for again after a late layout (`keepWordsOnPage`).
    var lookedForWords: [ReadingAnchor] = []
    /// Whether each of those looks may place his words as a restore does.
    var placingLooks: [Bool] = []
    func keepWordsOnPage(_ anchor: ReadingAnchor, placing: Bool, stillWanted: @escaping @MainActor () -> Bool) async -> VisibleRange? {
        lookedForWords.append(anchor)
        placingLooks.append(placing)
        return nil
    }
}

/// His place is the page he sees. A report that only the layout brought (after a tap that only
/// showed or hid the controls) never moves the saved place, the running head or "here".
@MainActor @Suite(.serialized) struct LayoutReportTests {
    struct Fixture {
        let model: ReaderModel
        let page: DriftingPage
        let app: AppModel
        let publication: Publication
    }

    static let hisWords = "these are the words at the top of the page he is reading now"
    static let nextWords = "a different page of words that a swipe brought onto the screen"

    /// Frankenstein opened fresh in the middle of one chapter, with no place of the Cloud's.
    static func open() async throws -> Fixture {
        let sync = StubSync()
        await sync.setLibrary(.success([ReaderSyncTests.frankenstein]))
        await sync.setRemote(nil)
        let app = AppModel(sync: sync, libraryRoot: URL.temporaryDirectory.appending(path: "layout-report-\(UUID().uuidString)"))
        await app.library.refresh()
        let publication = try await ReaderSyncTests.publication()
        let book = try #require(app.library.book(ReaderSyncTests.frankenstein.fastHash))
        let href = publication.readingOrder[10].url().string
        let start = Locator(href: try #require(AnyURL(string: href)), mediaType: .xhtml,
                            locations: .init(progression: 0.4, totalProgression: 0.30))
        let page = DriftingPage(at: start, words: hisWords)
        let model = ReaderModel(book: book, publication: publication, app: app, page: page)
        await model.load()
        // Readium's first report: the page the book opened on.
        await model.locationDidChange(start)
        try await Task.sleep(for: .milliseconds(300))
        return Fixture(model: model, page: page, app: app, publication: publication)
    }

    /// Readium's report of the next chapter's first page: a different boundary, a different file.
    static func nextChapter(_ f: Fixture) throws -> Locator {
        let href = f.publication.readingOrder[11].url().string
        return Locator(href: try #require(AnyURL(string: href)), mediaType: .xhtml,
                       locations: .init(progression: 0, totalProgression: 0.33))
    }

    @Test func aLayoutReportAfterATapThatShowedTheControlsKeepsHisPage() async throws {
        let f = try await Self.open()
        let head = f.model.runningHead
        let here = f.model.totalProgression
        let saved = f.app.library.book(ReaderSyncTests.frankenstein.fastHash)?.locatorJSON

        // He taps the middle of the page: the touch, then the controls come up. Nothing turns.
        f.model.noteInteraction()
        f.model.controlsTapped(visible: true)
        // Page numbers come on; the layout shifts and Readium reports a boundary in the next chapter
        // while his words stay on screen.
        f.page.currentLocation = try Self.nextChapter(f)
        await f.model.locationDidChange(f.page.currentLocation!)
        try await Task.sleep(for: .milliseconds(300))

        let after = f.app.library.book(ReaderSyncTests.frankenstein.fastHash)?.locatorJSON
        #expect(after == saved, "a report the layout brought was saved as his place")
        #expect(f.model.runningHead == head, "the running head followed Readium's report, not his page")
        #expect(abs(f.model.totalProgression - here) < 0.0001, "here followed Readium's report, not his page")
        f.model.close()
    }

    @Test func aLayoutReportWithNoTouchKeepsTheRunningHeadOnHisPage() async throws {
        let f = try await Self.open()
        let head = f.model.runningHead
        let here = f.model.totalProgression
        f.page.currentLocation = try Self.nextChapter(f)
        await f.model.locationDidChange(f.page.currentLocation!)
        try await Task.sleep(for: .milliseconds(300))
        #expect(f.model.runningHead == head, "the running head followed Readium's report, not his page")
        #expect(abs(f.model.totalProgression - here) < 0.0001, "here followed Readium's report, not his page")
        f.model.close()
    }

    /// gatefold#482: after a move of his, a reflow's restore puts his words on screen; then Readium lays the page out
    /// again in the new columns and reports its own place, another page with other words, with no move of his. His
    /// words stay his, and the page is asked to put them back: inside the restore's 1.2 s window, and after it (on
    /// CI's loaded iPad the report came 2 s late, and his words were read again from the wrong page).
    @Test(arguments: [false, true]) func aLayoutReportAfterARestoreLooksForHisWordsAgain(late: Bool) async throws {
        let f = try await Self.open()
        // His move: a swipe brings his page.
        f.model.noteInteraction()
        let his = try Self.nextChapter(f)
        f.page.words = Self.nextWords
        f.page.currentLocation = his
        await f.model.locationDidChange(his)
        try await Task.sleep(for: .milliseconds(300))
        let anchor = try #require(f.model.keeper.anchor)
        try #require(anchor.text == ReaderJS.normalize(Self.nextWords), "the swipe's page is his")
        // The iPad turns: a reflow whose restore finds his words on screen.
        f.model.keeper.reflowWillBegin(.rotation)
        f.model.reflowDidBegin()
        f.model.keeper.restoreDidComplete()
        f.model.reflowDidFinish(visible: await f.page.visibleRange())
        if late { try await Task.sleep(for: .milliseconds(1300)) }
        // Readium lays the page out again and keeps its own place: the page after his.
        let after = Locator(href: his.href, mediaType: .xhtml, locations: .init(progression: 0.1, totalProgression: 0.335))
        f.page.words = "the words that start the page after his in the new columns"
        f.page.currentLocation = after
        await f.model.locationDidChange(after)
        for _ in 0..<40 where f.page.lookedForWords.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
        #expect(f.model.keeper.anchor == anchor, "his words were read again from the page the layout moved to")
        #expect(f.page.lookedForWords == [anchor], "his words weren't looked for again on the page the layout moved")
        #expect(f.page.placingLooks == [true], "the look after the restore couldn't place his words as the restore would")
        f.model.close()
    }

    /// gatefold#534: the reflow's check judges his words, never progressions. A page whose text wasn't read is
    /// unproven, not his (build 46's check fell back to Readium's report and the page's end clamped to it); a page
    /// whose text holds other words is a loss, even where the progressions overlap.
    @Test func theReflowCheckJudgesHisWordsNeverProgressions() async throws {
        let f = try await Self.open()
        let anchor = try #require(f.model.keeper.anchor)
        try #require(anchor.text != nil, "his words were read")
        func check(_ visible: VisibleRange) -> String {
            f.model.keeper.reflowWillBegin(.rotation)
            f.model.reflowDidBegin()
            f.model.keeper.restoreDidComplete()
            f.model.reflowDidFinish(visible: visible)
            return f.model.anchorCheck
        }
        let around = (start: anchor.progression - 0.01, end: anchor.progression + 0.02)
        #expect(check(VisibleRange(href: anchor.href, start: around.start, end: around.end, text: nil)).hasPrefix("anchor-unread "),
                "a page with no words read was called his by its progressions")
        #expect(check(VisibleRange(href: anchor.href, start: around.start, end: around.end, text: Self.nextWords)).hasPrefix("anchor-lost "),
                "a page of other words was called his")
        #expect(check(VisibleRange(href: anchor.href, start: 0.9, end: 0.9, text: Self.hisWords)).hasPrefix("anchor-visible "),
                "his words on screen weren't seen, because Readium's report was elsewhere")
        f.model.close()
    }

    /// gatefold#534: the late look's second verdict is for its own reflow only. A look begun for an older reflow, or a
    /// read that missed the page's text, leaves the latest verdict standing.
    @Test func theLateCheckJudgesOnlyItsOwnReflowWithItsWordsRead() async throws {
        let f = try await Self.open()
        let anchor = try #require(f.model.keeper.anchor)
        try #require(anchor.text != nil, "his words were read")
        f.model.keeper.reflowWillBegin(.rotation)
        f.model.reflowDidBegin()
        f.model.keeper.restoreDidComplete()
        f.model.reflowDidFinish(visible: VisibleRange(href: anchor.href, start: 0.9, end: 0.9, text: Self.hisWords))
        let own = f.model.reflowNumber
        try #require(f.model.anchorCheck == "anchor-visible \(own)")
        f.model.rejudgeReflow(VisibleRange(href: anchor.href, start: 0.9, end: 0.9, text: nil), reflow: own)
        #expect(f.model.anchorCheck == "anchor-visible \(own)", "a late read that missed the page's text overturned the verdict")
        f.model.rejudgeReflow(VisibleRange(href: anchor.href, start: 0.9, end: 0.9, text: Self.nextWords), reflow: own - 1)
        #expect(f.model.anchorCheck == "anchor-visible \(own)", "an older reflow's late look overwrote the latest verdict")
        f.model.rejudgeReflow(VisibleRange(href: anchor.href, start: 0.9, end: 0.9, text: Self.nextWords), reflow: own)
        #expect(f.model.anchorCheck == "anchor-lost \(own)", "the late look found his words gone and the check didn't say so")
        f.model.close()
    }

    /// A swipe (slide or scroll mode) is a touch Readium owns: the words change, and that is his move.
    @Test func aSwipeThatBringsNewWordsIsStillHisMove() async throws {
        let f = try await Self.open()
        f.model.noteInteraction()
        let next = try Self.nextChapter(f)
        f.page.words = Self.nextWords
        f.page.currentLocation = next
        await f.model.locationDidChange(next)
        try await Task.sleep(for: .milliseconds(300))
        let saved = f.app.library.book(ReaderSyncTests.frankenstein.fastHash)?.locatorJSON
            .flatMap { try? Locator(jsonString: $0) }
        #expect(saved?.href.string == next.href.string, "the swipe's page was not kept")
        #expect(abs(f.model.totalProgression - 0.33) < 0.0001)
        f.model.close()
    }

    /// Turning into the next chapter, Readium can first name the old one with the new page's words on
    /// screen, then correct itself: the correction is his turn's, never the layout's.
    @Test func aTurnReportedFirstInTheOldChapterIsKeptInTheNewOne() async throws {
        let f = try await Self.open()
        let next = try Self.nextChapter(f)
        let old = try #require(f.page.currentLocation)
        f.page.words = Self.nextWords
        f.page.currentLocation = Locator(href: old.href, mediaType: .xhtml, locations: .init(progression: 0.99, totalProgression: 0.32))
        f.model.userTurnedPage()
        try await Task.sleep(for: .milliseconds(200))
        f.page.currentLocation = next
        try await Task.sleep(for: .milliseconds(1500))
        let saved = f.app.library.book(ReaderSyncTests.frankenstein.fastHash)?.locatorJSON
            .flatMap { try? Locator(jsonString: $0) }
        #expect(saved?.href.string == next.href.string, "the turn's corrected place was taken for the layout's")
        f.model.close()
    }

    /// A turn is always his, whatever came before it.
    @Test func aTurnAfterTheControlsIsStillHisMove() async throws {
        let f = try await Self.open()
        f.model.noteInteraction()
        f.model.controlsTapped(visible: true)
        f.model.controlsTapped(visible: false)
        let next = try Self.nextChapter(f)
        f.page.words = Self.nextWords
        f.page.currentLocation = next
        f.model.userTurnedPage()
        try await Task.sleep(for: .milliseconds(1200))
        let saved = f.app.library.book(ReaderSyncTests.frankenstein.fastHash)?.locatorJSON
            .flatMap { try? Locator(jsonString: $0) }
        #expect(saved?.href.string == next.href.string, "the turn's page was not kept")
        f.model.close()
    }
}
