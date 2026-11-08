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
    var reported = false
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

    /// Readium's report arriving while the settle is reading the page.
    @Test func aReportDuringTheSettleDoesNotRevealThePage() async throws {
        try await open(reportBeforeLoad: false)
    }

    /// The usual order on a device: Readium's report arrives while load() is still reading the book,
    /// before the settle has begun.
    @Test func aReportBeforeTheSettleDoesNotRevealThePage() async throws {
        try await open(reportBeforeLoad: true)
    }

    private func open(reportBeforeLoad: Bool) async throws {
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
        if reportBeforeLoad {
            page.reported = true
            await model.locationDidChange(guess)
            // Whatever reveal that report started gets its turns before load() reads the page.
            for _ in 0..<10 { await Task.yield() }
        }
        await model.load()
        // The reveal runs on its own task once the open has settled: give it a few turns of the loop.
        for _ in 0..<40 where !model.pageReady { await Task.yield(); try? await Task.sleep(for: .milliseconds(10)) }
        #expect(page.showsHisWords, "the open never settled on his words")
        #expect(page.revealedOnOtherWords == 0, "the page showed \(page.revealedOnOtherWords) reads before his words were on it")
        #expect(model.pageReady, "his page never showed")
        model.close()
    }
}

/// A starved host: the settle's read of his words takes longer than the cover's bound, so the
/// placeholder forces the page into view while the read is still out. Every move of the page is
/// counted by whether the page could be seen then.
@MainActor
final class StarvedOpenPage: ReaderPage {
    var currentLocation: Locator?
    weak var model: ReaderModel?
    let hisWords: String
    let hisPlace: Locator
    var showsHisWords = false
    /// Moves of the page made while it was in view (revealed, with no picture over it).
    private(set) var movesInView = 0
    /// Looks (one per 50 ms) the slow read waited for the forced reveal.
    private(set) var looksWaited = 0
    /// The slow part: the read of his words, or the move to them (looks the move takes).
    let slowMoveLooks: Int?

    init(guess: Locator, hisPlace: Locator, hisWords: String, slowMoveLooks: Int? = nil) {
        currentLocation = guess
        self.hisPlace = hisPlace
        self.hisWords = hisWords
        self.slowMoveLooks = slowMoveLooks
    }

    private var inView: Bool { model.map { $0.pageReady && $0.reopenPicture == nil } ?? false }

    @discardableResult func go(to locator: Locator) async -> Bool {
        // A move begun under the cover that outlasts the cover's bound.
        if let slow = slowMoveLooks, let model, !showsHisWords {
            if !model.pageReady { model.forceReady() }
            for _ in 0..<slow { try? await Task.sleep(for: .milliseconds(50)) }
        }
        if inView { movesInView += 1 }
        currentLocation = hisPlace
        showsHisWords = true
        return true
    }

    func go(to link: ReadiumShared.Link) async {}

    func visibleRange() async -> VisibleRange? {
        guard let here = currentLocation else { return nil }
        let start = here.locations.progression ?? 0
        let text = showsHisWords ? hisWords + " and the rest of his page" : "a page of other words that Readium guessed at first"
        return VisibleRange(href: here.href.string, start: start, end: min(1, start + 0.03), text: text)
    }

    /// The first read outlasts the cover: the placeholder's bound runs out and forces the page, and
    /// only once it is in view does the read come back with his words.
    func progression(of quote: String) async -> Double? {
        guard slowMoveLooks == nil, let model, !showsHisWords else { return hisPlace.locations.progression }
        if !model.pageReady { model.forceReady() }
        while !inView, looksWaited < 400 {
            looksWaited += 1
            try? await Task.sleep(for: .milliseconds(50))
        }
        return hisPlace.locations.progression
    }

    func currentAnchor() async -> (ReadingAnchor, Locator)? {
        guard let here = currentLocation else { return nil }
        let words = showsHisWords ? hisWords : "a page of other words that Readium guessed at first"
        let anchor = ReadingAnchor(href: here.href.string, progression: here.locations.progression ?? 0, text: ReaderJS.normalize(words))
        return (anchor, here.copy(text: { $0 = Locator.Text(highlight: words) }))
    }
}

/// Build 21 on a starved iPad (load about 360): the settle's read took 24 s, the cover's bound forced
/// the page into view, and 0.5 s later the settle moved it to his words. A page in view stays put; his
/// place is offered as a Jump instead.
@MainActor @Suite(.serialized) struct ForcedRevealTests {
    @Test func aSettleThatOutlastsTheCoverOffersHisPlaceInsteadOfMovingThePage() async throws {
        let (model, page, app) = try await open(slowMoveLooks: nil)
        #expect(model.pageReady, "the forced reveal never showed the page")
        #expect(page.looksWaited < 400, "the slow read never saw the forced reveal")
        #expect(page.movesInView == 0, "the settle moved the page \(page.movesInView) times after it was in view")
        #expect(!page.showsHisWords, "the page left the words he was looking at")
        #expect(model.suggestion != nil && model.slip != nil && model.slipKind == .ahead, "his place was not offered on screen")
        // Counted from the page in view (0.30) to his (0.31): a page or so on, never the whole book.
        let detail = model.slip?.detail ?? ""
        let counted = Int(detail.split(separator: " ").first ?? "") ?? 0
        #expect(detail == "Jump back to it" || (detail.hasSuffix(" on") && counted <= 20), "the offer's distance is off: \(detail)")
        #expect(app.library.book(ReaderSyncTests.frankenstein.fastHash)?.localSnapshot?.totalProgression == 0.31,
                "his saved place changed before he chose")
        // Taking the offer goes to his words.
        await model.acceptSuggestion()
        #expect(page.showsHisWords, "the Jump didn't reach his words")
        #expect(model.slip == nil, "the offer stayed up after the Jump")
        model.close()
    }

    /// Taking the offer of his own place goes back to his words with no Back pill: the guessed page he
    /// was shown is not a place to come back to (#49).
    @Test func takingHisOwnPlacePutsUpNoWayBack() async throws {
        let (model, page, _) = try await open(slowMoveLooks: nil)
        #expect(model.suggestion != nil, "his place was not offered")
        await model.acceptSuggestion()
        #expect(page.showsHisWords, "the Jump didn't reach his words")
        #expect(!model.showJumpBack, "taking his own place put up a way back to the guessed page")
        model.close()
    }

    /// The move to his words began under the cover and is still going when the cover's bound runs out:
    /// the reveal waits for it rather than showing the page mid-move.
    @Test func aMoveBegunUnderTheCoverFinishesBeforeTheReveal() async throws {
        let (model, page, _) = try await open(slowMoveLooks: 80)
        for _ in 0..<200 where !model.pageReady { try? await Task.sleep(for: .milliseconds(50)) }
        #expect(model.pageReady, "the page never showed")
        #expect(page.showsHisWords, "the open never reached his words")
        #expect(page.movesInView == 0, "the page moved \(page.movesInView) times while in view")
        model.close()
    }

    /// His own place on offer, then the InkPad's further place arrives: one offer, the InkPad's, never
    /// two stacked; and Stay leaves no offer of his own behind it.
    @Test func aCloudOfferReplacesHisOwnPlaceRatherThanStackingOnIt() async throws {
        let (model, _, _) = try await open(slowMoveLooks: nil, then: { sync, publication in
            guard let mapper = await ReaderSyncTests.mapper(publication) else { return }
            let inkPad = try await ReaderSyncTests.inkPadPlace(publication, mapper, index: 20, percent: 60, updated: Date().addingTimeInterval(60))
            await sync.setRemote(inkPad)
        })
        #expect(model.aheadTab == "Your place", "his own place wasn't offered first")
        await model.checkRemote()
        #expect(model.slip != nil, "no offer is up")
        #expect(model.aheadTab != "Your place" && model.slip?.title != "Where you stopped reading",
                "his own place's offer is still up beside the InkPad's")
        model.dismissSuggestion()
        #expect(model.slip == nil && model.suggestion == nil, "an offer stayed up after Stay")
        model.close()
    }

    private func open(slowMoveLooks: Int?, then: (@MainActor (StubSync, Publication) async throws -> Void)? = nil) async throws -> (ReaderModel, StarvedOpenPage, AppModel) {
        let sync = StubSync()
        await sync.setLibrary(.success([ReaderSyncTests.frankenstein]))
        await sync.setRemote(nil)
        let app = AppModel(sync: sync, libraryRoot: URL.temporaryDirectory.appending(path: "forced-reveal-\(UUID().uuidString)"))
        await app.library.refresh()
        let publication = try await ReaderSyncTests.publication()
        let href = try #require(AnyURL(string: publication.readingOrder[10].url().string))
        let hisPlace = Locator(href: href, mediaType: .xhtml, locations: .init(progression: 0.6, totalProgression: 0.31),
                               text: .init(highlight: OpenRevealTests.hisWords))
        app.library.recordPlace(bookID: ReaderSyncTests.frankenstein.fastHash, locatorJSON: try hisPlace.jsonString() ?? "",
                                totalProgression: 0.31, progression: 0.6)
        let book = try #require(app.library.book(ReaderSyncTests.frankenstein.fastHash))
        let guess = Locator(href: href, mediaType: .xhtml, locations: .init(progression: 0.4, totalProgression: 0.30))
        let page = StarvedOpenPage(guess: guess, hisPlace: hisPlace.copy(text: { $0 = Locator.Text() }), hisWords: OpenRevealTests.hisWords,
                                   slowMoveLooks: slowMoveLooks)
        let model = ReaderModel(book: book, publication: publication, app: app, page: page)
        page.model = model
        await model.load()
        try await then?(sync, publication)
        return (model, page, app)
    }
}
