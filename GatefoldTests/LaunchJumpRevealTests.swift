import Foundation
import GatefoldCore
import ReadiumShared
import Testing
@testable import Gatefold

/// A page a test's launch jump is still on its way to: `pageRange` can't confirm the jump for
/// `readsUnconfirmed` reads (a reflow still laying the chapter out, as on CI's iPad on its side). On its first
/// read the cover's bound runs out and forces the page (`forceReady`). Every read notes whether the reader could
/// see the page while it wasn't yet on the jump's place. Counted in reads, never seconds.
@MainActor
final class SlowLaunchJumpPage: ReaderPage {
    var currentLocation: Locator?
    weak var model: ReaderModel?
    let readsUnconfirmed: Int
    private(set) var reads = 0
    /// Reads made while the page was in view and not yet on the jump's place.
    private(set) var shownBeforeLanding = 0

    init(at start: Locator, readsUnconfirmed: Int) {
        currentLocation = start
        self.readsUnconfirmed = readsUnconfirmed
    }

    private func words(_ here: Locator) -> String { "words at \(here.href.string) \(here.locations.progression ?? -1) on down the page" }

    @discardableResult func go(to locator: Locator) async -> Bool {
        currentLocation = locator
        return true
    }

    func go(to link: ReadiumShared.Link) async {}

    func pageRange() async -> VisibleRange? {
        reads += 1
        if reads == 1, let model, !model.pageReady { model.forceReady() }
        guard reads > readsUnconfirmed else {
            if model?.pageReady == true { shownBeforeLanding += 1 }
            return nil
        }
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

/// gatefold#262 at c01be7c (iPad on its side, job 131123778136): the cover's bound forced the page 12.6 s into
/// the open while the launch jump to 0.31 was still on its way, so the page showed at 0.3003; the jump landed at
/// 0.3099 12.6 s later and moved the words under the test reading them. A test's launch jump shows its page
/// once, after the jump, as the open's settle does.
@MainActor @Suite(.serialized) struct LaunchJumpRevealTests {
    @Test func theCoversBoundNeverShowsAPageTheLaunchJumpIsStillMoving() async throws {
        let sync = StubSync()
        await sync.setLibrary(.success([ReaderSyncTests.frankenstein]))
        await sync.setRemote(nil)
        let app = AppModel(sync: sync, libraryRoot: URL.temporaryDirectory.appending(path: "launch-jump-reveal-\(UUID().uuidString)"))
        await app.library.refresh()
        let publication = try await ReaderSyncTests.publication()
        let book = try #require(app.library.book(ReaderSyncTests.frankenstein.fastHash))
        let opening = Locator(href: try #require(AnyURL(string: publication.readingOrder[0].url().string)), mediaType: .xhtml,
                              locations: .init(progression: 0, totalProgression: 0))
        // Unconfirmed past two resends (every JumpLanding.resendEvery reads).
        let page = SlowLaunchJumpPage(at: opening, readsUnconfirmed: JumpLanding.resendEvery * 3)
        let model = ReaderModel(book: book, publication: publication, app: app, page: page, goTo: 0.31,
                                jumpBeat: { try? await Task.sleep(for: .milliseconds(10)) })
        page.model = model
        let target = try #require(await ReaderSyncTests.locate(publication, 0.31))
        await model.load()
        #expect(page.reads > page.readsUnconfirmed, "the jump never landed: the test proves nothing")
        // The reveal runs on its own task once the jump has landed: counted in looks of the model.
        for _ in 0..<400 where !model.pageReady { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.pageReady, "the page never showed")
        #expect(page.shownBeforeLanding == 0,
                "the page was in view for \(page.shownBeforeLanding) reads before the launch jump reached its place")
        #expect(page.currentLocation?.href.string == target.href.string
                    && page.currentLocation?.locations.progression == target.locations.progression,
                "the page isn't on the launch jump's place")
        model.close()
    }
}
