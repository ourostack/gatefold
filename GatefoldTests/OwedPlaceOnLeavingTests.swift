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

    /// The app only went inactive (Control Center, a notification) and came back: the owed move was
    /// written as he seemed to leave, and the reflow, settling after all, still records his own words
    /// over it, as it does with no leaving at all.
    @Test func aReflowThatSettlesAfterAnInactiveMomentStillKeepsHisWords() async throws {
        let sync = StubSync()
        await sync.setLibrary(.success([ReaderSyncTests.frankenstein]))
        await sync.setRemote(nil)
        let app = AppModel(sync: sync, libraryRoot: URL.temporaryDirectory.appending(path: "owed-inactive-\(UUID().uuidString)"))
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
        model.keeper.reflowWillBegin(.rotation)
        model.reflowDidBegin()
        let turned = try #require(await ReaderSyncTests.locate(publication, 0.31))
        page.currentLocation = turned
        model.userTurnedPage()
        for _ in 0..<200 where !model.placeOwed { await Task.yield() }
        func savedPlace() -> Locator? {
            app.library.book(ReaderSyncTests.frankenstein.fastHash)?.locatorJSON.flatMap { try? Locator(jsonString: $0) }
        }

        // Inactive: the owed move is written now, Readium's page only (no words yet).
        let owed = try #require(model.owedPlaceOnLeaving())
        await model.keepOwedPlace(owed)
        #expect(savedPlace()?.locations.progression == turned.locations.progression, "the inactive moment kept the turn")
        #expect(savedPlace()?.text.highlight == nil)
        #expect(model.placeOwed, "the reader is still open: the reflow still owes his words")

        // Back, and the reflow settles: his words are the place.
        model.keeper.restoreDidComplete()
        model.reflowDidFinish(visible: await page.visibleRange())
        for _ in 0..<200 where model.placeOwed || savedPlace()?.text.highlight == nil {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(!model.placeOwed, "the reflow paid its debt")
        let saved = try #require(savedPlace())
        #expect(saved.locations.progression == turned.locations.progression)
        #expect(saved.text.highlight != nil, "the settled reflow's capture of his words was not kept last")
        model.close()
    }

    /// A restore that stalls after a rotation leaves him the page as it was (gatefold#133). Leaving writes
    /// that page at once, before any wait: the words and their mapped position may never come while the
    /// page is stalled, and the app may be ended a moment later. The words, when they come, land on the
    /// same place. Fails if the leave write waits on the words' path (`placeWriteWait`, then the mapping).
    @Test func thePageAStalledRestoreLeftIsWrittenBeforeAnyWait() async throws {
        let sync = StubSync()
        await sync.setLibrary(.success([ReaderSyncTests.frankenstein]))
        await sync.setRemote(nil)
        let app = AppModel(sync: sync, libraryRoot: URL.temporaryDirectory.appending(path: "shown-on-leaving-\(UUID().uuidString)"))
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
        func savedPlace() -> Locator? {
            app.library.book(ReaderSyncTests.frankenstein.fastHash)?.locatorJSON.flatMap { try? Locator(jsonString: $0) }
        }

        // He rotates; the restore stalls, and the page is shown as it is, a page the opening wasn't on.
        model.keeper.reflowWillBegin(.rotation)
        model.reflowDidBegin()
        let shownPage = try #require(await ReaderSyncTests.locate(publication, 0.31))
        let withWords = shownPage.copy(text: { $0.highlight = "placeholder words" })
        let note = try #require(model.reflowShownUnsettled(shownPage))
        try #require(model.reflowShownUnsettled(withWords, wordsFor: note) != nil, "his words noted for the page shown")

        // The words' path never comes back while he is leaving.
        let held = LeaveGate()
        model.placeWriteWait = { await held.wait() }
        let owed = try #require(model.owedPlaceOnLeaving(), "the page left unsettled is owed on leaving")
        let leaving = Task { await model.keepOwedPlace(owed) }
        for _ in 0..<200 where savedPlace()?.locations.progression != shownPage.locations.progression { await Task.yield() }
        let atOnce = try #require(savedPlace(), "leaving kept no place before the words' wait")
        #expect(atOnce.href.string == shownPage.href.string)
        #expect(atOnce.locations.progression == shownPage.locations.progression,
                "kept at \(atOnce.locations.progression ?? -1), not the shown page (\(shownPage.locations.progression ?? -1)), while the words' path waits")
        #expect(atOnce.text.highlight == nil, "Readium's location first")

        // The words come: on the same place, never another.
        await held.open()
        await leaving.value
        let after = try #require(savedPlace())
        #expect(after.locations.progression == shownPage.locations.progression)
        #expect(after.text.highlight != nil, "his words were not attached once they came")
        model.close()
    }
}

/// A wait that holds until it is opened.
actor LeaveGate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}
