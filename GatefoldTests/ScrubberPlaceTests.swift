import Foundation
import ReadiumShared
import Testing
@testable import Gatefold

/// The thumb stands where the page on screen is. A jump keeps the old page up, dimmed, until the new one has
/// painted, and Readium reports the new place before that: the review panel of 2026-11-22 caught the thumb at the
/// search match's place over the old page (ipad-dark-12; a chapter load took 7.6 s on CI, run 45074395630).
@MainActor @Suite(.serialized) struct ScrubberPlaceTests {
    @Test func theThumbWaitsWithThePageWhileAJumpIsOnItsWay() async throws {
        let sync = StubSync()
        await sync.setLibrary(.success([ReaderSyncTests.frankenstein]))
        await sync.setRemote(nil)
        let app = AppModel(sync: sync, libraryRoot: URL.temporaryDirectory.appending(path: "scrubber-place-\(UUID().uuidString)"))
        await app.library.refresh()
        let publication = try await ReaderSyncTests.publication()
        let book = try #require(app.library.book(ReaderSyncTests.frankenstein.fastHash))
        let start = Locator(href: try #require(AnyURL(string: publication.readingOrder[10].url().string)), mediaType: .xhtml,
                            locations: .init(progression: 0.4, totalProgression: 0.30))
        let page = SlowJumpPage(at: start)
        let model = ReaderModel(book: book, publication: publication, app: app, page: page)
        await model.load()
        await model.locationDidChange(start)
        let shown = model.totalProgression

        let target = Locator(href: try #require(AnyURL(string: publication.readingOrder[publication.readingOrder.count * 3 / 4].url().string)), mediaType: .xhtml,
                             locations: .init(progression: 0.5, totalProgression: 0.70))
        let jump = Task { await model.go(to: target, rememberBack: true) }
        for _ in 0..<100 where !page.jumping { try await Task.sleep(for: .milliseconds(20)) }
        #expect(page.jumping, "the jump reached the page")
        // Readium names the new place while the old page is still the one on screen.
        await model.locationDidChange(target)
        #expect(abs(model.scrubberPlace - shown) < 0.005, "the thumb ran ahead of the page: \(model.scrubberPlace), page \(shown)")

        page.arrive()
        await jump.value
        await model.locationDidChange(try #require(page.currentLocation))
        let landed = try #require(page.currentLocation?.locations.totalProgression)
        #expect(abs(model.scrubberPlace - landed) < 0.005, "the thumb didn't follow the page once it came: \(model.scrubberPlace), page \(landed)")
        model.close()
    }
}
