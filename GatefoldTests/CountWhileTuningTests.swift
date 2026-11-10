import Foundation
import GatefoldCore
import ReadiumShared
import Testing
@testable import Gatefold

/// A page that keeps a tally of the counts it is asked to start, and never finishes one.
@MainActor
final class CountingTallyPage: ReaderPage {
    var currentLocation: Locator?
    private(set) var countsStarted = 0
    private(set) var countsStopped = 0

    init(at location: Locator) { currentLocation = location }

    @discardableResult func go(to locator: Locator) async -> Bool { currentLocation = locator; return true }
    func go(to link: ReadiumShared.Link) async {}
    func visibleRange() async -> VisibleRange? {
        guard let here = currentLocation else { return nil }
        let start = here.locations.progression ?? 0
        return VisibleRange(href: here.href.string, start: start, end: min(1, start + 0.014), text: "words on the page")
    }
    func progression(of quote: String) async -> Double? { currentLocation?.locations.progression }
    func currentAnchor() async -> (ReadingAnchor, Locator)? {
        guard let here = currentLocation else { return nil }
        return (ReadingAnchor(href: here.href.string, progression: here.locations.progression ?? 0, text: "words"), here)
    }
    func countPages(_ hrefs: [String], record: @escaping @MainActor (String, Int) -> Void, finished: @escaping @MainActor () -> Void) {
        countsStarted += 1
    }
    func stopCounting() { countsStopped += 1 }
}

/// gatefold#162: in landscape on CI each Justify tap in Your Page started a count of the book behind the
/// page (four to six hidden web views), and the next tap threw it away before it counted a chapter. Making
/// them held the main thread for 10-14 s a tap. While Your Page is open he is still tuning the page: no
/// count starts until it closes, and closing it starts one count of the layout he chose.
@MainActor @Suite(.serialized) struct CountWhileTuningTests {
    private func opened() async throws -> (ReaderModel, CountingTallyPage) {
        let sync = StubSync()
        await sync.setLibrary(.success([ReaderSyncTests.frankenstein]))
        await sync.setRemote(nil)
        let app = AppModel(sync: sync, libraryRoot: URL.temporaryDirectory.appending(path: "count-tuning-\(UUID().uuidString)"))
        await app.library.refresh()
        let publication = try await ReaderSyncTests.publication()
        let book = try #require(app.library.book(ReaderSyncTests.frankenstein.fastHash))
        let opening = Locator(href: try #require(AnyURL(string: publication.readingOrder[11].url().string)), mediaType: .xhtml,
                              locations: .init(progression: 0, totalProgression: 0.33))
        let page = CountingTallyPage(at: opening)
        let model = ReaderModel(book: book, publication: publication, app: app, page: page)
        await model.load()
        await model.locationDidChange(opening)
        // The open's own count, once the page is up (counted in reads of the tally, not waited out).
        for _ in 0..<200 where page.countsStarted == 0 { try await Task.sleep(for: .milliseconds(10)) }
        try #require(page.countsStarted >= 1, "the open never started its count")
        // The open asks for numbers more than once (the chapters cleaned, the page shown): settle on its
        // last ask, 60 reads of the tally in a row with no new count.
        var quiet = 0, seen = page.countsStarted
        while quiet < 60 {
            try await Task.sleep(for: .milliseconds(10))
            if page.countsStarted == seen { quiet += 1 } else { seen = page.countsStarted; quiet = 0 }
        }
        return (model, page)
    }

    /// Each Justify change reflows, and each reflow's end asks for the new layout's numbers.
    private func flipJustify(_ model: ReaderModel) async {
        model.setPreferences { $0.justify.toggle() }
        model.reflowDidBegin()
        model.reflowDidFinish(visible: nil)
        await model.refreshScreenNumbers(recount: true)
    }

    @Test func noCountStartsWhileYourPageIsOpenAndClosingItStartsOne() async throws {
        let (model, page) = try await opened()
        model.tuning = true
        let before = page.countsStarted
        for _ in 0..<6 { await flipJustify(model) }
        // The reflows' own asks for numbers run while it's still open, and start nothing.
        for _ in 0..<50 { await Task.yield() }
        #expect(page.countsStarted == before, "\(page.countsStarted - before) counts started behind the page while he tuned it")
        // Meanwhile the number's slot is never blank and never the last layout's number: it says it's counting.
        #expect(model.screenNumbers == nil, "a number from the layout before the change is shown as current")
        #expect(model.countingPages, "the number's slot is blank while the count waits for Your Page to close")
        let tuned = page.countsStarted
        model.tuning = false
        for _ in 0..<200 where page.countsStarted == tuned { try await Task.sleep(for: .milliseconds(10)) }
        for _ in 0..<50 { await Task.yield() }
        #expect(page.countsStarted == tuned + 1, "closing Your Page started \(page.countsStarted - tuned) counts, not one")
        model.close()
    }

    /// Opening Your Page and closing it with nothing changed leaves the count it found alone.
    @Test func closingYourPageWithNothingChangedStartsNoCount() async throws {
        let (model, page) = try await opened()
        let before = page.countsStarted, stoppedBefore = page.countsStopped
        model.tuning = true
        model.tuning = false
        for _ in 0..<50 { await Task.yield() }
        #expect(page.countsStarted == before, "closing an untouched Your Page started \(page.countsStarted - before) counts")
        #expect(page.countsStopped == stoppedBefore, "closing an untouched Your Page stopped the count")
        model.close()
    }

    @Test func withYourPageClosedAChangeStillCountsItsLayout() async throws {
        let (model, page) = try await opened()
        let before = page.countsStarted
        await flipJustify(model)
        #expect(page.countsStarted > before, "a change made outside Your Page never counted its layout")
        model.close()
    }
}
