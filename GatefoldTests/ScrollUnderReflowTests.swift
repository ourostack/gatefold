import Foundation
import GatefoldCore
import ReadiumShared
import Testing
@testable import Gatefold

/// A scroll or swipe of his while a reflow lays out (switching to Scroll on a slow iPad, gatefold#171)
/// is his move: the reflow's restore gives way to it and his page is owed, never put back under him.
/// CI's iPad (job 129949743858): six swipes during a restarted typography reflow, and the restore then
/// put the words from before the switch back on screen. Judged in reports and reads, never seconds.
@MainActor @Suite(.serialized) struct ScrollUnderReflowTests {
    private func open() async throws -> (ReaderModel, TwoStepJumpPage, Publication, AppModel) {
        let sync = StubSync()
        await sync.setLibrary(.success([ReaderSyncTests.frankenstein]))
        await sync.setRemote(nil)
        let app = AppModel(sync: sync, libraryRoot: URL.temporaryDirectory.appending(path: "scroll-reflow-\(UUID().uuidString)"))
        await app.library.refresh()
        let publication = try await ReaderSyncTests.publication()
        let book = try #require(app.library.book(ReaderSyncTests.frankenstein.fastHash))
        let opening = try #require(await ReaderSyncTests.locate(publication, 0.2))
        let page = TwoStepJumpPage(at: opening, readsToLand: 1)
        let model = ReaderModel(book: book, publication: publication, app: app, page: page)
        page.model = model
        await model.load()
        model.setPreferences { $0.pageTurn = .scroll }
        await model.locationDidChange(opening)
        return (model, page, publication, app)
    }

    private func savedPlace(_ app: AppModel) -> Locator? {
        app.library.book(ReaderSyncTests.frankenstein.fastHash)?.locatorJSON.flatMap { try? Locator(jsonString: $0) }
    }

    @Test func aScrollOfHisWhileAReflowLaysOutIsHisMove() async throws {
        let (model, page, publication, app) = try await open()
        // The switch to Scroll lays the book out again; its restore would put his words back.
        model.keeper.reflowWillBegin(.typography, move: model.hisMoves)
        model.reflowDidBegin()
        #expect(model.keeper.restoreMayMove(move: model.hisMoves))
        // He scrolls: a touch that travels, and the page moves on.
        model.noteInteraction()
        model.noteDrag()
        let scrolled = try #require(await ReaderSyncTests.locate(publication, 0.22))
        page.currentLocation = scrolled
        await model.locationDidChange(scrolled)
        #expect(!model.keeper.restoreMayMove(move: model.hisMoves), "the restore would still put his old words back over his scroll")
        #expect(model.placeOwed, "his scroll under the reflow isn't owed: the reflow's end won't keep it")

        // The restore gives way and the reflow ends: the place he scrolled to is the one kept.
        model.keeper.restoreGaveWay()
        model.reflowDidFinish(visible: nil)
        // Waited on the save itself: the debt is cleared before the place is written.
        for _ in 0..<200 where savedPlace(app)?.locations.progression != scrolled.locations.progression {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(!model.placeOwed, "the reflow's end never paid the scroll it owed")
        #expect(savedPlace(app)?.locations.progression == scrolled.locations.progression, "the saved place isn't where he scrolled to")
        model.close()
    }

    /// The reflow's own reports (no touch of his) are the layout, not a move: the restore keeps his words.
    @Test func theReflowsOwnReportsAreNotHisMove() async throws {
        let (model, page, publication, _) = try await open()
        model.keeper.reflowWillBegin(.typography, move: model.hisMoves)
        model.reflowDidBegin()
        let laidOut = try #require(await ReaderSyncTests.locate(publication, 0.21))
        page.currentLocation = laidOut
        await model.locationDidChange(laidOut)
        #expect(model.keeper.restoreMayMove(move: model.hisMoves), "the layout's own report took the restore away")
        model.close()
    }

    /// A touch from before the reflow (holding the iPad as it turns, a tap that went nowhere) is not a
    /// scroll under it: the reflow's own layout report keeps the restore.
    @Test func aTouchFromBeforeTheReflowIsNotAScrollUnderIt() async throws {
        let (model, page, publication, _) = try await open()
        model.noteInteraction()
        model.noteDrag()
        let before = model.hisMoves
        model.keeper.reflowWillBegin(.rotation, move: model.hisMoves)
        model.reflowDidBegin()
        let laidOut = try #require(await ReaderSyncTests.locate(publication, 0.21))
        page.currentLocation = laidOut
        await model.locationDidChange(laidOut)
        #expect(model.keeper.restoreMayMove(move: model.hisMoves), "a touch from before the reflow took its restore away")
        #expect(!model.placeOwed, "the layout's page boundary is owed as his place")
        #expect(model.hisMoves == before, "a touch from before the reflow counted as a move of his")
        model.close()
    }

    /// A tap during the reflow that only shows the controls moves nothing.
    @Test func aTapForTheControlsDuringTheReflowIsNotAScroll() async throws {
        let (model, page, publication, _) = try await open()
        model.keeper.reflowWillBegin(.typography, move: model.hisMoves)
        model.reflowDidBegin()
        model.noteInteraction()
        model.controlsTapped(visible: true)
        let laidOut = try #require(await ReaderSyncTests.locate(publication, 0.21))
        page.currentLocation = laidOut
        await model.locationDidChange(laidOut)
        #expect(model.keeper.restoreMayMove(move: model.hisMoves), "a tap for the controls took the restore away")
        model.close()
    }

    /// One swipe is one move, however many reports its scroll brings.
    @Test func oneSwipeUnderTheReflowIsOneMove() async throws {
        let (model, page, publication, _) = try await open()
        model.keeper.reflowWillBegin(.typography, move: model.hisMoves)
        model.reflowDidBegin()
        let before = model.hisMoves
        model.noteInteraction()
        model.noteDrag()
        for p in [0.22, 0.23] {
            let here = try #require(await ReaderSyncTests.locate(publication, p))
            page.currentLocation = here
            await model.locationDidChange(here)
        }
        #expect(model.hisMoves == before + 1, "one swipe counted as \(model.hisMoves - before) moves")
        model.close()
    }

    /// A finger down that hasn't travelled is no scroll yet: a report of the layout's that lands before
    /// the tap is recognised keeps the restore.
    @Test func aFingerDownBeforeItsTapIsRecognisedIsNotAScroll() async throws {
        let (model, page, publication, _) = try await open()
        model.keeper.reflowWillBegin(.typography, move: model.hisMoves)
        model.reflowDidBegin()
        let before = model.hisMoves
        model.noteInteraction()
        let laidOut = try #require(await ReaderSyncTests.locate(publication, 0.21))
        page.currentLocation = laidOut
        await model.locationDidChange(laidOut)
        #expect(model.keeper.restoreMayMove(move: model.hisMoves), "a finger down for a tap took the restore away")
        #expect(model.hisMoves == before, "a finger down for a tap counted as a move of his")
        model.close()
    }

    /// A turn under the reflow is one move: its own late report is not a second one.
    @Test func aTurnUnderTheReflowIsOneMove() async throws {
        let (model, page, publication, _) = try await open()
        model.keeper.reflowWillBegin(.typography, move: model.hisMoves)
        model.reflowDidBegin()
        let before = model.hisMoves
        model.noteInteraction()
        model.noteDrag()
        let next = try #require(await ReaderSyncTests.locate(publication, 0.22))
        page.currentLocation = next
        model.userTurnedPage()
        await model.locationDidChange(next)
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.hisMoves == before + 1, "one turn counted as \(model.hisMoves - before) moves")
        model.close()
    }

    /// In curl the page moves only by a turn: a drag that springs back, then the layout's own report,
    /// keeps the restore.
    @Test func aCurlDragThatTurnsNothingIsNotAScroll() async throws {
        let (model, page, publication, _) = try await open()
        model.setPreferences { $0.pageTurn = .curl }
        model.keeper.reflowWillBegin(.typography, move: model.hisMoves)
        model.reflowDidBegin()
        let before = model.hisMoves
        model.noteInteraction()
        model.noteDrag()
        model.dragDidNotTurn()
        let laidOut = try #require(await ReaderSyncTests.locate(publication, 0.21))
        page.currentLocation = laidOut
        await model.locationDidChange(laidOut)
        #expect(model.keeper.restoreMayMove(move: model.hisMoves), "a curl drag that turned nothing took the restore away")
        #expect(model.hisMoves == before, "a curl drag that turned nothing counted as a move of his")
        model.close()
    }

    /// In curl a drag up the page neither turns nor springs back: it is still no scroll.
    @Test func aCurlDragUpThePageIsNotAScroll() async throws {
        let (model, page, publication, _) = try await open()
        model.setPreferences { $0.pageTurn = .curl }
        model.keeper.reflowWillBegin(.typography, move: model.hisMoves)
        model.reflowDidBegin()
        let before = model.hisMoves
        model.noteInteraction()
        model.noteDrag()
        let laidOut = try #require(await ReaderSyncTests.locate(publication, 0.21))
        page.currentLocation = laidOut
        await model.locationDidChange(laidOut)
        #expect(model.keeper.restoreMayMove(move: model.hisMoves), "a curl drag up the page took the restore away")
        #expect(model.hisMoves == before, "a curl drag up the page counted as a move of his")
        model.close()
    }
}
