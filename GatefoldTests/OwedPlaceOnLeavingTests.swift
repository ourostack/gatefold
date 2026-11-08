import Foundation
import GatefoldCore
import ReadiumShared
import Testing
@testable import Gatefold

/// A move he makes while a reflow is laying out (a turn while the iPad's rotation settles) is owed: the
/// reflow's end records it. A reflow that never settles (a slow device, a load stuck as in gatefold#94)
/// never ends, so leaving dropped the move, and the reopen came back where he was before it
/// (gatefold#96). Judged in reports and reads, never seconds.
@MainActor @Suite(.serialized) struct OwedPlaceOnLeavingTests {
    @Test func aTurnUnderAReflowThatNeverSettlesIsKeptWhenHeClosesTheBook() async throws {
        let sync = StubSync()
        await sync.setLibrary(.success([ReaderSyncTests.frankenstein]))
        await sync.setRemote(nil)
        let app = AppModel(sync: sync, libraryRoot: URL.temporaryDirectory.appending(path: "owed-on-leaving-\(UUID().uuidString)"))
        await app.library.refresh()
        let publication = try await ReaderSyncTests.publication()
        let book = try #require(app.library.book(ReaderSyncTests.frankenstein.fastHash))
        let first = publication.readingOrder[0].url().string
        let opening = Locator(href: try #require(AnyURL(string: first)), mediaType: .xhtml,
                              locations: .init(progression: 0, totalProgression: 0))
        let page = TwoStepJumpPage(at: opening, readsToLand: 1)
        let model = ReaderModel(book: book, publication: publication, app: app, page: page)
        page.model = model
        await model.load()

        // He turns the iPad, and turns the page while its reflow lays out; the reflow never settles.
        model.keeper.reflowWillBegin(.rotation)
        model.reflowDidBegin()
        let turned = try #require(await ReaderSyncTests.locate(publication, 0.31))
        page.currentLocation = turned
        model.userTurnedPage()
        for _ in 0..<200 where !model.placeOwed { await Task.yield() }
        #expect(model.placeOwed, "the turn under the reflow is owed")

        // He closes the book with the reflow still under way.
        model.close()
        func savedPlace() -> Locator? {
            app.library.book(ReaderSyncTests.frankenstein.fastHash)?.locatorJSON.flatMap { try? Locator(jsonString: $0) }
        }
        for _ in 0..<200 where savedPlace()?.locations.progression != turned.locations.progression {
            try await Task.sleep(for: .milliseconds(25))
        }
        let saved = try #require(savedPlace(), "leaving kept no place")
        #expect(saved.href.string == turned.href.string)
        #expect(saved.locations.progression == turned.locations.progression,
                "kept at \(saved.locations.progression ?? -1) in its file, not the page he turned to (\(turned.locations.progression ?? -1))")
    }
}
