import Foundation
import GatefoldCore
import ReadiumShared
import Testing
@testable import Gatefold

/// A page that does what Readium does on a jump: it lands on the page boundary a little before the
/// locator (the page starts a few lines above the words) and reports each location as it goes.
@MainActor
final class ScriptedPage: ReaderPage {
    var currentLocation: Locator?
    weak var model: ReaderModel?
    /// Every jump asked of the page, in order.
    private(set) var jumps: [Locator] = []
    /// How far before a locator's progression its page starts.
    var pageStartsBefore = 0.02
    /// Whether a jump's words end up on screen. Says no for words the test wants to keep settling.
    var showsWords: (Locator) -> Bool = { _ in true }
    private var visibleText = ""

    init(at location: Locator) { currentLocation = location }

    /// Whether a jump reports its page (a test holds the report back to act before Readium's).
    var reportsJumps = true
    /// Called as each jump starts, so a test can see the reader mid-jump.
    var onGo: (() -> Void)?
    /// Jumps that never come back until released (a load that hangs).
    var holdsJumps = false
    /// Reports a jump's page before the jump returns, as Readium can.
    var reportsBeforeReturn = false
    private var held: [CheckedContinuation<Void, Never>] = []
    func releaseJumps() { let h = held; held = []; h.forEach { $0.resume() } }

    /// Jumps a loading web view takes at its file's first page, dropping the place inside it (Readium on
    /// CI's iPad: Back to a page mid-chapter opened the chapter's start, 8c5f294).
    var dropsPlaceInFile = 0

    @discardableResult
    func go(to locator: Locator) async -> Bool {
        jumps.append(locator)
        onGo?()
        if holdsJumps { await withCheckedContinuation { held.append($0) } }
        if dropsPlaceInFile > 0, let inFile = locator.locations.progression, inFile > 0 {
            dropsPlaceInFile -= 1
            currentLocation = locator.copy(
                locations: {
                    $0.progression = 0
                    $0.totalProgression = max(0, ($0.totalProgression ?? 0) - inFile / 50)
                },
                text: { $0 = Locator.Text() }
            )
            visibleText = "the chapter's first page"
            if let model, reportsJumps, reportsOnGo, let here = currentLocation { Task { await model.locationDidChange(here) } }
            return true
        }
        let before = pageStartsBefore
        let landed = locator.copy(
            locations: {
                $0.progression = max(0, ($0.progression ?? 0) - before)
                $0.totalProgression = max(0, ($0.totalProgression ?? 0) - before / 50)
            },
            text: { $0 = Locator.Text() }
        )
        currentLocation = landed
        if let words = locator.text.highlight {
            visibleText = showsWords(locator) ? "the lines above the place. " + words + " and on down the page" : "a page of something else entirely"
        }
        if let model, reportsJumps, reportsOnGo {
            if reportsBeforeReturn { await model.locationDidChange(landed) } else { Task { await model.locationDidChange(landed) } }
        }
        return true
    }

    /// Readium reports where a jump took it on its own (off: a test sends the reports itself, in order).
    var reportsOnGo = true

    func go(to link: ReadiumShared.Link) async {}

    /// The place loading behind the page (`prepareStandby`), and every one swapped in.
    private(set) var standby: Locator?
    private(set) var promoted: [Locator] = []

    func prepareStandby(at locator: Locator) { standby = locator }
    func dropStandby() { standby = nil }

    func promoteStandby(for locator: Locator) async -> Bool {
        guard standby == locator else { return false }
        standby = nil
        promoted.append(locator)
        // Loaded and turned to its words before the tap.
        currentLocation = locator.copy(text: { $0 = Locator.Text() })
        if let words = locator.text.highlight { visibleText = words + " and on down the page" }
        if let model { Task { await model.locationDidChange(currentLocation!) } }
        return true
    }

    /// The page whose words are on screen, when Readium names another (its boundary after a jump).
    var shownLocation: Locator?
    /// The page's geometry can't be read (a web view still loading): `pageRange` is nil.
    var pageUnmeasured = false

    /// As the host measures it: the page on screen, from its own geometry.
    func pageRange() async -> VisibleRange? {
        guard !pageUnmeasured, let here = shownLocation ?? currentLocation else { return nil }
        let start = here.locations.progression ?? 0
        return VisibleRange(href: here.href.string, start: start, end: min(1, start + 0.03), text: visibleText)
    }

    func visibleRange() async -> VisibleRange? {
        guard let here = currentLocation else { return nil }
        let start = here.locations.progression ?? 0
        return VisibleRange(href: here.href.string, start: start, end: min(1, start + 0.03), text: visibleText)
    }

    func progression(of quote: String) async -> Double? {
        currentLocation?.locations.progression.map { $0 + 0.01 }
    }

    /// The chapter each landing settle's words resolved to, as the host's moves look them up.
    private(set) var landingSettles: [String?] = []
    func settleLanding(_ anchor: ReadingAnchor, stillWanted: @escaping @MainActor () -> Bool) async {
        landingSettles.append(model?.locator(for: anchor)?.href.string)
    }

    /// A capture a stalled reflow cuts short: no first words to be had.
    var withholdAnchor = false

    /// How long reading the first words on screen takes (the web view answers in its own time).
    var anchorDelay: Duration = .zero

    /// The web view answers its scripts in the order they were asked, so two captures in flight end in
    /// that order too. Two sleeps side by side can wake in either order on a loaded machine (a report
    /// during a jump's write once failed that way, the boundary's capture ending first).
    private var anchorQueue: Task<Void, Never>?
    /// Reads of the first words on screen so far.
    private(set) var anchorReads = 0
    /// The next read waits until `releaseAnchor()`: two reports' reads can come back out of order.
    var holdNextAnchor = false
    private var heldAnchor: CheckedContinuation<Void, Never>?
    /// A read is parked in `holdNextAnchor`.
    var isHoldingAnchor: Bool { heldAnchor != nil }
    func releaseAnchor() { heldAnchor?.resume(); heldAnchor = nil }

    func currentAnchor() async -> (ReadingAnchor, Locator)? {
        anchorReads += 1
        // As the host does: Readium's place is taken before the wait for the words on screen.
        let taken = currentLocation
        if holdNextAnchor {
            holdNextAnchor = false
            await withCheckedContinuation { heldAnchor = $0 }
        }
        if anchorDelay > .zero {
            let before = anchorQueue, delay = anchorDelay
            let mine = Task { await before?.value; try? await Task.sleep(for: delay) }
            anchorQueue = mine
            await mine.value
        }
        guard !withholdAnchor, let here = taken else { return nil }
        let anchor = ReadingAnchor(href: here.href.string, progression: here.locations.progression ?? 0, text: nil)
        return (anchor, here)
    }
}

/// The reader's side of sync: landing on another device's place, the races around it and what is
/// recorded for the Cloud. Runs the real `ReaderModel`, Frankenstein and its CFI mapper against a
/// scripted page and a scripted Cloud.
@MainActor @Suite(.serialized) struct ReaderSyncTests {
    static let frankenstein = CloudBook(fastHash: "56f8619536655be4a1541a40c5702d32", name: "pg84.epub", title: "Frankenstein", authors: "Mary Shelley")

    @MainActor struct Fixture {
        let model: ReaderModel
        let page: ScriptedPage
        let app: AppModel
        let sync: StubSync
        let publication: Publication
        let mapper: PositionMapper

        /// Whatever is waiting goes to the Cloud now; returns everything sent.
        func sent() async -> [ReadingPosition] {
            await app.library.sendPendingPushes()
            return await sync.pushed.map(\.0)
        }
    }

    /// Readium's publication isn't Sendable; these tests use it from the main actor only.
    static func locate(_ publication: Publication, _ progression: Double) async -> Locator? {
        nonisolated(unsafe) let p = publication
        return await p.locate(progression: progression)
    }

    static func mapper(_ publication: Publication) async -> PositionMapper? {
        nonisolated(unsafe) let p = publication
        return await BookPositions.mapper(for: p)
    }

    static func publication() async throws -> Publication {
        let url = try #require(Bundle.main.url(forResource: "frankenstein", withExtension: "epub"))
        return try await BookOpener.shared.open(url)
    }

    /// A place the InkPad might hold: the middle of reading-order item `index`, as its exact CFI.
    static func inkPadPlace(_ publication: Publication, _ mapper: PositionMapper, index: Int = 10, percent: Double = 31,
                            updated: Date = Date()) async throws -> ReadingPosition {
        let href = publication.readingOrder[index].url().string
        let made = try #require(await mapper.position(for: BookLocation(href: href, progression: 0.5), at: updated))
        let cfi = try #require(made.cfi)
        return ReadingPosition(cfi: cfi, pointer: "pbr:/external##" + cfi, totalProgression: percent / 100, updated: updated, source: .pocketBookNative)
    }

    /// `listed`: the shelf's listing already carries the Cloud place, as every real listing does (each
    /// book comes with its position, and `merge` keeps it). Off, the place arrives only from the reader's
    /// own fetch: a book on a shelf kept from an earlier listing, opened before the next one returns.
    static func make(remote: @MainActor (Publication, PositionMapper) async throws -> ReadingPosition?,
                     book change: (inout LibraryBook) -> Void = { _ in },
                     startAt: Double = 0, listed: Bool = true) async throws -> Fixture {
        let sync = StubSync()
        let app = AppModel(sync: sync, libraryRoot: URL.temporaryDirectory.appending(path: "reader-sync-\(UUID().uuidString)"))
        let publication = try await publication()
        let mapper = try #require(await Self.mapper(publication))
        let place = try await remote(publication, mapper)
        var cloudBook = frankenstein
        if listed { cloudBook.position = place }
        await sync.setLibrary(.success([cloudBook]))
        await app.library.refresh()
        app.library.update(frankenstein.fastHash, change)
        await sync.setRemote(place)
        let book = try #require(app.library.book(frankenstein.fastHash))
        let initial = book.locatorJSON.flatMap { try? Locator(jsonString: $0) }
        let start: Locator
        if let initial {
            start = initial.copy(text: { $0 = Locator.Text() })
        } else {
            let found = try #require(await Self.locate(publication, startAt))
            start = found.copy(locations: { $0.totalProgression = startAt })
        }
        let page = ScriptedPage(at: start)
        let model = ReaderModel(book: book, publication: publication, app: app, page: page)
        page.model = model
        return Fixture(model: model, page: page, app: app, sync: sync, publication: publication, mapper: mapper)
    }

    // MARK: Landing (item 1)

    @Test func landingOnTheInkPadsPlaceNeverSendsAPlaceBehindIt() async throws {
        var target: ReadingPosition?
        let f = try await Self.make(remote: { pub, mapper in
            target = try await Self.inkPadPlace(pub, mapper)
            return target
        })
        await f.model.load()
        let aim = try #require(target?.parsedCFI)

        let sent = await f.sent()
        #expect(!sent.isEmpty, "the first open lands on the InkPad's place and records it")
        for place in sent {
            let cfi = try #require(place.parsedCFI, "a landing sends an exact place")
            #expect(!(cfi < aim), "sent \(cfi) is behind the InkPad's \(aim)")
        }
        #expect(sent.last?.parsedCFI.map { $0.isSameLocation(as: aim) } == true, "the InkPad gets its own place back, not the top of the page")
        // On Readium's scale (not the Cloud's 31%), and not behind the page the reader landed on.
        #expect((sent.last?.totalProgression ?? 0) >= (f.page.currentLocation?.locations.totalProgression ?? 1))
        #expect(f.app.library.book(Self.frankenstein.fastHash)?.locatorJSON != nil, "this device reopens on the landed page")
    }

    @Test func aLandingBehindTheShelfRecordsNothingUntilTheTap() async throws {
        let f = try await Self.make(remote: { pub, mapper in try await Self.inkPadPlace(pub, mapper) })
        f.model.warm()
        for _ in 0..<200 where !f.model.pageReady { try await Task.sleep(for: .milliseconds(25)) }
        #expect(f.model.pageReady, "the warm open reached its first page")
        try await Task.sleep(for: .milliseconds(200))
        // Nothing opened yet: the shelf keeps its order and the Cloud hears nothing.
        #expect(f.app.library.book(Self.frankenstein.fastHash)?.lastOpened == nil)
        f.app.library.flushPushes()
        try await Task.sleep(for: .milliseconds(80))
        #expect(await f.sync.pushed.isEmpty, "a warm open sent the Cloud a place")
        f.model.activate()
        for _ in 0..<200 where f.app.library.book(Self.frankenstein.fastHash)?.lastOpened == nil {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(f.app.library.book(Self.frankenstein.fastHash)?.lastOpened != nil, "the tap records the landed place")
        let sent = await f.sent()
        #expect(!sent.isEmpty)
        f.model.close()
    }

    /// The Cloud holds only a percent (no CFI, as the fake Cloud and many PocketBook books do). The
    /// first open lands on it and must keep the page it shows as his place: build 20's reopen loop found
    /// no place kept at all, so each reopen landed on the percent afresh and Readium's spread could
    /// fall on the page beside the one he left (3 in 19).
    /// A place the Cloud has only as a whole percent can be pages from his real one: a first open
    /// offers it and shows the book's own page, never lands on it (build 20 landed pages away).
    /// A fresh install (the shelf wiped, the Cloud not) whose own place the Cloud has only as a percent:
    /// offered like any percent-only place, never dropped (it was ours, so nothing was offered at all).
    @Test func ourOwnPercentOnlyPlaceOnAFreshInstallIsOffered() async throws {
        let ours = ReadingPosition(cfi: nil, totalProgression: 0.42, updated: Date(), source: .gatefold)
        let f = try await Self.make(remote: { _, _ in ours }, book: { $0.remote = ours })
        await f.model.load()
        #expect(f.page.jumps.isEmpty, "a percent-only place was landed on")
        #expect(f.app.library.book(Self.frankenstein.fastHash)?.locatorJSON == nil, "a place was saved without a move of his")
        #expect(f.model.suggestion != nil, "his own place on the Cloud was dropped, not offered")
        f.model.close()
    }

    /// VoiceOver's adjust on the scrubber is a jump like any other that isn't a turn: one tap undoes it.
    @Test func aVoiceOverAdjustOnTheScrubberCanBeUndone() async throws {
        let f = try await Self.make(remote: { _, _ in nil }, startAt: 0.05)
        await f.model.load()
        let before = try #require(f.page.currentLocation)
        await f.model.locationDidChange(before)
        await f.model.adjustScrubber(forward: true)
        #expect(f.page.jumps.count == 1, "the adjust didn't jump")
        #expect(f.model.showJumpBack, "an adjust on the scrubber left no way back")
        #expect(f.model.backLocator?.locations.totalProgression == before.locations.totalProgression, "Back doesn't go to the page before the adjust")
        f.model.close()
    }

    @Test func aPercentOnlyPlaceAtAFirstOpenIsOfferedNotLanded() async throws {
        let f = try await Self.make(remote: { _, _ in
            ReadingPosition(cfi: nil, totalProgression: 0.42, updated: Date(), source: .pocketBookNative)
        }, book: { $0.remote = ReadingPosition(cfi: nil, totalProgression: 0.42, updated: Date(), source: .pocketBookNative) })
        await f.model.load()
        #expect(f.page.jumps.isEmpty, "a percent-only place was landed on")
        #expect(f.app.library.book(Self.frankenstein.fastHash)?.locatorJSON == nil, "a place was saved without a move of his")
        #expect(f.model.suggestion != nil, "the percent place is offered")
        // The cover gives way once the check has answered (it was held for a landing): counted in reads.
        for _ in 0..<100 where !f.model.pageReady { try await Task.sleep(for: .milliseconds(20)) }
        #expect(f.model.pageReady, "the cover never gave way to the page")
        f.model.close()
    }

    /// Behind the shelf too: nothing moves and nothing is kept, and the offer waits for the tap.
    @Test func aPercentOnlyPlaceBehindTheShelfIsOfferedAtTheTap() async throws {
        let f = try await Self.make(remote: { _, _ in
            ReadingPosition(cfi: nil, totalProgression: 0.42, updated: Date(), source: .pocketBookNative)
        }, book: { $0.remote = ReadingPosition(cfi: nil, totalProgression: 0.42, updated: Date(), source: .pocketBookNative) })
        f.model.warm()
        for _ in 0..<200 where !f.model.pageReady { try await Task.sleep(for: .milliseconds(25)) }
        #expect(f.page.jumps.isEmpty, "a warm open landed on a percent")
        f.model.activate()
        for _ in 0..<200 where f.model.suggestion == nil { try await Task.sleep(for: .milliseconds(25)) }
        #expect(f.page.jumps.isEmpty)
        #expect(f.model.suggestion != nil)
        #expect(f.app.library.book(Self.frankenstein.fastHash)?.locatorJSON == nil, "a place was saved without a move of his")
        f.model.close()
    }

    /// An offer made behind the shelf has not been seen, so it is not "unanswered" yet: it stays open
    /// until he has tapped the book and its page is up, and only then starts the wait before it folds
    /// (gatefold#156: made at a warm open's start, it folded about 10 s later, before the page under
    /// the cover had shown; CI's Catch up then found only the tab). Counted in reads of the slip.
    @Test func anOfferMadeBehindTheShelfFoldsOnlyAfterHeHasSeenIt() async throws {
        let f = try await Self.make(remote: { _, _ in
            ReadingPosition(cfi: nil, totalProgression: 0.42, updated: Date(), source: .pocketBookNative)
        }, book: { $0.remote = ReadingPosition(cfi: nil, totalProgression: 0.42, updated: Date(), source: .pocketBookNative) })
        f.model.warm()
        for _ in 0..<200 where f.model.slip == nil || !f.model.pageReady { try await Task.sleep(for: .milliseconds(25)) }
        try #require(f.model.slip != nil && f.model.slipKind == .ahead && f.model.pageReady, "the Cloud's place was not offered behind the shelf, or the warm page never came up")
        // Past the fold's whole wait, behind the shelf: nobody has seen the offer, so it must still be open.
        let foldReads = Int((LaunchOptions.offerFoldSeconds + 2) / 0.025)
        for _ in 0..<foldReads where !f.model.slipFolded { try await Task.sleep(for: .milliseconds(25)) }
        #expect(!f.model.slipFolded, "the offer folded behind the shelf, before he had seen it")
        f.model.activate()
        #expect(f.model.slip != nil && !f.model.slipFolded, "the tap did not find the offer open")
        // Seen and unanswered, it still folds into its tab.
        for _ in 0..<foldReads where !f.model.slipFolded { try await Task.sleep(for: .milliseconds(25)) }
        #expect(f.model.slipFolded && f.model.slip != nil, "the offer never folded once he had seen it")
        f.model.close()
    }

    /// His own place in the front matter is still his place: the InkPad's further one is offered.
    @Test func aPlaceInTheFrontMatterIsKeptAndTheInkPadsOffered() async throws {
        let f = try await Self.make(remote: { pub, mapper in try await Self.inkPadPlace(pub, mapper, index: 12, percent: 40) },
                                    book: { $0.totalProgression = 0.003; $0.lastOpened = Date().addingTimeInterval(-3600)
                                            $0.remote = ReadingPosition(cfi: nil, totalProgression: 0.40, updated: Date(), source: .pocketBookNative) },
                                    startAt: 0.003)
        await f.model.load()
        #expect(f.page.jumps.isEmpty, "the front-matter place was landed over")
        #expect(f.model.suggestion != nil, "the InkPad's place is offered")
        f.model.close()
    }

    /// A jump made behind the shelf (a test's launch jump reaches every book that opens) is his once he
    /// taps: the page he sees is kept then, and a fresh open shows it again (build 20's Duo run reopened
    /// the jump afresh, on another page).
    @Test func aJumpBehindTheShelfIsKeptAtTheTap() async throws {
        let f = try await Self.make(remote: { _, _ in nil })
        f.model.warm()
        for _ in 0..<200 where !f.model.pageReady { try await Task.sleep(for: .milliseconds(25)) }
        await f.model.go(toProgression: 0.5, rememberBack: false)
        if let jumped = f.page.currentLocation { await f.model.locationDidChange(jumped) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(f.app.library.book(Self.frankenstein.fastHash)?.locatorJSON == nil, "a warm book kept a place before the tap")
        f.model.activate()
        for _ in 0..<200 where f.app.library.book(Self.frankenstein.fastHash)?.locatorJSON == nil {
            try await Task.sleep(for: .milliseconds(25))
        }
        let saved = try #require(f.app.library.book(Self.frankenstein.fastHash)?.locatorJSON.flatMap { try? Locator(jsonString: $0) },
                                 "the tap kept no place for a jump made behind the shelf")
        let shown = try #require(f.page.currentLocation)
        #expect(saved.href.string == shown.href.string, "saved \(ReaderModel.placeTag(saved)) shown \(ReaderModel.placeTag(shown))")
        #expect(abs((saved.locations.progression ?? -1) - (shown.locations.progression ?? -2)) < 0.0001, "the kept place isn't the page shown")
        await f.model.locationDidChange(Self.boundary(of: shown))
        try await Task.sleep(for: .milliseconds(100))
        #expect(f.app.library.book(Self.frankenstein.fastHash)?.locatorJSON.flatMap { try? Locator(jsonString: $0) }?.locations.progression == saved.locations.progression,
                "a layout report moved the saved place")
        f.model.close()
    }

    /// One jump, one place: once his jump is kept, a later report with no turn, jump or touch since
    /// (Readium naming the chapter's first page as the web view finishes loading) is the layout's.
    /// Build 20's real-unfold run wrote it as a second move and lost his words on the next unfold.
    @Test func aSecondReportAfterAKeptJumpLeavesThePlace() async throws {
        let f = try await Self.make(remote: { _, _ in nil })
        await f.model.load()
        // The test sends the jump's reports itself, so no third one races them.
        f.page.reportsOnGo = false
        await f.model.go(toProgression: 0.5, rememberBack: false)
        let jumped = try #require(f.page.currentLocation)
        await f.model.locationDidChange(jumped)
        try await Task.sleep(for: .milliseconds(100))
        let kept = try #require(f.app.library.book(Self.frankenstein.fastHash)?.locatorJSON.flatMap { try? Locator(jsonString: $0) },
                                "the jump kept no place")
        await f.model.locationDidChange(Self.boundary(of: jumped))
        try await Task.sleep(for: .milliseconds(100))
        #expect(f.app.library.book(Self.frankenstein.fastHash)?.locatorJSON.flatMap { try? Locator(jsonString: $0) }?.locations.progression == kept.locations.progression,
                "a second report after the jump moved the saved place")
        f.model.close()
    }

    /// The same, with the second report arriving while the first is still being written (the loop's
    /// double writes came 0.3 s apart, inside the first write's wait for its exact position).
    @Test func aReportDuringAJumpsWriteLeavesThePlace() async throws {
        try await reportDuringAJumpsWrite(pageUnmeasured: false)
    }

    /// The same with a page that can't be measured yet: the first report keeps the move.
    @Test func aReportDuringAJumpsWriteOnAnUnmeasuredPageLeavesThePlace() async throws {
        try await reportDuringAJumpsWrite(pageUnmeasured: true)
    }

    private func reportDuringAJumpsWrite(pageUnmeasured: Bool) async throws {
        let f = try await Self.make(remote: { _, _ in nil })
        await f.model.load()
        // The test sends the jump's reports itself, so no third one races them.
        f.page.reportsOnGo = false
        await f.model.go(toProgression: 0.5, rememberBack: false)
        let jumped = try #require(f.page.currentLocation)
        // Both reports wait on the web view for his words, as they do on a device, and the boundary's read
        // comes back first (a busy runner reordered them: #82 kept the boundary, progression 0). Ordered by
        // the page's reads, not by time: the jump's report holds in its read until the boundary's is done.
        // Readium has already named the boundary when the jump's report reads (the host takes Readium's
        // place first), while his words, the jump's page, stay on screen.
        let boundary = Self.boundary(of: jumped)
        f.page.shownLocation = jumped
        f.page.pageUnmeasured = pageUnmeasured
        f.page.currentLocation = boundary
        f.page.holdNextAnchor = true
        let reads = f.page.anchorReads
        let first = Task { await f.model.locationDidChange(jumped) }
        for _ in 0..<10_000 where !f.page.isHoldingAnchor { await Task.yield() }
        try #require(f.page.isHoldingAnchor && f.page.anchorReads == reads + 1, "the jump's report isn't the read held")
        await f.model.locationDidChange(boundary)
        f.page.releaseAnchor()
        // A write is synchronous: once both reports have returned, the place is what was kept.
        await first.value
        let saved = try #require(f.app.library.book(Self.frankenstein.fastHash)?.locatorJSON.flatMap { try? Locator(jsonString: $0) })
        #expect(saved.locations.progression == jumped.locations.progression, "a report during the jump's write moved the saved place")
        f.model.close()
    }

    /// The other order: a two-step jump reports its file's start first, then (while that report is
    /// still reading the page) the place itself. The place is what he sees, so it is kept, not the start.
    @Test func aJumpsStartReportThenItsPlaceKeepsThePlace() async throws {
        let f = try await Self.make(remote: { _, _ in nil })
        await f.model.load()
        f.page.reportsOnGo = false
        await f.model.go(toProgression: 0.5, rememberBack: false)
        let place = try #require(f.page.currentLocation)
        let start = Self.boundary(of: place)
        f.page.currentLocation = start
        f.page.holdNextAnchor = true
        let reads = f.page.anchorReads
        let first = Task { await f.model.locationDidChange(start) }
        for _ in 0..<10_000 where !f.page.isHoldingAnchor { await Task.yield() }
        try #require(f.page.isHoldingAnchor && f.page.anchorReads == reads + 1, "the start's report isn't the read held")
        // The page reaches the place and says so while the start's read is out.
        f.page.currentLocation = place
        await f.model.locationDidChange(place)
        f.page.releaseAnchor()
        await first.value
        let saved = try #require(f.app.library.book(Self.frankenstein.fastHash)?.locatorJSON.flatMap { try? Locator(jsonString: $0) })
        #expect(saved.locations.progression == place.locations.progression, "the jump's file start was kept, not the place it reached")
        f.model.close()
    }

    /// A landing whose first words couldn't be captured (a reflow that wouldn't settle) keeps Readium's
    /// boundary only until the layout is still: then the page he sees is the place (build 20's loop
    /// kept the chapter's start under a stalled reflow and reopened a page before him).
    @Test func aLandingOnTheBoundaryTakesHisWordsOnceStill() async throws {
        let f = try await Self.make(remote: { pub, mapper in try await Self.inkPadPlace(pub, mapper) })
        f.page.withholdAnchor = true
        await f.model.load()
        let boundary = try #require(f.app.library.book(Self.frankenstein.fastHash)?.locatorJSON.flatMap { try? Locator(jsonString: $0) },
                                    "the landing kept nothing")
        // The layout settles on his page, a little on from the boundary, and reports it: not his move.
        let landed = try #require(f.page.currentLocation)
        let settled = landed.copy(locations: { $0.progression = ($0.progression ?? 0) + 0.05; $0.totalProgression = ($0.totalProgression ?? 0) + 0.001 })
        f.page.currentLocation = settled
        await f.model.locationDidChange(settled)
        f.page.withholdAnchor = false
        for _ in 0..<200 where f.app.library.book(Self.frankenstein.fastHash)?.locatorJSON.flatMap({ try? Locator(jsonString: $0) })?.locations.progression == boundary.locations.progression {
            try await Task.sleep(for: .milliseconds(25))
        }
        let saved = try #require(f.app.library.book(Self.frankenstein.fastHash)?.locatorJSON.flatMap { try? Locator(jsonString: $0) })
        #expect(saved.locations.progression == settled.locations.progression, "the boundary was kept, not the page he sees")
        f.model.close()
    }

    /// Shape (b) at the model: after the landing is kept, a report from the layout with no turn, jump
    /// or touch of his never moves the saved place.
    @Test func aLayoutReportAfterALandingLeavesThePlace() async throws {
        let f = try await Self.make(remote: { pub, mapper in try await Self.inkPadPlace(pub, mapper) })
        await f.model.load()
        let before = f.app.library.book(Self.frankenstein.fastHash)?.locatorJSON
        #expect(before != nil)
        let landed = try #require(f.page.currentLocation)
        await f.model.locationDidChange(Self.boundary(of: landed))
        try await Task.sleep(for: .milliseconds(100))
        #expect(f.app.library.book(Self.frankenstein.fastHash)?.locatorJSON == before, "a layout report moved the saved place")
        f.model.close()
    }

    /// The first page of the chapter a place is in: where Readium's spread can report from.
    static func boundary(of l: Locator) -> Locator {
        l.copy(locations: {
            $0.totalProgression = max(0, ($0.totalProgression ?? 0) - 0.008)
            $0.progression = 0
        }, text: { $0 = Locator.Text() })
    }

    @Test func choosingTheLandedPlace() throws {
        let now = Date()
        let at = { (cfi: String?, total: Double) in ReadingPosition(cfi: cfi, totalProgression: total, updated: .distantPast, source: .pocketBookNative) }
        let target = at("epubcfi(/6/22[item12]!/4/2/10/1:40)", 0.31)
        // The page starts above the target: the target.
        let above = LandingPlace.choose(settled: at("epubcfi(/6/22[item12]!/4/2/8/1:0)", 0.305), target: target, at: now)
        #expect(above?.cfi == target.cfi)
        #expect(above?.updated == now)
        #expect(above?.source == .gatefold)
        #expect(above?.totalProgression == 0.31)
        // The page is past it (Readium overshot): where the reader is.
        let past = LandingPlace.choose(settled: at("epubcfi(/6/22[item12]!/4/2/12/1:0)", 0.312), target: target, at: now)
        #expect(past?.cfi == "epubcfi(/6/22[item12]!/4/2/12/1:0)")
        // Percent-only on either side compares whole-book progress.
        #expect(LandingPlace.choose(settled: at(nil, 0.30), target: target, at: now)?.cfi == target.cfi)
        #expect(LandingPlace.choose(settled: at(nil, 0.33), target: target, at: now)?.cfi == nil)
        #expect(LandingPlace.choose(settled: nil, target: target, at: now)?.cfi == target.cfi)
        #expect(LandingPlace.choose(settled: above, target: nil, at: now) == above)
    }

    // MARK: checkRemote (item 4)

    @Test func ourOwnPercentReadBackIsNotOfferedAsFurtherAhead() async throws {
        // A book without a CFI mapping sends a percent; the Cloud gives back ceil(30.1) = 31%.
        let opened = Date().addingTimeInterval(-600)
        let f = try await Self.make(remote: { _, _ in
            ReadingPosition(cfi: nil, totalProgression: 0.31, updated: Date(), source: .unknown)
        }, book: { $0.totalProgression = 0.301; $0.lastOpened = opened }, startAt: 0.301)
        await f.model.load()
        #expect(f.model.suggestion == nil)
        #expect(f.page.jumps.isEmpty)
    }

    @Test func aPercentOnlyPlaceThatIsAheadIsOffered() async throws {
        let opened = Date().addingTimeInterval(-600)
        let f = try await Self.make(remote: { _, _ in
            ReadingPosition(cfi: nil, totalProgression: 0.33, updated: Date(), source: .unknown)
        }, book: { $0.totalProgression = 0.301; $0.lastOpened = opened }, startAt: 0.301)
        await f.model.load()
        #expect(f.model.suggestion?.detail.contains("Jump there?") == true)
    }

    /// Landing on another device's place is a jump he can undo: the Back pill comes up (#49, #46).
    @Test func aCatchUpLandingPutsUpTheWayBack() async throws {
        let f = try await Self.make(remote: { pub, mapper in
            try await Self.inkPadPlace(pub, mapper, index: 12, percent: 40)
        }, book: { $0.totalProgression = 0.05; $0.lastOpened = Date().addingTimeInterval(-600) }, startAt: 0.05)
        await f.model.load()
        #expect(f.model.suggestion != nil)
        await f.model.acceptSuggestion()
        #expect(f.model.showJumpBack && f.model.backLocator != nil, "landing on another device's place left no way back")
        f.model.close()
    }

    /// Catch up taken while the first page is still loading behind the opening cover (the offer sits
    /// above the cover since #46 at c8d3084): Readium refuses a jump then, and the landing's few reads
    /// can't outwait a chapter's load, so the landing waits for the page to show, then goes.
    @Test func catchUpTakenWhileTheFirstPageLoadsLandsOnceItShows() async throws {
        let f = try await Self.make(remote: { pub, mapper in
            try await Self.inkPadPlace(pub, mapper, index: 12, percent: 40)
        }, book: { $0.totalProgression = 0.05; $0.lastOpened = Date().addingTimeInterval(-600) }, startAt: 0.05)
        // No load: the first page has not shown, and the Cloud's reply is offered over the cover.
        await f.model.checkRemote()
        try #require(f.model.suggestion != nil, "the Cloud's place is offered")
        try #require(!f.model.pageReady, "the first page is still loading")
        let taking = Task { await f.model.acceptSuggestion() }
        for _ in 0..<20 { await Task.yield(); try await Task.sleep(for: .milliseconds(10)) }
        #expect(f.page.jumps.isEmpty && f.page.promoted.isEmpty, "the landing went while the first page was still loading")
        #expect(f.model.suggestion == nil, "the offer stayed up after his tap")
        f.model.forceReady()
        await taking.value
        #expect(f.model.pageReady)
        #expect(!f.page.jumps.isEmpty || !f.page.promoted.isEmpty, "the landing never went once the page showed")
        f.model.close()
    }

    /// A landing settle moves the page to its words through the place they resolve to. Resolved to the
    /// page he left (the last place captured), its moves went nowhere: on CI's iPad the Cloud's words
    /// stayed pinned off the spread and every reopen showed another one (#46's reviewer leg, 5 of 5).
    @Test func aLandingSettlesOnTheLandingsChapterNotThePageHeLeft() async throws {
        let f = try await Self.make(remote: { pub, mapper in
            try await Self.inkPadPlace(pub, mapper, index: 12, percent: 40)
        }, book: { $0.totalProgression = 0.05; $0.lastOpened = Date().addingTimeInterval(-600) }, startAt: 0.05)
        await f.model.load()
        let left = try #require(f.page.currentLocation?.href.string)
        await f.model.acceptSuggestion()
        let landed = try #require(f.page.currentLocation?.href.string)
        #expect(landed != left, "the Cloud's place is in another chapter")
        try #require(f.page.landingSettles.count == 1, "the Cloud's place had words for the landing to settle")
        #expect(f.page.landingSettles == [landed], "the landing settle's words resolved to \(f.page.landingSettles), not \(landed)")
        f.model.close()
    }

    @Test func theCatchUpPageLoadsWhileTheSlipIsUpSoTheTapOnlySwapsItIn() async throws {
        let opened = Date().addingTimeInterval(-600)
        var target: ReadingPosition?
        let f = try await Self.make(remote: { pub, mapper in
            target = try await Self.inkPadPlace(pub, mapper, index: 12, percent: 40)
            return target
        }, book: { $0.totalProgression = 0.05; $0.lastOpened = opened }, startAt: 0.05)
        await f.model.load()
        #expect(f.model.suggestion != nil)
        let waiting = try #require(f.page.standby, "the Cloud place's page starts loading as the slip appears")
        await f.model.acceptSuggestion()
        #expect(f.page.promoted == [waiting])
        #expect(f.page.jumps.isEmpty, "no fresh jump: the page was already there")
        let aim = try #require(target?.parsedCFI)
        #expect(await f.sent().last?.parsedCFI.map { $0.isSameLocation(as: aim) } == true)
    }

    @Test func carryingOnHereLetsTheWaitingPageGo() async throws {
        let opened = Date().addingTimeInterval(-600)
        let f = try await Self.make(remote: { pub, mapper in
            try await Self.inkPadPlace(pub, mapper, index: 12, percent: 40)
        }, book: { $0.totalProgression = 0.05; $0.lastOpened = opened }, startAt: 0.05)
        await f.model.load()
        #expect(f.page.standby != nil)
        f.model.dismissSuggestion()
        #expect(f.page.standby == nil)
    }

    @Test func aReflowWhileTheSlipIsUpLoadsTheWaitingPageAgain() async throws {
        let opened = Date().addingTimeInterval(-600)
        let f = try await Self.make(remote: { pub, mapper in
            try await Self.inkPadPlace(pub, mapper, index: 12, percent: 40)
        }, book: { $0.totalProgression = 0.05; $0.lastOpened = opened }, startAt: 0.05)
        await f.model.load()
        let waiting = try #require(f.page.standby)
        // The host throws the page away when the type or the size changes…
        f.page.dropStandby()
        f.model.reflowDidFinish(visible: nil)
        // …and the catch-up still on offer gets a new one once the page has settled.
        #expect(f.page.standby == waiting)
        await f.model.acceptSuggestion()
        #expect(f.page.promoted == [waiting])
    }

    @Test func theSwapIsTheLandingAndTheOpeningSettleNeverPullsBack() async throws {
        let pub = try await Self.publication()
        let early = try #require(await Self.locate(pub, 0.05))
        let saved = early.copy(text: { $0 = Locator.Text(highlight: "words of the saved page that never show") })
        let json = try #require(try saved.jsonString())
        let f = try await Self.make(remote: { pub, mapper in
            try await Self.inkPadPlace(pub, mapper, index: 12, percent: 40)
        }, book: { $0.locatorJSON = json; $0.totalProgression = 0.05; $0.lastOpened = Date().addingTimeInterval(-3600) })
        let savedHref = saved.href.string
        f.page.showsWords = { $0.href.string != savedHref }
        let loading = Task { await f.model.load() }
        for _ in 0..<100 where f.page.jumps.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        await f.model.checkRemote()
        #expect(f.page.standby != nil)
        await f.model.acceptSuggestion()
        let afterSwap = f.page.jumps.count
        await loading.value
        try await Task.sleep(for: .seconds(1))
        #expect(f.page.promoted.count == 1)
        #expect(f.page.jumps.count == afterSwap, "nothing moved the page after the swap")
        #expect(f.page.currentLocation?.href.string != savedHref)
    }

    @Test func ourOwnPlaceComingBackIsNotNews() async throws {
        // Opened here before: our own place in the Cloud is where we already are.
        let opened = Date().addingTimeInterval(-600)
        let f = try await Self.make(remote: { pub, mapper in
            var p = try await Self.inkPadPlace(pub, mapper)
            p.source = .gatefold
            p.updated = opened.addingTimeInterval(60)
            return p
        }, book: { $0.totalProgression = 0.05; $0.lastOpened = opened }, startAt: 0.05)
        await f.model.load()
        #expect(f.model.suggestion == nil)
        #expect(f.page.jumps.isEmpty)
        #expect(await f.sent().isEmpty)
    }

    @Test func afterAReinstallOurOwnPlaceOpensAndIsNeverCreditedToTheInkPad() async throws {
        // A fresh shelf (a reinstall), and the Cloud holds a place this app wrote.
        let f = try await Self.make(remote: { pub, mapper in
            var p = try await Self.inkPadPlace(pub, mapper)
            p.source = .gatefold
            return p
        })
        await f.model.load()
        #expect(f.model.suggestion == nil)
        #expect(!(await f.sent()).isEmpty, "the book opens on the place it was left at")
        let title = f.model.slip?.title
        #expect(title?.hasPrefix("Right where you left off") == true, "got \(title ?? "no slip")")
        #expect(title?.contains("InkPad") == false)
    }

    @Test func aRemotePlaceArrivingWhileTheOpeningSettleRunsWinsAndIsNotPulledBack() async throws {
        // Opened here before, on a page whose words never come on screen, so the opening settle keeps
        // retrying. Meanwhile the app comes back to the foreground and the InkPad is further ahead.
        let pub = try await Self.publication()
        let early = try #require(await Self.locate(pub, 0.05))
        let saved = early.copy(text: { $0 = Locator.Text(highlight: "words of the saved page that never show") })
        let json = try #require(try saved.jsonString())
        var target: ReadingPosition?
        let f = try await Self.make(remote: { pub, mapper in
            target = try await Self.inkPadPlace(pub, mapper, index: 12, percent: 40)
            return target
        }, book: { $0.locatorJSON = json; $0.totalProgression = 0.05; $0.lastOpened = Date().addingTimeInterval(-3600) })
        let savedHref = saved.href.string
        f.page.showsWords = { $0.href.string != savedHref }

        let loading = Task { await f.model.load() }
        // Wait for the opening settle to start retrying its jump.
        for _ in 0..<100 where f.page.jumps.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!f.page.jumps.isEmpty, "the opening settle is retrying")
        await f.model.checkRemote()
        #expect(f.model.suggestion != nil)
        await f.model.acceptSuggestion()
        let landedAfter = f.page.jumps.count
        await loading.value

        let later = f.page.jumps[landedAfter...]
        #expect(later.allSatisfy { $0.href.string != savedHref }, "the opening settle pulled the reader back after the jump")
        #expect(f.page.currentLocation?.href.string != savedHref)
        let aim = try #require(target?.parsedCFI)
        #expect(await f.sent().last?.parsedCFI.map { $0.isSameLocation(as: aim) } == true)
        #expect(f.model.backLocator != nil, "Back returns to the saved page")
    }

    @Test func closingDuringALandingStopsItAndRecordsNothingAfter() async throws {
        let f = try await Self.make(remote: { pub, mapper in try await Self.inkPadPlace(pub, mapper) })
        // The words never show, so the landing keeps settling for about a second.
        f.page.showsWords = { _ in false }
        let loading = Task { await f.model.load() }
        for _ in 0..<200 where f.page.jumps.count < 2 { try await Task.sleep(for: .milliseconds(25)) }
        #expect(f.page.jumps.count >= 2, "the landing is settling")
        f.model.close()
        await f.app.sendPlaceNow()
        let jumpsAtClose = f.page.jumps.count
        await loading.value
        try await Task.sleep(for: .milliseconds(600))

        #expect(f.page.jumps.count <= jumpsAtClose, "the page moved after the book closed")
        #expect(f.app.library.pendingPush(for: Self.frankenstein.fastHash) == nil, "a place was recorded after the close")
        #expect(await f.sent().isEmpty)
        // And a remote check after the close does nothing.
        await f.model.checkRemote()
        #expect(f.model.suggestion == nil)
    }

    @Test func aTurnDuringALandingOwnsThePlace() async throws {
        var target: ReadingPosition?
        let f = try await Self.make(remote: { pub, mapper in
            target = try await Self.inkPadPlace(pub, mapper)
            return target
        })
        f.page.showsWords = { _ in false }
        let loading = Task { await f.model.load() }
        for _ in 0..<200 where f.page.jumps.count < 2 { try await Task.sleep(for: .milliseconds(25)) }
        let jumpsAtTurn = f.page.jumps.count
        // The reader turns a page while the landing is still settling.
        let turned = try #require(f.page.currentLocation).copy(locations: { $0.progression = ($0.progression ?? 0) + 0.04 })
        f.page.currentLocation = turned
        f.model.userTurnedPage()
        await loading.value
        try await Task.sleep(for: .milliseconds(900))

        #expect(f.page.jumps.count == jumpsAtTurn, "the landing kept moving the page after the turn")
        let sent = await f.sent()
        let aim = try #require(target?.parsedCFI)
        #expect(sent.last.map { p in p.parsedCFI.map { !$0.isSameLocation(as: aim) } ?? true } == true, "the landing overwrote the turn")
    }

    @Test func overlappingRemoteChecksRunOneAfterAnother() async throws {
        let f = try await Self.make(remote: { pub, mapper in try await Self.inkPadPlace(pub, mapper) })
        f.page.showsWords = { _ in false }
        let loading = Task { await f.model.load() }
        let second = Task {
            try? await Task.sleep(for: .milliseconds(400))
            await f.model.checkRemote()
        }
        await loading.value
        await second.value
        let reads = await f.sync.remoteReads
        #expect(reads >= 1)
        // One landing: a second check found the reader already there instead of landing again.
        let landings = f.page.jumps.filter { $0.text.highlight != nil }.count
        #expect(landings == 1)
    }

    @Test func theRunningHeadStaysWithThePageOnScreenUntilTheNewOneIsRevealed() async throws {
        let f = try await Self.make(remote: { _, _ in nil }, startAt: 0.05)
        await f.model.load()
        let before = f.model.chapterTitle
        // A jump under way: the old page still shows, so the head keeps its chapter.
        f.model.heldRunningHead = .some(before)
        let far = try #require(await Self.locate(f.publication, 0.8))
        _ = await f.page.go(to: far)
        await f.model.locationDidChange(f.page.currentLocation!)
        #expect(f.model.chapterTitle != before, "the jump went to another chapter")
        #expect(f.model.runningHead == before, "mid-riffle, the head still names the old page's chapter")
        // The new page is revealed.
        f.model.heldRunningHead = nil
        #expect(f.model.runningHead == f.model.chapterTitle)
    }
}

// MARK: Pushes and percents (items 2 and 3)

@MainActor @Suite struct PushBookkeepingTests {
    @Test func thePushTableEmptiesOnceEveryPlaceIsSent() async throws {
        let sync = FakeSyncService(signedIn: true, latency: .zero)
        let store = LibraryStore(sync: sync, root: URL.temporaryDirectory.appending(path: "push-table-\(UUID().uuidString)"))
        await store.refresh()
        for (i, book) in store.books.enumerated() {
            for turn in 0..<5 { store.recordPlace(bookID: book.id, locatorJSON: "{}", totalProgression: 0.1 + Double(i * 5 + turn) / 100, progression: 0.5) }
        }
        #expect(store.pushesInFlight == store.books.count)
        await store.sendPendingPushes()
        #expect(store.pushesInFlight == 0)
        #expect(store.pendingPush(for: store.books[0].id) == nil)
    }

    @Test func aDebouncedPushLeavesTheTableWhenItLands() async throws {
        let sync = FakeSyncService(signedIn: true, latency: .zero)
        let store = LibraryStore(sync: sync, root: URL.temporaryDirectory.appending(path: "push-table-\(UUID().uuidString)"))
        await store.refresh()
        let emma = try #require(store.books.first { $0.title == "Emma" })
        store.recordPlace(bookID: emma.id, locatorJSON: "{}", totalProgression: 0.2, progression: 0.2)
        store.recordPlace(bookID: emma.id, locatorJSON: "{}", totalProgression: 0.21, progression: 0.2)
        #expect(store.pushesInFlight == 1)
        try await Task.sleep(for: .milliseconds(900))
        #expect(store.pushesInFlight == 0)
        #expect(try await sync.remotePosition(for: try #require(emma.cloud))?.totalProgression == 0.21)
    }

    @Test func theShelfShowsTheCloudsWholePercent() throws {
        var book = LibraryBook(id: "b", title: "B", author: "", origin: .imported, added: Date())
        for whole in [1, 7, 29, 57, 99] {
            book.totalProgression = Double(whole) / 100
            book.lastOpened = Date()
            let position = ReadingPosition(cfi: nil, totalProgression: book.totalProgression, updated: Date())
            #expect(book.displayPercent == whole)
            #expect(book.displayPercent == position.wholePercent)
        }
        book.totalProgression = 0.0861
        #expect(book.displayPercent == 9, "PocketBook's ceiling, like the InkPad and web reader")
    }
}
