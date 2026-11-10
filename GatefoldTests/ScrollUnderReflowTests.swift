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
    private func open() async throws -> (ReaderModel, TwoStepJumpPage, Publication) {
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
        await model.locationDidChange(opening)
        return (model, page, publication)
    }

    @Test func aScrollOfHisWhileAReflowLaysOutIsHisMove() async throws {
        let (model, page, publication) = try await open()
        // The switch to Scroll lays the book out again; its restore would put his words back.
        model.keeper.reflowWillBegin(.typography, move: model.hisMoves)
        model.reflowDidBegin()
        #expect(model.keeper.restoreMayMove(move: model.hisMoves))
        // He scrolls: a touch, and the page moves on.
        model.noteInteraction()
        let scrolled = try #require(await ReaderSyncTests.locate(publication, 0.22))
        page.currentLocation = scrolled
        await model.locationDidChange(scrolled)
        #expect(!model.keeper.restoreMayMove(move: model.hisMoves), "the restore would still put his old words back over his scroll")
        #expect(model.placeOwed, "his scroll under the reflow isn't owed: the reflow's end won't keep it")
        model.close()
    }

    /// The reflow's own reports (no touch of his) are the layout, not a move: the restore keeps his words.
    @Test func theReflowsOwnReportsAreNotHisMove() async throws {
        let (model, page, publication) = try await open()
        model.keeper.reflowWillBegin(.typography, move: model.hisMoves)
        model.reflowDidBegin()
        let laidOut = try #require(await ReaderSyncTests.locate(publication, 0.21))
        page.currentLocation = laidOut
        await model.locationDidChange(laidOut)
        #expect(model.keeper.restoreMayMove(move: model.hisMoves), "the layout's own report took the restore away")
        model.close()
    }
}
