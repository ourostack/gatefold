import Foundation
import GatefoldCore
import ReadiumShared
import Testing
@testable import Gatefold

/// A page whose jumps take as long as the test says (a cold Contents jump took 3.6 to 8.8 s in build 19).
@MainActor
final class SlowJumpPage: ReaderPage {
    var currentLocation: Locator?
    private var waiting: CheckedContinuation<Void, Never>?
    var jumping: Bool { waiting != nil }

    init(at location: Locator) { currentLocation = location }

    @discardableResult func go(to locator: Locator) async -> Bool {
        await withCheckedContinuation { waiting = $0 }
        currentLocation = locator
        return true
    }
    func go(to link: ReadiumShared.Link) async {}
    func arrive() { waiting?.resume(); waiting = nil }

    func visibleRange() async -> VisibleRange? {
        guard let here = currentLocation else { return nil }
        let start = here.locations.progression ?? 0
        return VisibleRange(href: here.href.string, start: start, end: min(1, start + 0.03), text: "words on the page")
    }
    func progression(of quote: String) async -> Double? { currentLocation?.locations.progression }
    func currentAnchor() async -> (ReadingAnchor, Locator)? {
        guard let here = currentLocation else { return nil }
        return (ReadingAnchor(href: here.href.string, progression: here.locations.progression ?? 0, text: "words on the page"), here)
    }
}

/// "Back to page" comes up with the page the jump brought, never while the old page is still showing.
@MainActor @Suite(.serialized) struct JumpBackTests {
    @Test func theWayBackWaitsForThePageToMove() async throws {
        let sync = StubSync()
        await sync.setLibrary(.success([ReaderSyncTests.frankenstein]))
        await sync.setRemote(nil)
        let app = AppModel(sync: sync, libraryRoot: URL.temporaryDirectory.appending(path: "jump-back-\(UUID().uuidString)"))
        await app.library.refresh()
        let publication = try await ReaderSyncTests.publication()
        let book = try #require(app.library.book(ReaderSyncTests.frankenstein.fastHash))
        let start = Locator(href: try #require(AnyURL(string: publication.readingOrder[10].url().string)), mediaType: .xhtml,
                            locations: .init(progression: 0.4, totalProgression: 0.30))
        let page = SlowJumpPage(at: start)
        let model = ReaderModel(book: book, publication: publication, app: app, page: page)
        await model.load()
        await model.locationDidChange(start)

        let jump = Task { await model.go(toProgression: 0.7, rememberBack: true) }
        for _ in 0..<100 where !page.jumping { try await Task.sleep(for: .milliseconds(20)) }
        #expect(page.jumping, "the jump reached the page")
        #expect(model.backLocator == nil, "the way back was offered before the page moved")
        page.arrive()
        await jump.value
        #expect(model.backLocator != nil, "the way back was not offered once the page moved")
        // Readium reports where the jump brought him.
        await model.locationDidChange(try #require(page.currentLocation))
        try await Task.sleep(for: .milliseconds(300))

        // A second jump: the first one's way back goes down until the second has landed.
        let second = Task { await model.go(toProgression: 0.2, rememberBack: true) }
        for _ in 0..<100 where !page.jumping { try await Task.sleep(for: .milliseconds(20)) }
        #expect(page.jumping)
        #expect(model.backLocator == nil, "an earlier jump's way back was offered during this one")
        page.arrive()
        await second.value
        #expect(abs((model.backLocator?.locations.totalProgression ?? 0) - 0.7) < 0.05, "the way back isn't to where the first jump went")
        model.close()
    }
}
