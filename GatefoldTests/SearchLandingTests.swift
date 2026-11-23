import Foundation
import GatefoldCore
import ReadiumShared
import Testing
@testable import Gatefold

/// A page that places a search match by Readium's progression first, a page past the match, as Readium did on CI
/// for a jump into the preface; once asked for the match's words, it knows their place.
@MainActor
final class MisplacingSearchPage: ReaderPage {
    var currentLocation: Locator?
    weak var model: ReaderModel?
    let exact: Double
    let words: String
    /// For each move of the page: whether the jump's veil was still over the page (the thumb held on the old page).
    var movedUnderVeil: [Bool] = []
    var oldPlace = 0.0

    init(at location: Locator, exact: Double, words: String) {
        currentLocation = location
        self.exact = exact
        self.words = words
    }

    @discardableResult func go(to locator: Locator) async -> Bool {
        movedUnderVeil.append(abs((model?.scrubberPlace ?? -1) - oldPlace) < 0.000_1)
        // A locator with its words is Readium's own placing, by progression: a page past the match.
        let placed = (locator.text.highlight ?? "").isEmpty ? (locator.locations.progression ?? 0) : exact + 0.04
        let here = locator.copy(locations: { $0.progression = placed; $0.totalProgression = 0.02 + placed / 100 },
                                text: { $0 = Locator.Text() })
        currentLocation = here
        await model?.locationDidChange(here)
        return true
    }
    func go(to link: ReadiumShared.Link) async {}

    func visibleRange() async -> VisibleRange? {
        guard let here = currentLocation else { return nil }
        let start = here.locations.progression ?? 0
        let text = abs(start - exact) < 0.000_1 ? words : "the page after the match"
        return VisibleRange(href: here.href.string, start: start, end: min(1, start + 0.03), text: text)
    }
    func progression(of quote: String) async -> Double? { exact }
    func currentAnchor() async -> (ReadingAnchor, Locator)? {
        guard let here = currentLocation else { return nil }
        return (ReadingAnchor(href: here.href.string, progression: here.locations.progression ?? 0, text: "words on the page"), here)
    }
}

/// A search jump lifts its veil on the match's page: he never sees Readium's first placing, a page past the match,
/// and then the page moving to it (review panel 2026-11-22, duo-dark-12 then duo-dark-13).
@MainActor @Suite(.serialized) struct SearchLandingTests {
    @Test func theVeilLiftsOnTheMatchsPage() async throws {
        let sync = StubSync()
        await sync.setLibrary(.success([ReaderSyncTests.frankenstein]))
        await sync.setRemote(nil)
        let app = AppModel(sync: sync, libraryRoot: URL.temporaryDirectory.appending(path: "search-landing-\(UUID().uuidString)"))
        await app.library.refresh()
        let publication = try await ReaderSyncTests.publication()
        let book = try #require(app.library.book(ReaderSyncTests.frankenstein.fastHash))
        let start = Locator(href: try #require(AnyURL(string: publication.readingOrder[10].url().string)), mediaType: .xhtml,
                            locations: .init(progression: 0.4, totalProgression: 0.30))
        let match = Locator(href: try #require(AnyURL(string: publication.readingOrder[2].url().string)), mediaType: .xhtml,
                            locations: .init(progression: 0.5, totalProgression: 0.025),
                            text: .init(after: " conduct given by Wickham", before: "by the false account of ", highlight: "Darcy's"))
        let words = ReaderJS.normalize("provided by the false account of Darcy's conduct given by Wickham, and")
        let page = MisplacingSearchPage(at: start, exact: 0.5, words: words)
        let model = ReaderModel(book: book, publication: publication, app: app, page: page)
        page.model = model
        await model.load()
        await model.locationDidChange(start)
        page.oldPlace = model.scrubberPlace

        await model.go(to: match, rememberBack: true, markingTheMatch: true)

        #expect(page.movedUnderVeil.count >= 2, "the jump never went on to the match's words: \(page.movedUnderVeil)")
        #expect(page.movedUnderVeil.allSatisfy { $0 }, "the page moved to the match after the veil had lifted: \(page.movedUnderVeil)")
        #expect(abs((page.currentLocation?.locations.progression ?? 0) - 0.5) < 0.000_1, "the jump didn't end on the match's page")
        model.close()
    }
}
