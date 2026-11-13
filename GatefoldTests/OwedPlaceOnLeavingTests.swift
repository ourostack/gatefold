import Foundation
import GatefoldCore
import ReadiumShared
import Testing
@testable import Gatefold

/// A move he makes while a reflow is laying out (a turn while the iPad's rotation settles) is owed: the
/// reflow's end records it. A reflow that never settles (a slow device, a load stuck as in gatefold#94)
/// never ends, so leaving dropped the move, and the reopen came back where he was before it
/// (gatefold#96). Judged in reports and reads, never seconds.
@MainActor @Suite(.serialized) struct OwedPlaceOnLeavingTests {
    @Test func aTurnUnderAReflowThatNeverSettlesIsKeptWhenHeClosesTheBook() async throws {
        let sync = StubSync()
        await sync.setLibrary(.success([ReaderSyncTests.frankenstein]))
        await sync.setRemote(nil)
        let app = AppModel(sync: sync, libraryRoot: URL.temporaryDirectory.appending(path: "owed-on-leaving-\(UUID().uuidString)"))
        await app.library.refresh()
        let publication = try await ReaderSyncTests.publication()
        let book = try #require(app.library.book(ReaderSyncTests.frankenstein.fastHash))
        let first = publication.readingOrder[0].url().string
        let opening = Locator(href: try #require(AnyURL(string: first)), mediaType: .xhtml,
                              locations: .init(progression: 0, totalProgression: 0))
        let page = TwoStepJumpPage(at: opening, readsToLand: 1)
        let model = ReaderModel(book: book, publication: publication, app: app, page: page)
        page.model = model
        await model.load()

        // He turns the iPad, and turns the page while its reflow lays out; the reflow never settles.
        model.keeper.reflowWillBegin(.rotation)
        model.reflowDidBegin()
        let turned = try #require(await ReaderSyncTests.locate(publication, 0.31))
        page.currentLocation = turned
        model.userTurnedPage()
        for _ in 0..<200 where !model.placeOwed { await Task.yield() }
        #expect(model.placeOwed, "the turn under the reflow is owed")

        // He closes the book with the reflow still under way.
        model.close()
        func savedPlace() -> Locator? {
            app.library.book(ReaderSyncTests.frankenstein.fastHash)?.locatorJSON.flatMap { try? Locator(jsonString: $0) }
        }
        for _ in 0..<200 where savedPlace()?.locations.progression != turned.locations.progression {
            try await Task.sleep(for: .milliseconds(25))
        }
        let saved = try #require(savedPlace(), "leaving kept no place")
        #expect(saved.href.string == turned.href.string)
        #expect(saved.locations.progression == turned.locations.progression,
                "kept at \(saved.locations.progression ?? -1) in its file, not the page he turned to (\(turned.locations.progression ?? -1))")
    }

    /// The app only went inactive (Control Center, a notification) and came back: the owed move was
    /// written as he seemed to leave, and the reflow, settling after all, still records his own words
    /// over it, as it does with no leaving at all.
    @Test func aReflowThatSettlesAfterAnInactiveMomentStillKeepsHisWords() async throws {
        let sync = StubSync()
        await sync.setLibrary(.success([ReaderSyncTests.frankenstein]))
        await sync.setRemote(nil)
        let app = AppModel(sync: sync, libraryRoot: URL.temporaryDirectory.appending(path: "owed-inactive-\(UUID().uuidString)"))
        await app.library.refresh()
        let publication = try await ReaderSyncTests.publication()
        let book = try #require(app.library.book(ReaderSyncTests.frankenstein.fastHash))
        let first = publication.readingOrder[0].url().string
        let opening = Locator(href: try #require(AnyURL(string: first)), mediaType: .xhtml,
                              locations: .init(progression: 0, totalProgression: 0))
        let page = TwoStepJumpPage(at: opening, readsToLand: 1)
        let model = ReaderModel(book: book, publication: publication, app: app, page: page)
        page.model = model
        await model.load()
        model.keeper.reflowWillBegin(.rotation)
        model.reflowDidBegin()
        let turned = try #require(await ReaderSyncTests.locate(publication, 0.31))
        page.currentLocation = turned
        model.userTurnedPage()
        for _ in 0..<200 where !model.placeOwed { await Task.yield() }
        func savedPlace() -> Locator? {
            app.library.book(ReaderSyncTests.frankenstein.fastHash)?.locatorJSON.flatMap { try? Locator(jsonString: $0) }
        }

        // Inactive: the owed move is written now, Readium's page only (no words yet).
        let owed = try #require(model.owedPlaceOnLeaving())
        await model.keepOwedPlace(owed)
        #expect(savedPlace()?.locations.progression == turned.locations.progression, "the inactive moment kept the turn")
        #expect(savedPlace()?.text.highlight == nil)
        #expect(model.placeOwed, "the reader is still open: the reflow still owes his words")

        // Back, and the reflow settles: his words are the place.
        model.keeper.restoreDidComplete()
        model.reflowDidFinish(visible: await page.visibleRange())
        for _ in 0..<200 where model.placeOwed || savedPlace()?.text.highlight == nil {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(!model.placeOwed, "the reflow paid its debt")
        let saved = try #require(savedPlace())
        #expect(saved.locations.progression == turned.locations.progression)
        #expect(saved.text.highlight != nil, "the settled reflow's capture of his words was not kept last")
        model.close()
    }

    /// A restore that stalls after a rotation leaves him the page as it was (gatefold#133). Closing writes
    /// that page in the close itself, before any Task or wait: the words and their mapped position may
    /// never come while the page is stalled, and the app may be ended a moment later. His words, noted
    /// before he left, go with it; the mapped position, when it comes, lands on the same place. Fails if
    /// the leave write waits on the mapping's path (`placeWriteWait`, then the mapping) or on a Task hop.
    @Test func thePageAStalledRestoreLeftIsWrittenBeforeAnyWait() async throws {
        let sync = StubSync()
        await sync.setLibrary(.success([ReaderSyncTests.frankenstein]))
        await sync.setRemote(nil)
        let app = AppModel(sync: sync, libraryRoot: URL.temporaryDirectory.appending(path: "shown-on-leaving-\(UUID().uuidString)"))
        await app.library.refresh()
        let publication = try await ReaderSyncTests.publication()
        let book = try #require(app.library.book(ReaderSyncTests.frankenstein.fastHash))
        let first = publication.readingOrder[0].url().string
        let opening = Locator(href: try #require(AnyURL(string: first)), mediaType: .xhtml,
                              locations: .init(progression: 0, totalProgression: 0))
        let page = TwoStepJumpPage(at: opening, readsToLand: 1)
        let model = ReaderModel(book: book, publication: publication, app: app, page: page)
        page.model = model
        await model.load()
        func savedPlace() -> Locator? {
            app.library.book(ReaderSyncTests.frankenstein.fastHash)?.locatorJSON.flatMap { try? Locator(jsonString: $0) }
        }

        // He reads on a little: a turn, kept as his place.
        let read = try #require(await ReaderSyncTests.locate(publication, 0.12))
        page.currentLocation = read
        model.userTurnedPage()
        await model.locationDidChange(read)
        for _ in 0..<200 where savedPlace()?.locations.progression != read.locations.progression { await Task.yield() }
        try #require(savedPlace()?.locations.progression == read.locations.progression, "his turn was kept")

        // He rotates; the restore stalls, and the page is shown as it is, not the page he turned to.
        model.keeper.reflowWillBegin(.rotation)
        model.reflowDidBegin()
        let shownPage = try #require(await ReaderSyncTests.locate(publication, 0.31))
        let withWords = shownPage.copy(text: { $0.highlight = "placeholder words" })
        let note = try #require(model.reflowShownUnsettled(shownPage))
        try #require(model.reflowShownUnsettled(withWords, wordsFor: note) != nil, "his words noted for the page shown")

        // The words' path never comes back while he is leaving.
        let held = LeaveGate()
        model.placeWriteWait = { await held.wait() }
        // He closes the book: the place is the shown page by the time the close returns, with no yield.
        model.close()
        let atOnce = try #require(savedPlace(), "leaving kept no place")
        #expect(atOnce.href.string == shownPage.href.string)
        #expect(atOnce.locations.progression == shownPage.locations.progression,
                "kept at \(atOnce.locations.progression ?? -1), not the shown page (\(shownPage.locations.progression ?? -1)), while the words' path waits")
        #expect(atOnce.text.highlight == withWords.text.highlight, "the first write didn't carry the words noted before he left")

        // The words come: on the same place, never another.
        await held.open()
        // The mapping reads the chapter off the main actor: bounded polls, as the tests above wait on writes.
        for _ in 0..<200 where model.shownLeaveSteps.count < 2 { try await Task.sleep(for: .milliseconds(25)) }
        #expect(model.shownLeaveSteps == ["written", "position mapped (cfi)"], "steps \(model.shownLeaveSteps)")
        let after = try #require(savedPlace())
        #expect(after.locations.progression == shownPage.locations.progression, "the mapped position moved the place")
        #expect(after.text.highlight == withWords.text.highlight, "the mapped position's write replaced his noted words")
    }

    /// The page shown under a stalled restore is the page his own turn kept, and the page gave no words
    /// before he left. Written as Readium's location alone, the leave replaced his words with a bare
    /// progression on a page boundary, and the reopen came back one page early (gatefold#133, #238's run
    /// at b7c5fc2: his page's start 616 characters into the reopened page). The same place keeps his words.
    @Test func leavingOnThePageHisTurnKeptKeepsHisWordsWhenThePageGivesNone() async throws {
        let sync = StubSync()
        await sync.setLibrary(.success([ReaderSyncTests.frankenstein]))
        await sync.setRemote(nil)
        let app = AppModel(sync: sync, libraryRoot: URL.temporaryDirectory.appending(path: "shown-same-\(UUID().uuidString)"))
        await app.library.refresh()
        let publication = try await ReaderSyncTests.publication()
        let book = try #require(app.library.book(ReaderSyncTests.frankenstein.fastHash))
        let first = publication.readingOrder[0].url().string
        let opening = Locator(href: try #require(AnyURL(string: first)), mediaType: .xhtml,
                              locations: .init(progression: 0, totalProgression: 0))
        let page = TwoStepJumpPage(at: opening, readsToLand: 1)
        let model = ReaderModel(book: book, publication: publication, app: app, page: page)
        page.model = model
        await model.load()
        func savedPlace() -> Locator? {
            app.library.book(ReaderSyncTests.frankenstein.fastHash)?.locatorJSON.flatMap { try? Locator(jsonString: $0) }
        }

        // He turns: the place kept carries his first words.
        let read = try #require(await ReaderSyncTests.locate(publication, 0.31))
        page.currentLocation = read
        model.userTurnedPage()
        await model.locationDidChange(read)
        for _ in 0..<200 where savedPlace()?.text.highlight == nil { await Task.yield() }
        let his = try #require(savedPlace()?.text.highlight, "his turn was kept with his words")
        try #require(savedPlace()?.locations.progression == read.locations.progression)

        // He rotates; the restore stalls on that same page, shown as it is, and no words come before he leaves.
        model.keeper.reflowWillBegin(.rotation)
        model.reflowDidBegin()
        try #require(model.reflowShownUnsettled(read.copy(text: { $0 = Locator.Text() })) != nil)
        model.close()
        let kept = try #require(savedPlace(), "leaving kept no place")
        #expect(kept.locations.progression == read.locations.progression)
        #expect(kept.text.highlight == his, "the leave write dropped his words on the same place")
        // The mapped position follows on the same place, his words with it.
        for _ in 0..<200 where model.shownLeaveSteps.count < 2 { try await Task.sleep(for: .milliseconds(25)) }
        #expect(model.shownLeaveSteps == ["written", "position mapped (cfi)"], "steps \(model.shownLeaveSteps)")
        #expect(savedPlace()?.text.highlight == his, "the mapped position's write dropped his words")
    }

    /// Opened on his saved place with words, rotated, stalled on that same page and left with no move:
    /// nothing moved since the place was kept, so it keeps his words (the gap the #133 ruling left open).
    @Test func leavingTheOpenedPageUnderAStalledRestoreKeepsItsWords() async throws {
        let sync = StubSync()
        await sync.setLibrary(.success([ReaderSyncTests.frankenstein]))
        await sync.setRemote(nil)
        let app = AppModel(sync: sync, libraryRoot: URL.temporaryDirectory.appending(path: "shown-opened-\(UUID().uuidString)"))
        await app.library.refresh()
        let publication = try await ReaderSyncTests.publication()
        let id = ReaderSyncTests.frankenstein.fastHash
        let place = try #require(await ReaderSyncTests.locate(publication, 0.31))
        // A stand-in for his saved words, never a book's.
        let saved = place.copy(text: { $0 = Locator.Text(highlight: "stand-in words of his saved page") })
        app.library.recordPlace(bookID: id, locatorJSON: try #require(try saved.jsonString()),
                                totalProgression: saved.locations.totalProgression ?? 0,
                                progression: saved.locations.progression ?? 0, at: Date())
        let book = try #require(app.library.book(id))
        let page = TwoStepJumpPage(at: place, readsToLand: 1)
        let model = ReaderModel(book: book, publication: publication, app: app, page: page)
        page.model = model
        await model.load()
        func savedPlace() -> Locator? {
            app.library.book(id)?.locatorJSON.flatMap { try? Locator(jsonString: $0) }
        }
        let kept = try #require(savedPlace())
        let words = try #require(kept.text.highlight, "the opened place has words")

        model.keeper.reflowWillBegin(.rotation)
        model.reflowDidBegin()
        try #require(model.reflowShownUnsettled(kept.copy(text: { $0 = Locator.Text() })) != nil)
        model.close()
        let left = try #require(savedPlace(), "leaving kept no place")
        #expect(left.locations.progression == kept.locations.progression)
        #expect(left.text.highlight == words, "leaving the opened page dropped its words")
    }

    /// A model opened, read on with one turn (kept with stand-in words), then rotated with the restore
    /// stalled: the shared start of gatefold#276's tests.
    private func stalledAfterATurn(_ name: String, page onPage: ((TwoStepJumpPage) -> Void)? = nil) async throws
        -> (model: ReaderModel, read: Locator, his: String, saved: () -> Locator?) {
        let sync = StubSync()
        await sync.setLibrary(.success([ReaderSyncTests.frankenstein]))
        await sync.setRemote(nil)
        let app = AppModel(sync: sync, libraryRoot: URL.temporaryDirectory.appending(path: "\(name)-\(UUID().uuidString)"))
        await app.library.refresh()
        let publication = try await ReaderSyncTests.publication()
        let book = try #require(app.library.book(ReaderSyncTests.frankenstein.fastHash))
        let first = publication.readingOrder[0].url().string
        let opening = Locator(href: try #require(AnyURL(string: first)), mediaType: .xhtml,
                              locations: .init(progression: 0, totalProgression: 0))
        let page = TwoStepJumpPage(at: opening, readsToLand: 1)
        onPage?(page)
        let model = ReaderModel(book: book, publication: publication, app: app, page: page)
        page.model = model
        await model.load()
        let saved = { app.library.book(ReaderSyncTests.frankenstein.fastHash)?.locatorJSON.flatMap { try? Locator(jsonString: $0) } }
        let read = try #require(await ReaderSyncTests.locate(publication, 0.31))
        page.currentLocation = read
        model.userTurnedPage()
        await model.locationDidChange(read)
        for _ in 0..<200 where saved()?.text.highlight == nil { await Task.yield() }
        let his = try #require(saved()?.text.highlight, "his turn was kept with his words")
        model.keeper.reflowWillBegin(.rotation)
        model.reflowDidBegin()
        return (model, read, his, saved)
    }

    /// gatefold#276 (PR #285's run 43147454242): under the stalled restore Readium still named the chapter's
    /// start while the screen showed a page further on. Left with no words, the place was that chapter
    /// start, and the reopen opened there. The page on screen is what is kept.
    @Test func leavingAStalledPageKeepsThePageOnScreenNotReadiumsStaleLocation() async throws {
        let (model, read, _, saved) = try await stalledAfterATurn("shown-stale")
        let p = try #require(read.locations.progression)
        let screen = max(0, p - 0.06)...max(0, p - 0.02)
        let stale = read.copy(locations: { $0.progression = 0 }, text: { $0 = Locator.Text() })
        let note = try #require(model.reflowShownUnsettled(stale, onScreen: screen))
        // The page's words come paired with Readium's stale name: only the words are taken.
        let named = stale.copy(text: { $0 = Locator.Text(highlight: "stand-in words of the page on screen") })
        try #require(model.reflowShownUnsettled(named, wordsFor: note) != nil, "the words noted for the page shown")
        model.close()
        let left = try #require(saved(), "leaving kept no place")
        let at = try #require(left.locations.progression)
        #expect(left.href.string == read.href.string)
        #expect(at > screen.lowerBound && at < screen.upperBound,
                "kept at in-file \(at), not on the page on screen (\(screen.lowerBound)..\(screen.upperBound))")
        #expect(left.text.highlight == named.text.highlight, "the page's words weren't kept with it")
        let total = try #require(left.locations.totalProgression)
        #expect(total > 0 && total < (read.locations.totalProgression ?? 0),
                "its total progression \(total) isn't the page on screen's, before his page")
    }

    /// gatefold#276 (CI 43075159905): Readium's location for the page shown was the page's first column,
    /// a page boundary, and the reopen landed one page early (his page's start 616 characters in). The
    /// place kept sits inside the page on screen, so the reopen can't round onto the page before.
    @Test func leavingAStalledPageKeepsAPlaceInsideItNotOnItsBoundary() async throws {
        let (model, read, _, saved) = try await stalledAfterATurn("shown-edge")
        let p = try #require(read.locations.progression)
        let start = max(0, p - 0.06)
        let screen = start...(start + 0.04)
        let edge = read.copy(locations: { $0.progression = start }, text: { $0 = Locator.Text() })
        try #require(model.reflowShownUnsettled(edge, onScreen: screen) != nil)
        model.close()
        let at = try #require(saved()?.locations.progression)
        #expect(at > screen.lowerBound + 0.01 && at < screen.upperBound - 0.01,
                "kept at in-file \(at), on the page's edge (\(screen.lowerBound)..\(screen.upperBound))")
    }

    /// The page on screen starts at his kept place: it is the page his turn kept, so his words stay
    /// with it (gatefold#133), read from the screen as from Readium.
    @Test func leavingOnHisKeptPageReadFromTheScreenKeepsHisWords() async throws {
        let (model, read, his, saved) = try await stalledAfterATurn("shown-his")
        let p = try #require(read.locations.progression)
        let screen = p...min(1, p + 0.04)
        try #require(model.reflowShownUnsettled(read.copy(text: { $0 = Locator.Text() }), onScreen: screen) != nil)
        model.close()
        let left = try #require(saved(), "leaving kept no place")
        #expect(left.locations.progression == p)
        #expect(left.text.highlight == his, "leaving his own page, read from the screen, dropped his words")
    }

    /// gatefold#346 (CI 43321734349 and 43370826599): at the watchdog the screen's span couldn't be read, and
    /// Readium still named the page from before the rotation, his kept place. Left so, that stale name took
    /// his words, and the chapter-start reopen opened on his portrait page, not the spread he saw. Read from
    /// the screen as he leaves, the page on screen is kept, without words that don't start it.
    @Test func leavingAPageNamedStaleWithItsSpanUnreadKeepsThePageOnScreenReadAsHeLeaves() async throws {
        var stub: TwoStepJumpPage?
        let (model, read, his, saved) = try await stalledAfterATurn("shown-late") { stub = $0 }
        let page = try #require(stub)
        let p = try #require(read.locations.progression)
        // His kept page's start sits inside the spread on screen, not at its start.
        let screen = max(0, p - 0.02)...min(1, p + 0.04)
        try #require(model.reflowShownUnsettled(read.copy(text: { $0 = Locator.Text() })) != nil)
        page.spanNow = screen
        model.close()
        let left = try #require(saved(), "leaving kept no place")
        let at = try #require(left.locations.progression)
        #expect(at > screen.lowerBound && at < screen.upperBound,
                "kept at in-file \(at), not on the page on screen (\(screen.lowerBound)..\(screen.upperBound))")
        #expect(at != p, "kept at Readium's stale name, his kept place, not the page on screen")
        #expect(left.text.highlight != his, "the stale name took his words to a page that doesn't start with them")
    }

    /// The span read as he leaves starts at his kept place: it is his kept page after all, and his words
    /// stay with it (gatefold#133).
    @Test func leavingAPageNamedAtHisPlaceWithItsSpanReadAsHeLeavesKeepsHisWords() async throws {
        var stub: TwoStepJumpPage?
        let (model, read, his, saved) = try await stalledAfterATurn("shown-late-his") { stub = $0 }
        let page = try #require(stub)
        let p = try #require(read.locations.progression)
        try #require(model.reflowShownUnsettled(read.copy(text: { $0 = Locator.Text() })) != nil)
        page.spanNow = p...min(1, p + 0.04)
        model.close()
        let left = try #require(saved(), "leaving kept no place")
        #expect(left.locations.progression == p)
        #expect(left.text.highlight == his, "leaving his own page, read as he left, dropped his words")
    }
}

/// A page whose jump goes out and is never reported: the chapter it went to is still loading (Readium's
/// spinner up, its location still the page before) when he leaves.
@MainActor
final class UnreportedJumpPage: ReaderPage {
    var currentLocation: Locator?
    private(set) var sent: [Locator] = []
    /// The words of the page once its chapter has loaded (none while it loads).
    var words: String?
    init(at location: Locator) { currentLocation = location }
    @discardableResult func go(to locator: Locator) async -> Bool { sent.append(locator); return true }
    func go(to link: ReadiumShared.Link) async {}
    func visibleRange() async -> VisibleRange? {
        guard let words, let here = currentLocation else { return nil }
        let start = here.locations.progression ?? 0
        return VisibleRange(href: here.href.string, start: start, end: min(1, start + 0.03), text: words)
    }
    func progression(of quote: String) async -> Double? { words == nil ? nil : currentLocation?.locations.progression }
    func currentAnchor() async -> (ReadingAnchor, Locator)? {
        guard let words, let here = currentLocation else { return nil }
        // As the host does: the place it reads carries the words it found.
        return (ReadingAnchor(href: here.href.string, progression: here.locations.progression ?? 0, text: words),
                here.copy(text: { $0 = Locator.Text(highlight: words) }))
    }
}

/// gatefold#279: a scrubber jump from the opening page whose chapter is still loading when he leaves,
/// no turn. Readium never reported the jump's page, so nothing was written, and the reopen had no place
/// at all ("opening on none"). The place he chose is kept: the jump's target, never the page before it.
@MainActor @Suite(.serialized) struct LeavingAScrubberJumpOnItsWayTests {
    private func open(_ name: String) async throws -> (AppModel, ReaderModel, UnreportedJumpPage) {
        let sync = StubSync()
        await sync.setLibrary(.success([ReaderSyncTests.frankenstein]))
        await sync.setRemote(nil)
        let app = AppModel(sync: sync, libraryRoot: URL.temporaryDirectory.appending(path: "\(name)-\(UUID().uuidString)"))
        await app.library.refresh()
        let publication = try await ReaderSyncTests.publication()
        let book = try #require(app.library.book(ReaderSyncTests.frankenstein.fastHash))
        let first = publication.readingOrder[0].url().string
        let opening = Locator(href: try #require(AnyURL(string: first)), mediaType: .xhtml,
                              locations: .init(progression: 0, totalProgression: 0))
        let page = UnreportedJumpPage(at: opening)
        let model = ReaderModel(book: book, publication: publication, app: app, page: page)
        await model.load()
        return (app, model, page)
    }

    private func savedPlace(_ app: AppModel) -> Locator? {
        app.library.book(ReaderSyncTests.frankenstein.fastHash)?.locatorJSON.flatMap { try? Locator(jsonString: $0) }
    }

    @Test func closingOnAScrubberJumpStillLoadingKeepsItsTarget() async throws {
        let (app, model, page) = try await open("scrub-leave-close")
        await model.go(toProgression: 0.43, rememberBack: true)
        let target = try #require(page.sent.last, "the jump went out")
        model.close()
        for _ in 0..<200 where savedPlace(app) == nil { try await Task.sleep(for: .milliseconds(25)) }
        let saved = try #require(savedPlace(app), "leaving kept no place")
        #expect(saved.href.string == target.href.string)
        #expect(saved.locations.progression == target.locations.progression,
                "kept at \(saved.locations.progression ?? -1) in its file, not the jump's target (\(target.locations.progression ?? -1))")
    }

    @Test func goingInactiveOnAScrubberJumpStillLoadingKeepsItsTarget() async throws {
        let (app, model, page) = try await open("scrub-leave-inactive")
        await model.go(toProgression: 0.43, rememberBack: true)
        let target = try #require(page.sent.last, "the jump went out")
        // As the app does when it goes inactive (GatefoldApp's scene phase).
        let owed = try #require(model.owedPlaceOnLeaving(), "leaving owed no place")
        model.keepShownPageNow(owed)
        await model.keepOwedPlace(owed)
        for _ in 0..<200 where savedPlace(app) == nil { try await Task.sleep(for: .milliseconds(25)) }
        let saved = try #require(savedPlace(app), "leaving kept no place")
        #expect(saved.href.string == target.href.string)
        #expect(saved.locations.progression == target.locations.progression)

        // He comes back, the chapter loads, and Readium reports the jump's page: that report still writes
        // his page and its words over the target the leave kept (the debt left open for it).
        page.words = "stand-in-words-of-the-jumped-page"
        page.currentLocation = target
        await model.locationDidChange(target)
        for _ in 0..<200 where savedPlace(app)?.text.highlight == nil { try await Task.sleep(for: .milliseconds(25)) }
        #expect(savedPlace(app)?.text.highlight != nil, "the jump's own report wrote no words after the inactive leave")
        #expect(!model.placeOwed, "the jump's report left the leave's debt standing")
        model.close()
    }

    /// gatefold#309: the leave's ordinary write reads the page first, and the chapter still loading held that
    /// read until iOS had ended Gatefold: the target was logged as kept and never written. It is written as he
    /// leaves, in leaving's own turn, before any wait (the write's wait held for good here).
    @Test func goingInactiveOnAScrubberJumpStillLoadingWritesItsTargetBeforeAnyWait() async throws {
        let (app, model, page) = try await open("scrub-leave-at-once")
        await model.go(toProgression: 0.43, rememberBack: true)
        let target = try #require(page.sent.last, "the jump went out")
        model.placeWriteWait = { await LeaveGate().wait() }
        let owed = try #require(model.owedPlaceOnLeaving(), "leaving owed no place")
        model.keepShownPageNow(owed)
        let saved = try #require(savedPlace(app), "leaving wrote nothing before its wait")
        #expect(saved.href.string == target.href.string)
        #expect(saved.locations.progression == target.locations.progression)
    }

    @Test func closingOnAScrubberJumpStillLoadingWritesItsTargetBeforeAnyWait() async throws {
        let (app, model, page) = try await open("scrub-close-at-once")
        await model.go(toProgression: 0.43, rememberBack: true)
        let target = try #require(page.sent.last, "the jump went out")
        model.placeWriteWait = { await LeaveGate().wait() }
        model.close()
        let saved = try #require(savedPlace(app), "the close wrote nothing before its wait")
        #expect(saved.href.string == target.href.string)
        #expect(saved.locations.progression == target.locations.progression)
    }

    /// The same inactive leave, with the jump's own report arriving while the leave still writes its
    /// target (held in its wait): the report is his page and its words, never dropped as already kept,
    /// and the target written after it never replaces them.
    @Test func theJumpsOwnReportDuringTheInactiveLeavesWriteKeepsHisWords() async throws {
        let (app, model, page) = try await open("scrub-leave-race")
        // Readium names the opening page before the jump, as it does once the book opens.
        let opening = try #require(page.currentLocation)
        await model.locationDidChange(opening)
        await model.go(toProgression: 0.43, rememberBack: true)
        let target = try #require(page.sent.last, "the jump went out")
        let gate = LeaveGate()
        model.placeWriteWait = { await gate.wait() }
        let owed = try #require(model.owedPlaceOnLeaving(), "leaving owed no place")
        model.keepShownPageNow(owed)
        let leave = Task { await model.keepOwedPlace(owed) }
        for _ in 0..<200 where await gate.waiters < 1 { await Task.yield() }
        #expect(await gate.waiters == 1, "the leave's write reached its wait")

        // A re-report of the page before the jump (the layout as the app goes inactive) is not the jump's.
        let stray = Task { await model.locationDidChange(opening) }
        await stray.value
        #expect(await gate.waiters == 1, "a re-report of the page before the jump was written as his move")

        // The chapter loads and Readium reports the jump's page while the leave's write waits.
        page.words = "stand-in-words-of-the-jumped-page"
        page.currentLocation = target
        let report = Task { await model.locationDidChange(target) }
        for _ in 0..<400 where await gate.waiters < 2 { await Task.yield() }
        #expect(await gate.waiters == 2, "the jump's report was dropped as already kept")
        await gate.open()
        await leave.value
        await report.value
        for _ in 0..<200 where savedPlace(app)?.text.highlight == nil { try await Task.sleep(for: .milliseconds(25)) }
        let saved = try #require(savedPlace(app))
        #expect(saved.text.highlight != nil, "his page's words were lost to the target the leave wrote")
        #expect(saved.locations.progression == target.locations.progression)

        // The layout then names a boundary on the same page, with no move of his since: one move, one place,
        // so his words stand (the leave handed nothing back after the report wrote).
        let boundary = target.copy(locations: { $0.progression = max(0, ($0.progression ?? 0) - 0.01) })
        page.words = nil
        page.currentLocation = boundary
        await model.locationDidChange(boundary)
        try await Task.sleep(for: .milliseconds(300))
        #expect(savedPlace(app)?.text.highlight == saved.text.highlight, "a later layout report wrote over his words")
        model.close()
    }
}

/// A wait that holds until it is opened.
actor LeaveGate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var watching: [CheckedContinuation<Void, Never>] = []
    var waiters: Int { waiting.count }
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation {
            waiting.append($0)
            watching.forEach { $0.resume() }
            watching = []
        }
    }
    /// Returns once a write is waiting here: the event itself (gatefold#350).
    func arrival() async {
        if !waiting.isEmpty { return }
        await withCheckedContinuation { watching.append($0) }
    }
    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting = []
        watching.forEach { $0.resume() }
        watching = []
    }
}
