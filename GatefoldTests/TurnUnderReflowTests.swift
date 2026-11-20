import Foundation
import GatefoldCore
import ReadiumShared
import Testing
@testable import Gatefold

/// gatefold#534: a tap's turn, and the iPad turned on its side before the turn lands. The reflow begins with
/// Readium already on the page beneath and the turn not yet counted. The page he turned to is his: the restore
/// puts it back, and its words are the place kept, whenever the turn lands. Build 46 put back the page before
/// the turn, or gave way and kept whatever page the unfinished layout showed. Judged in reports, never seconds.
@MainActor @Suite(.serialized) struct TurnUnderReflowTests {
    private func open() async throws -> (ReaderModel, TwoStepJumpPage, Publication, AppModel) {
        let sync = StubSync()
        await sync.setLibrary(.success([ReaderSyncTests.frankenstein]))
        await sync.setRemote(nil)
        let app = AppModel(sync: sync, libraryRoot: URL.temporaryDirectory.appending(path: "turn-reflow-\(UUID().uuidString)"))
        await app.library.refresh()
        let publication = try await ReaderSyncTests.publication()
        let book = try #require(app.library.book(ReaderSyncTests.frankenstein.fastHash))
        let opening = try #require(await ReaderSyncTests.locate(publication, 0.2))
        let page = TwoStepJumpPage(at: opening, readsToLand: 1)
        let model = ReaderModel(book: book, publication: publication, app: app, page: page)
        page.model = model
        await model.load()
        await model.locationDidChange(opening)
        return (model, page, publication, app)
    }

    private func savedPlace(_ app: AppModel) -> Locator? {
        app.library.book(ReaderSyncTests.frankenstein.fastHash)?.locatorJSON.flatMap { try? Locator(jsonString: $0) }
    }

    /// The tap's turn moves Readium onto the page beneath, and its words are read there.
    private func tapTurn(to place: Double, _ model: ReaderModel, _ page: TwoStepJumpPage, _ publication: Publication,
                         read: Bool = true) async throws -> Locator {
        let next = try #require(await ReaderSyncTests.locate(publication, place))
        page.currentLocation = next
        model.turnMovedBeneath()
        if read { await model.beneathRead?.value }
        return next
    }

    private func beginReflow(_ model: ReaderModel) {
        model.keeper.reflowWillBegin(.rotation, move: model.reflowMove())
        model.reflowDidBegin()
    }

    /// The restore puts his words back on a page that starts a little before them, as a spread can, and ends.
    private func restore(_ model: ReaderModel, _ page: TwoStepJumpPage, _ publication: Publication, onto place: Double) async throws {
        let restored = try #require(await ReaderSyncTests.locate(publication, place))
        page.currentLocation = restored
        let words = try #require(model.keeper.anchor?.text)
        model.keeper.restoreDidComplete()
        model.reflowDidFinish(visible: VisibleRange(href: restored.href.string, start: place, end: place + 0.01,
                                                    text: "a line before them. " + words))
    }

    private func waitForSave(_ app: AppModel, at next: Locator) async throws {
        for _ in 0..<200 where savedPlace(app)?.locations.progression != next.locations.progression {
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    @Test func aTurnThatLandsBeforeTheRestoreLooksIsPutBackAndKept() async throws {
        let (model, page, publication, app) = try await open()
        let next = try await tapTurn(to: 0.205, model, page, publication)
        beginReflow(model)
        #expect(model.keeper.restoreMayMove(move: model.hisMoves), "the restore gave way before the turn landed")
        model.userTurnedPage()
        #expect(model.keeper.restoreMayMove(move: model.hisMoves), "the restore gave way to the turn it puts back")
        model.takeTurnUnderReflow()
        #expect(model.keeper.anchor?.progression == next.locations.progression, "the restore puts back the page before the turn")
        try await restore(model, page, publication, onto: 0.204)
        try await waitForSave(app, at: next)
        #expect(savedPlace(app)?.locations.progression == next.locations.progression, "the place kept isn't the page he turned to")
        #expect(savedPlace(app)?.text.highlight != nil, "the place kept has no words")
        model.close()
    }

    @Test func aTurnThatLandsAfterTheRestoreLooksIsPutBackAndKept() async throws {
        let (model, page, publication, app) = try await open()
        let next = try await tapTurn(to: 0.205, model, page, publication)
        beginReflow(model)
        model.takeTurnUnderReflow()
        #expect(model.keeper.restoreMayMove(move: model.hisMoves), "the restore gave way before the turn landed")
        model.userTurnedPage()
        #expect(model.keeper.restoreMayMove(move: model.hisMoves), "the restore gave way to the turn it puts back")
        try await restore(model, page, publication, onto: 0.204)
        try await waitForSave(app, at: next)
        #expect(savedPlace(app)?.locations.progression == next.locations.progression, "the place kept isn't the page he turned to")
        model.close()
    }

    @Test func aTurnThatLandsOnceTheReflowHasEndedKeepsItsOwnWords() async throws {
        let (model, page, publication, app) = try await open()
        let next = try await tapTurn(to: 0.205, model, page, publication)
        beginReflow(model)
        model.takeTurnUnderReflow()
        try await restore(model, page, publication, onto: 0.204)
        model.userTurnedPage()
        await model.turnLook?.value
        try await waitForSave(app, at: next)
        #expect(savedPlace(app)?.locations.progression == next.locations.progression, "the restored page's first words were kept, not his turn's")
        #expect(model.keeper.anchor?.progression == next.locations.progression)
        model.close()
    }

    /// An iPad's rotation begins two reflows in a row; the turn lands between them.
    @Test func aTurnThatLandsBetweenTwoReflowsIsPutBackByTheSecond() async throws {
        let (model, page, publication, app) = try await open()
        let next = try await tapTurn(to: 0.205, model, page, publication)
        beginReflow(model)
        model.userTurnedPage()
        beginReflow(model)
        model.takeTurnUnderReflow()
        #expect(model.keeper.anchor?.progression == next.locations.progression, "the second reflow puts back the page before the turn")
        #expect(model.keeper.restoreMayMove(move: model.hisMoves))
        try await restore(model, page, publication, onto: 0.204)
        try await waitForSave(app, at: next)
        #expect(savedPlace(app)?.locations.progression == next.locations.progression, "the place kept isn't the page he turned to")
        model.close()
    }

    /// Two reflows, the turn landing between them, with no words read: the second gives way to its landing, never
    /// putting back the page before the turn.
    @Test func aTurnWithNoWordsThatLandsBetweenTwoReflowsIsGivenWayTo() async throws {
        let (model, page, publication, _) = try await open()
        let before = model.keeper.anchor
        _ = try await tapTurn(to: 0.205, model, page, publication, read: false)
        beginReflow(model)
        await model.beneathRead?.value
        model.userTurnedPage()
        beginReflow(model)
        model.takeTurnUnderReflow()
        #expect(model.keeper.anchor == before)
        #expect(!model.keeper.restoreMayMove(move: model.hisMoves), "the second reflow would put the page before the turn back")
        model.close()
    }

    /// A jump of his after the restore put the turn's page back, before the turn landed: the jump is his place.
    @Test func aJumpBeforeTheTurnLandsIsNeverWrittenOverByItsWords() async throws {
        let (model, page, publication, app) = try await open()
        let next = try await tapTurn(to: 0.205, model, page, publication)
        beginReflow(model)
        model.takeTurnUnderReflow()
        try await restore(model, page, publication, onto: 0.204)
        let movesBefore = model.hisMoves
        _ = await model.go(toProgression: 0.5, rememberBack: false)
        try #require(model.hisMoves > movesBefore, "the jump counted as his move")
        model.userTurnedPage()
        await model.turnLook?.value
        #expect(savedPlace(app)?.locations.progression != next.locations.progression, "the turn's words were written over his jump")
        model.close()
    }

    /// A read the reflow began during may mix the two layouts: no words, so the restore gives way to the landing.
    @Test func aReadTheReflowOvertookIsNoWordsAndTheRestoreGivesWay() async throws {
        let (model, page, publication, _) = try await open()
        let before = model.keeper.anchor
        _ = try await tapTurn(to: 0.205, model, page, publication, read: false)
        beginReflow(model)
        await model.beneathRead?.value
        #expect(model.beneathWords == nil, "words read across the reflow's start were kept")
        model.takeTurnUnderReflow()
        #expect(model.keeper.anchor == before)
        model.userTurnedPage()
        #expect(!model.keeper.restoreMayMove(move: model.hisMoves), "the restore would put the page before the turn back under it")
        model.close()
    }

    /// The start of the chapter after the one on screen: where a tap forward from its last screen lands.
    private func nextChapterStart(_ model: ReaderModel, _ page: TwoStepJumpPage) throws -> Locator {
        let here = try #require(page.currentLocation)
        let order = model.readingOrderHrefs
        let i = try #require(order.firstIndex(of: here.href.string))
        let next = try #require(AnyURL(string: order[i + 1]))
        return Locator(href: next, mediaType: here.mediaType, locations: .init(progression: 0))
    }

    /// A tap into the next chapter, its page still loading, so no words are read before the reflow overtakes the read
    /// (build 47's review at 0.73): the restore puts back the chapter's start, and the turn's landing is the turn it
    /// puts back, never a move it gives way to. Build 47 gave way, and Readium's report of the chapter he left was kept.
    @Test func aTurnIntoTheNextChapterWithNoWordsReadPutsBackItsStart() async throws {
        let (model, page, _, _) = try await open()
        let start = try nextChapterStart(model, page)
        page.currentLocation = start
        model.turnMovedBeneath(reaching: start)
        beginReflow(model)
        await model.beneathRead?.value
        model.takeTurnUnderReflow()
        #expect(model.keeper.anchor?.href == start.href.string, "the restore puts back another chapter")
        #expect(model.keeper.anchor?.progression == 0, "the restore puts back a page past the chapter's start")
        model.userTurnedPage()
        #expect(model.keeper.restoreMayMove(move: model.hisMoves), "the restore gave way to the turn it puts back")
        model.close()
    }

    /// The same tap with the iPad turned before the turn has moved (build 47's review at 0.47): the reflow began with no
    /// turn under way, and the turn moves under it. Its chapter's start is still the page put back. Build 47's restore
    /// put back the page he tapped from, then gave way to the turn landing on it.
    @Test func aTurnIntoTheNextChapterMovedUnderAReflowPutsBackItsStart() async throws {
        let (model, page, _, _) = try await open()
        let start = try nextChapterStart(model, page)
        beginReflow(model)
        page.currentLocation = start
        model.turnMovedBeneath(reaching: start)
        model.takeTurnUnderReflow()
        #expect(model.keeper.anchor?.href == start.href.string, "the restore puts back the chapter he turned from")
        #expect(model.keeper.anchor?.progression == 0)
        model.userTurnedPage()
        #expect(model.keeper.restoreMayMove(move: model.hisMoves), "the restore gave way to the turn it puts back")
        model.close()
    }

    /// The same tap read while the chapter he left is still on screen, the next one loading: those words are not the
    /// page he turned to, and its chapter's start stays the page the restore puts back.
    @Test func aTurnIntoTheNextChapterNeverTakesTheWordsOfTheChapterHeLeft() async throws {
        let (model, page, _, _) = try await open()
        let start = try nextChapterStart(model, page)
        model.turnMovedBeneath(reaching: start)
        await model.beneathRead?.value
        beginReflow(model)
        model.takeTurnUnderReflow()
        #expect(model.keeper.anchor?.href == start.href.string, "the restore puts back the page he turned from")
        #expect(model.keeper.anchor?.progression == 0)
        model.close()
    }

    /// A tap's turn within the chapter, the iPad turned before the page beneath answered (main's run for #565, on a
    /// hosted runner: the reflow began 170 ms after the turn moved): its words, read before it moved in the layout he
    /// turned in, are the page put back. Main gave way to the landing, back on the page he turned from.
    @Test func aTurnWhosePageAnsweredLateIsPutBackByItsWordsReadBeforeItMoved() async throws {
        let (model, page, publication, _) = try await open()
        let next = try #require(await ReaderSyncTests.locate(publication, 0.205))
        let words = next.copy(text: { $0 = .init(highlight: "the first words of the page he turned to") })
        page.currentLocation = next
        model.turnMovedBeneath(reaching: words)
        beginReflow(model)
        await model.beneathRead?.value
        model.takeTurnUnderReflow()
        #expect(model.keeper.anchor?.text == "the first words of the page he turned to", "the restore gave way, or put back other words")
        model.userTurnedPage()
        #expect(model.keeper.restoreMayMove(move: model.hisMoves), "the restore gave way to the turn it puts back")
        model.close()
    }
}
