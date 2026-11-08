import Foundation
import GatefoldCore
import ReadiumShared
import Testing
@testable import Gatefold

/// A cold web view: Readium first shows a page by its own progression, which is not the page his
/// saved words are on, and the words can't be found until the chapter has laid out. Every read of the
/// page notes whether the reader could see it then (`model.pageReady`) while it showed other words.
@MainActor
final class ColdOpenPage: ReaderPage {
    var currentLocation: Locator?
    weak var model: ReaderModel?
    let hisWords: String
    let hisPlace: Locator
    var showsHisWords = false
    /// Reads of the page before his words can be found in it.
    var unfindableReads: Int
    private var reads = 0
    private var reported = false
    /// Reads made while the page was revealed on words other than his.
    private(set) var revealedOnOtherWords = 0

    init(guess: Locator, hisPlace: Locator, hisWords: String, unfindableReads: Int) {
        currentLocation = guess
        self.hisPlace = hisPlace
        self.hisWords = hisWords
        self.unfindableReads = unfindableReads
    }

    private func look() {
        reads += 1
        if model?.pageReady == true, !showsHisWords { revealedOnOtherWords += 1 }
        // Readium reports the page it opened on while the open is still settling.
        if !reported, let model, let here = currentLocation {
            reported = true
            Task { await model.locationDidChange(here) }
        }
    }

    @discardableResult func go(to locator: Locator) async -> Bool {
        currentLocation = hisPlace
        showsHisWords = true
        return true
    }

    func go(to link: ReadiumShared.Link) async {}

    func visibleRange() async -> VisibleRange? {
        look()
        guard let here = currentLocation else { return nil }
        let start = here.locations.progression ?? 0
        let text = showsHisWords ? hisWords + " and the rest of his page" : "a page of other words that Readium guessed at first"
        return VisibleRange(href: here.href.string, start: start, end: min(1, start + 0.03), text: text)
    }

    func progression(of quote: String) async -> Double? {
        look()
        return reads > unfindableReads ? hisPlace.locations.progression : nil
    }

    func currentAnchor() async -> (ReadingAnchor, Locator)? {
        guard let here = currentLocation else { return nil }
        let words = showsHisWords ? hisWords : "a page of other words that Readium guessed at first"
        let anchor = ReadingAnchor(href: here.href.string, progression: here.locations.progression ?? 0, text: ReaderJS.normalize(words))
        return (anchor, here.copy(text: { $0 = Locator.Text(highlight: words) }))
    }
}

/// Build 20 on a cold relaunch with no picture of his page: the page Readium opened on showed, then
/// about 10 s later it jumped to his words. The cover now stays up until the open has settled on them.
@MainActor @Suite(.serialized) struct OpenRevealTests {
    static let hisWords = "the sentence he was reading when he put the book down last night"

    @Test func aColdOpenNeverShowsAPageBeforeHisWords() async throws {
        let sync = StubSync()
        await sync.setLibrary(.success([ReaderSyncTests.frankenstein]))
        await sync.setRemote(nil)
        let app = AppModel(sync: sync, libraryRoot: URL.temporaryDirectory.appending(path: "open-reveal-\(UUID().uuidString)"))
        await app.library.refresh()
        let publication = try await ReaderSyncTests.publication()
        let href = try #require(AnyURL(string: publication.readingOrder[10].url().string))
        let hisPlace = Locator(href: href, mediaType: .xhtml, locations: .init(progression: 0.6, totalProgression: 0.31),
                               text: .init(highlight: Self.hisWords))
        app.library.recordPlace(bookID: ReaderSyncTests.frankenstein.fastHash, locatorJSON: try hisPlace.jsonString() ?? "",
                                totalProgression: 0.31, progression: 0.6)
        let book = try #require(app.library.book(ReaderSyncTests.frankenstein.fastHash))
        let guess = Locator(href: href, mediaType: .xhtml, locations: .init(progression: 0.4, totalProgression: 0.30))
        let page = ColdOpenPage(guess: guess, hisPlace: hisPlace.copy(text: { $0 = Locator.Text() }),
                                hisWords: Self.hisWords, unfindableReads: 4)
        let model = ReaderModel(book: book, publication: publication, app: app, page: page)
        page.model = model
        await model.load()
        // The reveal runs on its own task once the open has settled: give it a few turns of the loop.
        for _ in 0..<40 where !model.pageReady { await Task.yield(); try? await Task.sleep(for: .milliseconds(10)) }
        #expect(page.showsHisWords, "the open never settled on his words")
        #expect(page.revealedOnOtherWords == 0, "the page showed \(page.revealedOnOtherWords) reads before his words were on it")
        #expect(model.pageReady, "his page never showed")
        model.close()
    }
}
