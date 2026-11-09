import Foundation
import GatefoldCore
import ReadiumShared
import Testing
@testable import Gatefold

/// A page Readium has just reloaded: it reports the file's start while the page on screen, read live, is
/// the file's last page (gatefold#128: a backward turn across files after a reload).
@MainActor
final class ReloadedPage: ReaderPage {
    var currentLocation: Locator?
    /// The page on screen, read live (`pageRange`): where the words really are.
    var live: VisibleRange?
    /// The first words on the page on screen, read live; nil when the page gives none.
    var words: String? = "words at the top of the page on screen"

    init(at location: Locator) { currentLocation = location }

    @discardableResult func go(to locator: Locator) async -> Bool { currentLocation = locator; return true }
    func go(to link: ReadiumShared.Link) async {}

    func visibleRange() async -> VisibleRange? {
        guard let here = currentLocation else { return nil }
        let start = here.locations.progression ?? 0
        return VisibleRange(href: here.href.string, start: start, end: min(1, start + 0.014), text: "words on the page")
    }

    func pageRange() async -> VisibleRange? { live }

    func progression(of quote: String) async -> Double? { currentLocation?.locations.progression }

    func currentAnchor() async -> (ReadingAnchor, Locator)? {
        guard let here = currentLocation else { return nil }
        // As the app's: the words are read from the screen, the progression is Readium's report.
        return (ReadingAnchor(href: here.href.string, progression: here.locations.progression ?? 0, text: words),
                here.copy(text: { $0 = Locator.Text(highlight: self.words) }))
    }
}

@MainActor @Suite(.serialized) struct TurnAfterReloadTests {
    /// He turns back from a chapter's first page onto the previous chapter's last page, and Readium, having
    /// reloaded that chapter, reports its start; `words` are what the page on screen gives as its first words.
    private func turnBackAfterAReload(words: String?) async throws -> (place: Locator, previous: String) {
        let sync = StubSync()
        await sync.setLibrary(.success([ReaderSyncTests.frankenstein]))
        await sync.setRemote(nil)
        let app = AppModel(sync: sync, libraryRoot: URL.temporaryDirectory.appending(path: "turn-reload-\(UUID().uuidString)"))
        await app.library.refresh()
        let publication = try await ReaderSyncTests.publication()
        let book = try #require(app.library.book(ReaderSyncTests.frankenstein.fastHash))
        let next = publication.readingOrder[11].url().string
        let previous = publication.readingOrder[10].url().string
        let opening = Locator(href: try #require(AnyURL(string: next)), mediaType: .xhtml,
                              locations: .init(progression: 0, totalProgression: 0.33))
        let page = ReloadedPage(at: opening)
        let model = ReaderModel(book: book, publication: publication, app: app, page: page)
        await model.load()
        await model.locationDidChange(opening)
        try await Task.sleep(for: .milliseconds(300))

        // The turn back: Readium names the previous chapter's start; the screen shows its last page.
        page.currentLocation = Locator(href: try #require(AnyURL(string: previous)), mediaType: .xhtml,
                                       locations: .init(progression: 0, totalProgression: 0.29))
        page.live = VisibleRange(href: previous, start: 0.986428, end: 1)
        page.words = words
        model.userTurnedPage()

        func saved() -> Locator? {
            app.library.book(ReaderSyncTests.frankenstein.fastHash)?.locatorJSON.flatMap { try? Locator(jsonString: $0) }
        }
        for _ in 0..<80 where saved()?.href.string != previous || (saved()?.locations.progression ?? 0) < 0.9 {
            try await Task.sleep(for: .milliseconds(25))
        }
        let place = try #require(saved(), "no place was saved")
        model.close()
        return (place, previous)
    }

    /// The place saved is the page he sees: in its chapter, on its page, with the page's own first words.
    @Test func aTurnBackAfterAReloadSavesThePageOnScreenNotTheFilesStart() async throws {
        let (place, previous) = try await turnBackAfterAReload(words: "words at the top of the page on screen")
        #expect(place.href.string == previous, "saved in \(place.href.string), not the chapter on screen")
        let p = place.locations.progression ?? -1
        #expect(p >= 0.986428 && p <= 1, "saved at \(p) in the chapter, not on the page on screen (0.986...1)")
        #expect(place.text.highlight == "words at the top of the page on screen", "saved without the page's own words")
    }

    /// A page that gives no words still saves the page he sees, by its progression alone.
    @Test func aTurnBackAfterAReloadWithNoWordsSavesThePagesMiddle() async throws {
        let (place, previous) = try await turnBackAfterAReload(words: nil)
        #expect(place.href.string == previous)
        let p = place.locations.progression ?? -1
        #expect(p >= 0.986428 && p <= 1, "saved at \(p), not on the page on screen (0.986...1)")
        #expect(place.text.highlight == nil, "kept words that weren't the page's")
    }
}
