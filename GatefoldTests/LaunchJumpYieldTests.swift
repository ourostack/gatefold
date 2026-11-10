import Foundation
import GatefoldCore
import ReadiumShared
import Testing
@testable import Gatefold

/// A page a launch jump has reached, whose reads can't confirm it yet (a web view still loading, as on
/// CI's folded Duo): `pageRange` has nothing for `readsUnconfirmed` reads, so the jump keeps reading and
/// resends now and then. At `turnAtRead` he turns to the next page. Counted in reads, never seconds.
@MainActor
final class UnconfirmedJumpPage: ReaderPage {
    var currentLocation: Locator?
    weak var model: ReaderModel?
    let readsUnconfirmed: Int
    let turnAtRead: Int
    var turn: (@MainActor () async -> Void)?
    /// Every jump sent, in order.
    private(set) var jumps: [Locator] = []
    private var reads = 0

    init(at start: Locator, readsUnconfirmed: Int, turnAtRead: Int) {
        currentLocation = start
        self.readsUnconfirmed = readsUnconfirmed
        self.turnAtRead = turnAtRead
    }

    private func words(_ here: Locator) -> String { "words at \(here.href.string) \(here.locations.progression ?? -1) on down the page" }

    @discardableResult func go(to locator: Locator) async -> Bool {
        jumps.append(locator)
        currentLocation = locator
        return true
    }

    func go(to link: ReadiumShared.Link) async {}

    func pageRange() async -> VisibleRange? {
        reads += 1
        if reads == turnAtRead, let turn { self.turn = nil; await turn() }
        guard reads > readsUnconfirmed else { return nil }
        return await visibleRange()
    }

    func visibleRange() async -> VisibleRange? {
        guard let here = currentLocation else { return nil }
        let start = here.locations.progression ?? 0
        return VisibleRange(href: here.href.string, start: start, end: min(1, start + 0.03), text: words(here))
    }

    func progression(of quote: String) async -> Double? { currentLocation?.locations.progression }

    func currentAnchor() async -> (ReadingAnchor, Locator)? {
        guard let here = currentLocation else { return nil }
        let text = words(here)
        let anchor = ReadingAnchor(href: here.href.string, progression: here.locations.progression ?? 0, text: ReaderJS.normalize(text))
        return (anchor, here.copy(text: { $0 = Locator.Text(highlight: text) }))
    }
}

/// A turn of his while a launch jump is still on its way ends the jump: it is never sent again over the
/// page he turned to. CI's folded Duo at c57dfcd (job 129440205332): the page was forced into view while
/// the jump to 0.31 still read as loading; his forward turn landed, then the jump's resend put the page
/// back on 0.31, and the test read "the forward turn didn't happen".
@MainActor @Suite(.serialized) struct LaunchJumpYieldTests {
    @Test func aTurnWhileTheLaunchJumpIsOnItsWayIsNeverJumpedOver() async throws {
        let sync = StubSync()
        await sync.setLibrary(.success([ReaderSyncTests.frankenstein]))
        await sync.setRemote(nil)
        let app = AppModel(sync: sync, libraryRoot: URL.temporaryDirectory.appending(path: "launch-jump-yield-\(UUID().uuidString)"))
        await app.library.refresh()
        let publication = try await ReaderSyncTests.publication()
        let book = try #require(app.library.book(ReaderSyncTests.frankenstein.fastHash))
        let opening = Locator(href: try #require(AnyURL(string: publication.readingOrder[0].url().string)), mediaType: .xhtml,
                              locations: .init(progression: 0, totalProgression: 0))
        // Unconfirmed past two resends (every JumpLanding.resendEvery reads); he turns on the 3rd read.
        let page = UnconfirmedJumpPage(at: opening, readsUnconfirmed: JumpLanding.resendEvery * 3, turnAtRead: 3)
        let model = ReaderModel(book: book, publication: publication, app: app, page: page, goTo: 0.31,
                                jumpBeat: { await Task.yield() })
        page.model = model
        let target = try #require(await ReaderSyncTests.locate(publication, 0.31))
        let next = try #require(await ReaderSyncTests.locate(publication, 0.32))
        page.turn = { [weak model] in
            // His turn: Readium moves to the next page and the reader is told.
            page.currentLocation = next
            model?.userTurnedPage()
        }
        await model.load()
        #expect(page.jumps.count >= 1 && page.jumps.allSatisfy { $0.locations.progression == target.locations.progression })
        #expect(page.turn == nil, "he never turned: the test proves nothing")
        #expect(page.jumps.count == 1, "the launch jump was sent \(page.jumps.count - 1) more time(s) after his turn")
        #expect(page.currentLocation?.href.string == next.href.string
                    && page.currentLocation?.locations.progression == next.locations.progression,
                "the page is back on the jump's place, not the page he turned to")
        // His turn is the place kept, once its write (on its own task) is done.
        func saved() -> Locator? {
            app.library.book(ReaderSyncTests.frankenstein.fastHash)?.locatorJSON.flatMap { try? Locator(jsonString: $0) }
        }
        for _ in 0..<200 where saved()?.locations.progression != next.locations.progression { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(saved()?.href.string == next.href.string && saved()?.locations.progression == next.locations.progression,
                "kept \(saved()?.href.string ?? "nothing") @\(saved()?.locations.progression ?? -1), not the page he turned to")
        model.close()
    }
}
