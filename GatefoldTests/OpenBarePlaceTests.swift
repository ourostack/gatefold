import Foundation
import GatefoldCore
import ReadiumShared
import Testing
@testable import Gatefold

/// A place saved with no words holds no anchor, so a reopen whose restore stalled on the chapter's start
/// left him there (gatefold#250). The open's place is put back once, only while that restore is pending and
/// only if he hasn't moved: never a late jump off a page he chose, and never a saved place moved.
@MainActor @Suite(.serialized) struct OpenBarePlaceTests {
    struct Opened {
        let app: AppModel
        let model: ReaderModel
        let saved: Locator
        let page: TwoStepJumpPage
    }

    /// Opens the book on a saved place at `progression` (Readium's location, no words unless `words`).
    func open(at progression: Double, words: String? = nil) async throws -> Opened {
        let sync = StubSync()
        await sync.setLibrary(.success([ReaderSyncTests.frankenstein]))
        await sync.setRemote(nil)
        let app = AppModel(sync: sync, libraryRoot: URL.temporaryDirectory.appending(path: "bare-open-\(UUID().uuidString)"))
        await app.library.refresh()
        let publication = try await ReaderSyncTests.publication()
        var saved = try #require(await ReaderSyncTests.locate(publication, progression))
        saved = saved.copy(text: { $0 = Locator.Text(highlight: words) })
        let id = ReaderSyncTests.frankenstein.fastHash
        app.library.recordPlace(bookID: id, locatorJSON: try saved.jsonString(), totalProgression: saved.locations.totalProgression ?? 0,
                                progression: saved.locations.progression ?? 0)
        let book = try #require(app.library.book(id))
        let page = TwoStepJumpPage(at: saved, readsToLand: 1)
        let model = ReaderModel(book: book, publication: publication, app: app, page: page)
        page.model = model
        return Opened(app: app, model: model, saved: saved, page: page)
    }

    func range(_ saved: Locator, _ start: Double, _ end: Double) -> VisibleRange {
        VisibleRange(href: saved.href.string, start: start, end: end)
    }

    @Test func aStalledRestoreOnTheChapterStartPutsTheBarePlaceBackOnce() async throws {
        let o = try await open(at: 0.31)
        o.model.keeper.reflowWillBegin(.rotation)
        let p = o.saved.locations.progression ?? 0
        try #require(p > 0.05, "the saved place is past the chapter's first page")
        let back = try #require(o.model.openPlaceToReapply(visible: range(o.saved, 0, 0.0333)), "the open's place was not put back")
        #expect(back.1.href.string == o.saved.href.string)
        #expect(back.1.locations.progression == p, "put back somewhere other than the saved place")
        #expect(back.0.text == nil)
        #expect(o.model.openPlaceToReapply(visible: range(o.saved, 0, 0.0333)) == nil, "put back more than once per open")
    }

    @Test func onceHeHasMovedTheLateReapplyDoesNothing() async throws {
        let o = try await open(at: 0.31)
        o.model.keeper.reflowWillBegin(.rotation)
        o.model.userTurnedPage()
        #expect(o.model.openPlaceToReapply(visible: range(o.saved, 0, 0.0333)) == nil, "a late jump took him off the page he turned to")
    }

    @Test func aTurnStillAnimatingBlocksTheReapply() async throws {
        let o = try await open(at: 0.31)
        o.model.keeper.reflowWillBegin(.rotation)
        o.page.isTurning = true
        #expect(o.model.openPlaceToReapply(visible: range(o.saved, 0, 0.0333)) == nil, "a late jump pulled back a page he was turning")
        o.page.isTurning = false
        #expect(o.model.openPlaceToReapply(visible: range(o.saved, 0, 0.0333)) == nil, "put back after the turn he began")
    }

    @Test func aClosedReaderNeverReapplies() async throws {
        let o = try await open(at: 0.31)
        o.model.keeper.reflowWillBegin(.rotation)
        o.model.close()
        #expect(o.model.openPlaceToReapply(visible: range(o.saved, 0, 0.0333)) == nil, "a closed reader jumped")
    }

    @Test func aTouchSinceTheLastReportBlocksTheReapply() async throws {
        let o = try await open(at: 0.31)
        o.model.keeper.reflowWillBegin(.rotation)
        o.model.noteInteraction()
        #expect(o.model.openPlaceToReapply(visible: range(o.saved, 0, 0.0333)) == nil, "put back under his finger")
    }

    @Test func neverAfterTheOpensRestoreHasLanded() async throws {
        let o = try await open(at: 0.31)
        o.model.keeper.reflowWillBegin(.rotation)
        o.model.keeper.restoreDidComplete()
        o.model.reflowDidFinish(visible: range(o.saved, 0, 0.0333))
        o.model.keeper.reflowWillBegin(.rotation)
        #expect(o.model.openPlaceToReapply(visible: range(o.saved, 0, 0.0333)) == nil, "put back after the restore had landed")
    }

    @Test func noRestorePendingNoReapply() async throws {
        let o = try await open(at: 0.31)
        #expect(o.model.openPlaceToReapply(visible: range(o.saved, 0, 0.0333)) == nil, "put back with no restore under way")
    }

    /// Saved places on and off a page's start boundary: a page that shows the place (from its start, from
    /// inside, a spread across it) is never moved, and a place with words is the anchor's, not this path's.
    @Test(arguments: [(0.0, 0.1), (-0.0333, 0.0333), (-0.0001, 0.06), (-0.05, 0.0001)])
    func aPageThatShowsTheSavedPlaceIsNeverMoved(offsets: (Double, Double)) async throws {
        let o = try await open(at: 0.31)
        o.model.keeper.reflowWillBegin(.rotation)
        let p = o.saved.locations.progression ?? 0
        #expect(o.model.openPlaceToReapply(visible: range(o.saved, p + offsets.0, p + offsets.1)) == nil,
                "moved a page showing the saved place (\(offsets.0), \(offsets.1))")
    }

    @Test func aPlaceWithWordsIsLeftToItsAnchor() async throws {
        let o = try await open(at: 0.31, words: "placeholder words for the anchor")
        o.model.keeper.reflowWillBegin(.rotation)
        #expect(o.model.openPlaceToReapply(visible: range(o.saved, 0, 0.0333)) == nil)
    }
}
