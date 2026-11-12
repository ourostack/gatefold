import Foundation
import GatefoldCore
import ReadiumShared
import Testing
@testable import Gatefold

/// He turns and leaves at once, and iOS ends Gatefold before his turn's write lands (gatefold#301): the
/// write waits for the leaf to land, then for his words and the mapped position. Leaving writes the page on
/// screen in its own turn, before any wait; the write under way, if it ever lands, adds his words to the
/// same page. Judged in writes and places, never seconds.
@MainActor @Suite(.serialized) struct QuickLeaveTests {
    @MainActor struct Opened {
        let app: AppModel
        let model: ReaderModel
        let page: TwoStepJumpPage
        let publication: Publication
        func saved() -> Locator? {
            app.library.book(ReaderSyncTests.frankenstein.fastHash)?.locatorJSON.flatMap { try? Locator(jsonString: $0) }
        }
    }

    func open() async throws -> Opened {
        let sync = StubSync()
        await sync.setLibrary(.success([ReaderSyncTests.frankenstein]))
        await sync.setRemote(nil)
        let app = AppModel(sync: sync, libraryRoot: URL.temporaryDirectory.appending(path: "quick-leave-\(UUID().uuidString)"))
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
        return Opened(app: app, model: model, page: page, publication: publication)
    }

    /// He turns, and his turn is kept with his words.
    func turnAndKeep(_ o: Opened, to progression: Double) async throws -> Locator {
        let read = try #require(await ReaderSyncTests.locate(o.publication, progression))
        o.page.currentLocation = read
        o.model.userTurnedPage()
        await o.model.locationDidChange(read)
        for _ in 0..<200 where o.saved()?.locations.progression != read.locations.progression || o.saved()?.text.highlight == nil {
            await Task.yield()
        }
        try #require(o.saved()?.locations.progression == read.locations.progression, "his turn was kept")
        return read
    }

    /// The turn has landed and its write is on its way (his words read, the position not yet mapped) when the
    /// app goes inactive: the page is written then, before any wait. The write, landing after all, keeps it.
    @Test func aTurnWhoseWriteIsStillOnItsWayIsWrittenAsHeLeaves() async throws {
        let o = try await open()
        let before = try await turnAndKeep(o, to: 0.12)
        let held = LeaveGate()
        o.model.placeWriteWait = { await held.wait() }
        let turned = try #require(await ReaderSyncTests.locate(o.publication, 0.31))
        o.page.currentLocation = turned
        o.model.userTurnedPage()
        for _ in 0..<400 where await held.waiters == 0 { await Task.yield() }
        try #require(await held.waiters == 1, "the turn's write waits on its way")
        #expect(o.saved()?.locations.progression == before.locations.progression, "the write landed before he left")

        // He leaves: the page of his turn is the place by the time the call returns, with no yield.
        o.model.keepTurnNow()
        let atOnce = try #require(o.saved())
        #expect(atOnce.href.string == turned.href.string)
        #expect(atOnce.locations.progression == turned.locations.progression,
                "kept at \(atOnce.locations.progression ?? -1), not the page he turned to (\(turned.locations.progression ?? -1))")
        #expect(atOnce.text.highlight != nil, "the words his turn had already read were not kept: a bare place can reopen on the chapter's start")

        // The app wasn't ended after all: the write under way lands on the same page, with his words.
        let records = o.model.placeRecords
        await held.open()
        for _ in 0..<400 where o.model.placeRecords == records { await Task.yield() }
        #expect(o.model.placeRecords > records, "the write under way never landed")
        let after = try #require(o.saved())
        #expect(after.locations.progression == turned.locations.progression, "the write under way moved the place")
        #expect(after.text.highlight != nil, "the write under way dropped his words")
        o.model.close()
    }

    /// The leaf is still falling (Readium is already on the page beneath; the turn counts when it lands) when
    /// the app goes inactive: that page is written at once, with the words read while it fell. The landing
    /// then keeps it, with its own read of his words.
    @Test func aTurnStillFallingIsWrittenAsHeLeaves() async throws {
        let o = try await open()
        let before = try await turnAndKeep(o, to: 0.12)
        let turned = try #require(await ReaderSyncTests.locate(o.publication, 0.31))
        o.page.currentLocation = turned
        o.model.turnCommitted()
        for _ in 0..<400 where o.model.fallingWords == nil { await Task.yield() }
        try #require(o.model.fallingWords != nil, "the page beneath the falling leaf gave its words")
        o.model.keepTurnNow()
        let atOnce = try #require(o.saved())
        #expect(atOnce.locations.progression == turned.locations.progression,
                "kept at \(atOnce.locations.progression ?? -1) (before the turn \(before.locations.progression ?? -1)), not the page beneath the falling leaf")
        #expect(atOnce.text.highlight == o.model.fallingWords?.text.highlight, "the words read while the leaf fell were not kept")

        // The leaf lands: his turn's own write keeps the same page, with his words.
        let records = o.model.placeRecords
        o.model.userTurnedPage()
        await o.model.locationDidChange(turned)
        for _ in 0..<400 where o.model.placeRecords == records { await Task.yield() }
        #expect(o.model.placeRecords > records, "the landing's write never landed")
        let after = try #require(o.saved())
        #expect(after.locations.progression == turned.locations.progression)
        #expect(after.text.highlight != nil, "the landing's write never added his words")
        o.model.close()
    }

    /// Never the layout's page: once his turn is written, a later report from the layout (Readium's boundary
    /// moving with no move of his, as a rotation or page numbers coming on do) is not written as he leaves.
    /// Kept, it reopened him a page early (build 17's rotation miss).
    @Test func leavingAfterHisTurnIsWrittenWritesNothing() async throws {
        let o = try await open()
        let read = try await turnAndKeep(o, to: 0.31)
        let kept = try #require(o.saved())
        o.page.currentLocation = try #require(await ReaderSyncTests.locate(o.publication, 0.33))
        o.model.keepTurnNow()
        #expect(o.saved()?.locations.progression == read.locations.progression, "leaving wrote the layout's boundary over his turn")
        #expect(o.saved()?.text.highlight == kept.text.highlight, "leaving dropped his words")
        o.model.close()
    }

    /// Left the moment the leaf lets go, before its page gives any words: Readium's place for that page, bare.
    @Test func aTurnLeftBeforeItsWordsAreReadKeepsReadiumsPlace() async throws {
        let o = try await open()
        _ = try await turnAndKeep(o, to: 0.12)
        let turned = try #require(await ReaderSyncTests.locate(o.publication, 0.31))
        o.page.currentLocation = turned
        o.model.turnCommitted()
        o.model.keepTurnNow()
        let atOnce = try #require(o.saved())
        #expect(atOnce.locations.progression == turned.locations.progression)
        #expect(atOnce.text.highlight == nil, "words from another page went with the place")
        o.model.close()
    }

    /// His turn has landed and its write is on its way when a drag of his begins (the Home swipe can start
    /// one, backward): Readium is on the page beneath the lifted leaf, which may spring back. Leaving then
    /// writes his turn's page, never the page beneath.
    @Test func aLeaveMidDragKeepsTheTurnBeforeIt() async throws {
        let o = try await open()
        _ = try await turnAndKeep(o, to: 0.12)
        let held = LeaveGate()
        o.model.placeWriteWait = { await held.wait() }
        let turned = try #require(await ReaderSyncTests.locate(o.publication, 0.31))
        o.page.currentLocation = turned
        o.model.userTurnedPage()
        for _ in 0..<400 where await held.waiters == 0 { await Task.yield() }
        try #require(await held.waiters == 1, "the turn's write waits on its way")
        o.page.isTurning = true
        let beneath = try #require(await ReaderSyncTests.locate(o.publication, 0.10))
        o.page.currentLocation = beneath
        o.model.keepTurnNow()
        let atOnce = try #require(o.saved())
        #expect(atOnce.locations.progression == turned.locations.progression,
                "kept at \(atOnce.locations.progression ?? -1), the page beneath his drag, not his turn's (\(turned.locations.progression ?? -1))")
        o.page.isTurning = false
        await held.open()
        o.model.close()
    }

    /// Quick turns: the write of one turn is still on its way when the next turn's leaf falls and he
    /// leaves. That older write, landing after the leave, never puts the place back a page.
    @Test func anOlderTurnsWriteLandingAfterTheLeaveKeepsHisLastTurn() async throws {
        let o = try await open()
        _ = try await turnAndKeep(o, to: 0.12)
        let gates = TwoGates()
        o.model.placeWriteWait = { await gates.wait() }
        let first = try #require(await ReaderSyncTests.locate(o.publication, 0.31))
        o.page.currentLocation = first
        o.model.userTurnedPage()
        for _ in 0..<400 where await gates.first.waiters == 0 { await Task.yield() }
        try #require(await gates.first.waiters == 1, "the first turn's write waits on its way")
        let last = try #require(await ReaderSyncTests.locate(o.publication, 0.52))
        o.page.currentLocation = last
        o.model.turnCommitted()
        o.model.keepTurnNow()
        #expect(o.saved()?.locations.progression == last.locations.progression, "leaving didn't keep the falling turn's page")

        // The first turn's write lands late: the place stays on his last turn.
        let records = o.model.placeRecords
        await gates.first.open()
        for _ in 0..<400 where o.model.placeRecords == records { await Task.yield() }
        #expect(o.saved()?.locations.progression == last.locations.progression,
                "the older turn's write put the place back to \(o.saved()?.locations.progression ?? -1)")
        await gates.second.open()
        o.model.close()
    }
}

/// The first place write waits on `first`, every later one on `second`.
actor TwoGates {
    let first = LeaveGate()
    let second = LeaveGate()
    private var calls = 0
    func wait() async {
        calls += 1
        if calls == 1 { await first.wait() } else { await second.wait() }
    }
}
