import Foundation
import GatefoldCore
import ReadiumShared
import Testing
@testable import Gatefold

/// A page Readium has just reloaded: it reports the file's start while the page on screen, read live, is
/// the file's last page (gatefold#128: a backward turn across files after a reload).
@MainActor
final class ReloadedPage: ReaderPage {
    var currentLocation: Locator?
    /// The page on screen, read live (`pageRange`): where the words really are.
    var live: VisibleRange?
    /// The first words on the page on screen, read live; nil when the page gives none.
    var words: String? = "words at the top of the page on screen"

    init(at location: Locator) { currentLocation = location }

    @discardableResult func go(to locator: Locator) async -> Bool { currentLocation = locator; return true }
    func go(to link: ReadiumShared.Link) async {}

    func visibleRange() async -> VisibleRange? {
        guard let here = currentLocation else { return nil }
        let start = here.locations.progression ?? 0
        return VisibleRange(href: here.href.string, start: start, end: min(1, start + 0.014), text: "words on the page")
    }

    /// Holds the next live read until `release()`: a report Readium sends meanwhile is in, before the turn reads.
    var holdNextPageRange = false
    private(set) var held: CheckedContinuation<Void, Never>?

    func pageRange() async -> VisibleRange? {
        if holdNextPageRange {
            holdNextPageRange = false
            await withCheckedContinuation { held = $0 }
        }
        return live
    }

    func release() { held?.resume(); held = nil }

    func progression(of quote: String) async -> Double? { currentLocation?.locations.progression }

    func currentAnchor() async -> (ReadingAnchor, Locator)? {
        guard let here = currentLocation else { return nil }
        // As the app's: the words are read from the screen, the progression is Readium's report.
        return (ReadingAnchor(href: here.href.string, progression: here.locations.progression ?? 0, text: words),
                here.copy(text: { $0 = Locator.Text(highlight: self.words) }))
    }
}

@MainActor @Suite(.serialized) struct TurnAfterReloadTests {
    @MainActor struct Turn {
        let app: AppModel, model: ReaderModel, page: ReloadedPage
        let previous: String, next: String
        func saved() -> Locator? {
            app.library.book(ReaderSyncTests.frankenstein.fastHash)?.locatorJSON.flatMap { try? Locator(jsonString: $0) }
        }
    }

    /// A reader open at a chapter's first page (`next`), its place kept; `previous` is the chapter before.
    private func opened() async throws -> Turn {
        let sync = StubSync()
        await sync.setLibrary(.success([ReaderSyncTests.frankenstein]))
        await sync.setRemote(nil)
        let app = AppModel(sync: sync, libraryRoot: URL.temporaryDirectory.appending(path: "turn-reload-\(UUID().uuidString)"))
        await app.library.refresh()
        let publication = try await ReaderSyncTests.publication()
        let book = try #require(app.library.book(ReaderSyncTests.frankenstein.fastHash))
        let next = publication.readingOrder[11].url().string
        let previous = publication.readingOrder[10].url().string
        let opening = Locator(href: try #require(AnyURL(string: next)), mediaType: .xhtml,
                              locations: .init(progression: 0, totalProgression: 0.33))
        let page = ReloadedPage(at: opening)
        let model = ReaderModel(book: book, publication: publication, app: app, page: page)
        await model.load()
        await model.locationDidChange(opening)
        try await Task.sleep(for: .milliseconds(300))
        return Turn(app: app, model: model, page: page, previous: previous, next: next)
    }

    /// The turn back: Readium names the previous chapter's start; the screen shows its last page.
    private func turnBack(_ t: Turn, words: String?) throws -> Locator {
        let start = Locator(href: try #require(AnyURL(string: t.previous)), mediaType: .xhtml,
                            locations: .init(progression: 0, totalProgression: 0.29))
        t.page.currentLocation = start
        t.page.live = VisibleRange(href: t.previous, start: 0.986428, end: 1)
        t.page.words = words
        return start
    }

    /// Waits (in reads of the saved place) for a place on the previous chapter's last page, past the turn's
    /// second look.
    private func placeOnItsLastPage(closing close: Bool = true, _ t: Turn) async throws -> Locator {
        for _ in 0..<80 where t.saved()?.href.string != t.previous || (t.saved()?.locations.progression ?? 0) < 0.9 {
            try await Task.sleep(for: .milliseconds(25))
        }
        let place = try #require(t.saved(), "no place was saved")
        if close { t.model.close() }
        return place
    }

    /// He turns back from a chapter's first page onto the previous chapter's last page, and Readium, having
    /// reloaded that chapter, reports its start; `words` are what the page on screen gives as its first words.
    private func turnBackAfterAReload(words: String?) async throws -> (place: Locator, previous: String) {
        let t = try await opened()
        _ = try turnBack(t, words: words)
        t.model.userTurnedPage()
        return (try await placeOnItsLastPage(t), t.previous)
    }

    /// The place saved is the page he sees: in its chapter, on its page, with the page's own first words.
    @Test func aTurnBackAfterAReloadSavesThePageOnScreenNotTheFilesStart() async throws {
        let (place, previous) = try await turnBackAfterAReload(words: "words at the top of the page on screen")
        #expect(place.href.string == previous, "saved in \(place.href.string), not the chapter on screen")
        let p = place.locations.progression ?? -1
        #expect(p >= 0.986428 && p <= 1, "saved at \(p) in the chapter, not on the page on screen (0.986...1)")
        #expect(place.text.highlight == "words at the top of the page on screen", "saved without the page's own words")
    }

    /// A page that gives no words still saves the page he sees, by its progression alone.
    @Test func aTurnBackAfterAReloadWithNoWordsSavesThePagesMiddle() async throws {
        let (place, previous) = try await turnBackAfterAReload(words: nil)
        #expect(place.href.string == previous)
        let p = place.locations.progression ?? -1
        #expect(p >= 0.986428 && p <= 1, "saved at \(p), not on the page on screen (0.986...1)")
        #expect(place.text.highlight == nil, "kept words that weren't the page's")
    }

    /// Readium's own report of the reloaded file's start, arriving while the turn reads the page and kept
    /// first, is the layout's: the turn's look at the page on screen puts the place back on that page.
    @Test func aLateReportOfTheFilesStartDoesNotOutliveTheTurn() async throws {
        let t = try await opened()
        let start = try turnBack(t, words: "words at the top of the page on screen")
        t.page.holdNextPageRange = true
        t.model.userTurnedPage()
        for _ in 0..<200 where t.page.held == nil { try await Task.sleep(for: .milliseconds(5)) }
        try #require(t.page.held != nil, "the turn never read the page")
        await t.model.locationDidChange(start)
        t.page.release()
        try await Task.sleep(for: .milliseconds(900))
        let place = try await placeOnItsLastPage(t)
        let p = place.locations.progression ?? -1
        #expect(place.href.string == t.previous)
        #expect(p >= 0.986428 && p <= 1, "saved at \(p): the file's start outlived the turn")
    }

    /// A report on the page on screen is his place as Readium gave it.
    @Test func aReportOnThePageOnScreenIsKeptAsIs() async throws {
        let t = try await opened()
        let start = try turnBack(t, words: "words at the top of the page on screen")
        t.page.currentLocation = start.copy(locations: { $0.progression = 0.5 })
        t.page.live = VisibleRange(href: t.previous, start: 0.4985, end: 0.513)
        t.model.userTurnedPage()
        for _ in 0..<80 where t.saved()?.href.string != t.previous { try await Task.sleep(for: .milliseconds(25)) }
        try await Task.sleep(for: .milliseconds(900))
        let place = try #require(t.saved())
        t.model.close()
        #expect(place.href.string == t.previous)
        #expect(place.locations.progression == 0.5, "moved a report that was on the page: \(place.locations.progression ?? -1)")
    }

    /// A live read of another file, or none, can't say where the report's file is: the report stands.
    @Test(arguments: [true, false]) func aLiveReadElsewhereOrNoneKeepsTheReport(readsAnotherFile: Bool) async throws {
        let t = try await opened()
        _ = try turnBack(t, words: "words at the top of the page on screen")
        t.page.live = readsAnotherFile ? VisibleRange(href: t.next, start: 0.986428, end: 1) : nil
        t.model.userTurnedPage()
        for _ in 0..<80 where t.saved()?.href.string != t.previous { try await Task.sleep(for: .milliseconds(25)) }
        try await Task.sleep(for: .milliseconds(900))
        let place = try #require(t.saved())
        t.model.close()
        #expect(place.href.string == t.previous)
        #expect(place.locations.progression == 0, "corrected by a read it couldn't trust: \(place.locations.progression ?? -1)")
    }

    /// A rotation right after a corrected turn restores the page he sees: the anchor it restores by is the
    /// corrected page, not the file's start that Readium still names.
    @Test func aRotationAfterACorrectedTurnRestoresThePageOnScreen() async throws {
        let t = try await opened()
        _ = try turnBack(t, words: "words at the top of the page on screen")
        t.model.userTurnedPage()
        _ = try await placeOnItsLastPage(closing: false, t)
        // He turns the device: Readium lays the file out again at the start it still names.
        t.model.keeper.reflowWillBegin(.rotation)
        t.model.reflowDidBegin()
        let action = t.model.keeper.reflowDidSettle(visible: try #require(await t.page.visibleRange()))
        let anchor = try #require(t.model.keeper.anchor, "no anchor to restore by")
        let jump = try #require(t.model.locator(for: anchor), "nothing to jump to")
        t.model.close()
        #expect(anchor.href == t.previous)
        #expect(anchor.progression >= 0.986428 && anchor.progression <= 1, "the restore's anchor is @\(anchor.progression), not the page on screen")
        #expect(action == .jump(anchor), "the file's start counted as his page")
        let p = jump.locations.progression ?? -1
        #expect(p >= 0.986428 && p <= 1, "the restore jumps to @\(p), not the page on screen")
        #expect(jump.text.highlight == "words at the top of the page on screen")
    }
}
