import Foundation
import GatefoldCore
import ReadiumShared
import Testing
@testable import Gatefold

/// A cold web view taking a launch jump, as Readium did in gatefold#83's run (42468852374): the jump
/// opens its file's first page and Readium reports that page at once; reading the words on screen waits
/// for the web view to load (`evaluateJavaScript` waits for the spread), and the host names the place
/// from Readium's location as it was when the read began. Some reads later the page has loaded and
/// shows the jump's own page. Pages are `span` of the file; counted in reads, never seconds.
@MainActor
final class ColdLaunchPage: ReaderPage {
    var currentLocation: Locator?
    weak var model: ReaderModel?
    let span: Double
    let loadsAtRead: Int
    private var reads = 0
    private var loaded = false
    private var reported = false
    private var lastJump: Locator?
    private var waiting: [CheckedContinuation<Void, Never>] = []
    /// Reports Readium has sent the model, and how many of them the model has finished with.
    private(set) var reportsSent = 0
    private(set) var reportsDone = 0
    /// Where the jump showed its own page once loaded.
    private(set) var landedPage: Locator?

    init(at start: Locator, span: Double, loadsAtRead: Int) {
        currentLocation = start
        self.span = span
        self.loadsAtRead = loadsAtRead
    }

    /// The page that holds `locator`'s place in its file.
    func page(of locator: Locator) -> Locator {
        let p = locator.locations.progression ?? 0
        return locator.copy(locations: { $0.progression = (p / self.span).rounded(.down) * self.span }, text: { $0 = Locator.Text() })
    }

    private func report(_ locator: Locator) {
        reportsSent += 1
        Task { await self.model?.locationDidChange(locator); self.reportsDone += 1 }
    }

    @discardableResult func go(to locator: Locator) async -> Bool {
        lastJump = locator
        if loaded {
            currentLocation = page(of: locator)
            return true
        }
        // Readium's first step on a cold web view: the file's first page, reported once.
        currentLocation = locator.copy(locations: { $0.progression = 0 }, text: { $0 = Locator.Text() })
        if !reported, let here = currentLocation { reported = true; report(here) }
        return true
    }

    func go(to link: ReadiumShared.Link) async {}

    private func load() {
        loaded = true
        if let lastJump {
            landedPage = page(of: lastJump)
            currentLocation = landedPage
        }
        let resumed = waiting
        waiting = []
        for c in resumed { c.resume() }
    }

    func pageRange() async -> VisibleRange? {
        reads += 1
        if !loaded, reads >= loadsAtRead { load() }
        guard loaded else { return nil }
        return await visibleRange()
    }

    func visibleRange() async -> VisibleRange? {
        guard let here = currentLocation else { return nil }
        let start = here.locations.progression ?? 0
        return VisibleRange(href: here.href.string, start: start, end: min(1, start + span), text: words(here))
    }

    private func words(_ here: Locator) -> String { "words at \(here.href.string) \(here.locations.progression ?? -1) on down the page" }

    func progression(of quote: String) async -> Double? { currentLocation?.locations.progression }

    func currentAnchor() async -> (ReadingAnchor, Locator)? {
        // Readium's location is read before the words, as the host does.
        guard let at = currentLocation else { return nil }
        if !loaded { await withCheckedContinuation { waiting.append($0) } }
        guard let live = currentLocation else { return nil }
        let text = words(live)
        let anchor = ReadingAnchor(href: at.href.string, progression: at.locations.progression ?? 0, text: ReaderJS.normalize(text))
        return (anchor, at.copy(text: { $0 = Locator.Text(highlight: text) }))
    }
}

/// gatefold#83: Back after a Contents jump came back to the launch jump's file start, a few pages before
/// the page he had been reading. The file start Readium reported on the jump's way was kept as his move
/// once the web view loaded, after the jump had landed, and the next jump took it as the place to go
/// back to. Judged by page identity: file and progression in it.
@MainActor @Suite(.serialized) struct LaunchJumpBackTests {
    @Test func backAfterAJumpReturnsToThePageTheLaunchJumpLandedOn() async throws {
        let publication = try await ReaderSyncTests.publication()
        // A launch place well inside its file, so its file's first page is a different page.
        var goTo = 0.0
        var target: Locator?
        for candidate in [0.31, 0.33, 0.47, 0.6, 0.72] {
            if let found = await ReaderSyncTests.locate(publication, candidate), (found.locations.progression ?? 0) > 0.2 {
                goTo = candidate
                target = found
                break
            }
        }
        let place = try #require(target, "no launch place well inside its file")

        let sync = StubSync()
        await sync.setLibrary(.success([ReaderSyncTests.frankenstein]))
        await sync.setRemote(nil)
        let app = AppModel(sync: sync, libraryRoot: URL.temporaryDirectory.appending(path: "launch-jump-back-\(UUID().uuidString)"))
        await app.library.refresh()
        let book = try #require(app.library.book(ReaderSyncTests.frankenstein.fastHash))
        let opening = Locator(href: try #require(AnyURL(string: publication.readingOrder[0].url().string)), mediaType: .xhtml,
                              locations: .init(progression: 0, totalProgression: 0))
        // A page is a twentieth of the file, so the place is at least four pages past the file start.
        let page = ColdLaunchPage(at: opening, span: 0.05, loadsAtRead: 4)
        let model = ReaderModel(book: book, publication: publication, app: app, page: page, goTo: goTo)
        page.model = model

        await model.load()
        // Readium's reports run in their own tasks: waited on as events, counted.
        for _ in 0..<400 where page.reportsDone < page.reportsSent { try await Task.sleep(for: .milliseconds(10)) }
        #expect(page.reportsDone == page.reportsSent, "Readium's reports never finished")
        let landed = try #require(page.landedPage, "the launch jump never loaded its page")
        #expect(landed.href.string == place.href.string)
        #expect((landed.locations.progression ?? 0) > 0, "the landed page is its file's first page; the test proves nothing")

        // The place kept for the launch jump is the page it landed on.
        let saved = try #require(app.library.book(ReaderSyncTests.frankenstein.fastHash)?.locatorJSON.flatMap { try? Locator(jsonString: $0) },
                                 "the launch jump kept no place")
        #expect(saved.href.string == landed.href.string && saved.locations.progression == landed.locations.progression,
                "kept \(saved.href.string) @\(saved.locations.progression ?? -1), not the landed page @\(landed.locations.progression ?? -1)")

        // A jump (a Contents pick) offers the way back to the page he left.
        await model.go(toProgression: 0.9, rememberBack: true)
        let back = try #require(model.backLocator, "no way back after the jump")
        #expect(back.href.string == landed.href.string && page.page(of: back).locations.progression == landed.locations.progression,
                "Back goes to \(back.href.string) @\(back.locations.progression ?? -1), not the page he left @\(landed.locations.progression ?? -1)")
        model.close()
    }
}
