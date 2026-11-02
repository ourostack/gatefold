import GatefoldCloudReadium
import GatefoldCore
import Observation
import ReadiumNavigator
import ReadiumShared
import SwiftUI

/// A table-of-contents row.
struct TOCEntry: Identifiable, Hashable {
    let id: Int
    let title: String
    let level: Int
    let link: ReadiumShared.Link
    let progression: Double
}

/// Everything the reader screen shows, and the reader's actions.
@MainActor @Observable
final class ReaderModel {
    let bookID: String
    /// The title a reader would say ("Frankenstein"); `fullTitle` keeps the subtitle for VoiceOver.
    let title: String
    let fullTitle: String
    nonisolated(unsafe) let publication: Publication
    private let app: AppModel

    private(set) var location: Locator?
    private(set) var chapterMap = ChapterMap(chapters: [], positionCount: 1)
    private(set) var toc: [TOCEntry] = []
    private(set) var chromeVisible = false
    private(set) var layout = ReaderLayoutResolver.resolve(.init(containerSize: CGSize(width: 400, height: 800)))
    private(set) var isBookmarked = false
    private(set) var bookmarks = BookmarkList()
    var suggestion: JumpSuggestion?
    /// Exactly where the suggestion goes (the other device's CFI, found in this book), when known.
    private var suggestionLocator: Locator?
    /// Turns places into PocketBook CFIs and back, from this book's own spine and XHTML.
    private var mapper: PositionMapper?
    private(set) var contents = ContentsIndex(entries: [], readingOrder: [])
    /// Where back matter (a Project Gutenberg licence) begins; turning past it closes the book.
    private(set) var storyEnd: ContentsIndex.Entry?
    private var readingOrderHrefs: [String] = []
    private var resourceStarts: [Double] = []
    /// The contents anchor above the first line on screen (from the web view).
    var contentsFragment: String?
    /// Where the reader was before a jump, so Back can return there.
    private(set) var backLocator: Locator?
    private(set) var backPage: Int?
    var errorMessage: String?
    /// The paper slip under the top bar: the sync landed, or the other device is further on.
    enum SlipKind: Equatable { case landed, ahead }
    private(set) var slip: SyncSlip?
    private(set) var slipKind: SlipKind?
    /// Bumped each time a slip appears, for its haptic.
    private(set) var slipCount = 0
    /// After a Jump, the way back stays on screen for a few seconds even with the controls hidden.
    private(set) var showJumpBack = false
    @ObservationIgnored private var jumpBackTask: Task<Void, Never>?
    @ObservationIgnored private var slipTask: Task<Void, Never>?
    /// The end leaf, once the reader turns past the story's last page.
    private(set) var endLeaf: EndLeaf?
    /// The book's cover, shown while the first page lays out and on the end leaf.
    let cover: UIImage?
    /// The first page is on screen and legible.
    private(set) var pageReady = false
    let openedAt = Date()
    /// Set once the reader has settled after a reflow (for UI tests): whether the anchor is on screen.
    private(set) var anchorCheck = "pending 0"
    private var anchorReady = false
    /// For UI tests: what the last check compared.
    private(set) var anchorDetail = ""

    var keeper = AnchorKeeper()
    private var anchorLocator: Locator?
    private var pendingReflowReason: ReflowReason?
    weak var host: ReaderHostController?
    private(set) var hostController: ReaderHostController?
    /// A scripted page for unit tests; the app always reads the host's.
    @ObservationIgnored private var injectedPage: (any ReaderPage)?
    private var page: (any ReaderPage)? { injectedPage ?? host }
    /// This device's place when the book was opened, for the "further ahead" comparison.
    private let openedSnapshot: ProgressSnapshot?
    /// First open here of a book the InkPad has a place in: the cover stays up until the reader has
    /// landed there, so the book's first page never flashes past (or loads blank) on the way.
    private var awaitingLanding: Bool
    /// Where the book opened; nothing is recorded or pushed until the reader moves from it,
    /// so opening a book never overwrites a further-ahead place on the other device.
    private var hasMoved = false
    /// The saved place, with the first words that were on screen.
    private let initialLocator: Locator?
    /// Counts every move of the page (a turn, a jump, a landing, the close). A settle or a landing
    /// that started before the latest move has been overtaken and must not move or record anything.
    private var moves = 0
    /// Set from the moment the reader closes; nothing moves the page or records a place after it.
    private(set) var isClosed = false
    /// While a landing settles, the navigator's in-between locations are not places: the landing
    /// records once, when it has settled. Any later move ends it.
    private var landingMove: Int?
    private var landing: Bool { landingMove == moves }
    /// The Cloud place behind the banner, so accepting it records that exact place.
    private var suggestionRemote: ReadingPosition?
    /// A remote check is running; another request runs once it ends instead of alongside it.
    private var checkingRemote = false
    private var recheckRemote = false

    init(book: LibraryBook, publication: Publication, app: AppModel, page: (any ReaderPage)? = nil) {
        self.bookID = book.id
        self.fullTitle = publication.metadata.title ?? book.title
        self.title = BookTitle.display(fullTitle)
        self.publication = publication
        self.app = app
        self.bookmarks = book.bookmarks
        self.openedSnapshot = book.localSnapshot
        self.awaitingLanding = book.localSnapshot == nil
            && ((book.remote?.totalProgression ?? 0) > JumpSuggestion.threshold || (book.cloud?.readPercent ?? 0) > 0)
        self.cover = app.library.cover(for: book)
        let initial = book.locatorJSON.flatMap { try? Locator(jsonString: $0) }
        self.initialLocator = initial
        let prefs = app.preferences.effective(for: book.id)
        if let page {
            injectedPage = page
            return
        }
        do {
            hostController = try ReaderHostController(
                model: self,
                publication: publication,
                initialLocation: initial,
                preferences: Self.epubPreferences(prefs, theme: prefs.resolvedTheme(systemIsDark: false), columns: .one)
            )
        } catch {
            errorMessage = "This book couldn't be opened: \(error.localizedDescription)"
        }
        if LaunchOptions.showChrome { chromeVisible = true }
    }

    // MARK: Derived

    var preferences: ReaderPreferences { app.preferences.effective(for: bookID) }
    var followsDefault: Bool { app.preferences.followsDefault(bookID) }
    var systemIsDark = false
    var theme: ReaderTheme { preferences.resolvedTheme(systemIsDark: systemIsDark) }
    var reduceMotion = false
    var pageTurn: PageTurnStyle { preferences.effectivePageTurn(reduceMotion: reduceMotion) }
    var totalProgression: Double { location?.locations.totalProgression ?? 0 }
    /// The heading above the first line on screen, for books without contents.
    var heading: String?
    /// The chapter, as the book's contents name it; the page's heading only when there are no contents.
    var chapterTitle: String? {
        if let href = location?.href.string, let title = contents.title(href: href, precedingFragment: contentsFragment) {
            return ReaderJS.tidyHeading(title)
        }
        return heading ?? chapterMap.chapter(at: totalProgression)?.title ?? location?.title
    }
    /// The contents entry the reader is in: the one whose anchor is above the first line on screen,
    /// else the file's own entry, else the chapter by progression.
    var currentTOCEntryID: Int? {
        if let href = location?.href.string {
            let here = toc.filter { ContentsIndex.sameResource($0.link.url().removingFragment().string, href) }
            if let fragment = contentsFragment, let hit = here.last(where: { $0.link.url().fragment == fragment }) { return hit.id }
            if let whole = here.first(where: { $0.link.url().fragment == nil }) { return whole.id }
        }
        let level0 = toc.filter { $0.level == 0 }
        guard let i = chapterMap.chapterIndex(at: totalProgression), i < level0.count else { return nil }
        return level0[i].id
    }

    var pageLabel: String {
        let page = chapterMap.page(at: totalProgression)
        return "\(page) of \(chapterMap.positionCount)"
    }
    var pagesLeftLabel: String? {
        guard chapterMap.positionCount > 1 else { return nil }
        let left = chapterMap.pagesLeftInChapter(at: totalProgression)
        switch left {
        case 0, 1: return "Last page in chapter"
        default: return "\(left) pages left in chapter"
        }
    }

    // MARK: Loading

    func load() async {
        let positions = (try? await publication.positionsByReadingOrder().get()) ?? []
        let count = positions.reduce(0) { $0 + $1.count }
        readerLog.notice("open: positions after \(Date().timeIntervalSince(self.openedAt), privacy: .public) s; location \(self.page?.currentLocation != nil, privacy: .public)")
        var starts: [String: Double] = [:]
        for (i, link) in publication.readingOrder.enumerated() where i < positions.count {
            starts[link.url().removingFragment().string] = positions[i].first?.locations.totalProgression ?? 0
        }
        let tocLinks = (try? await publication.tableOfContents().get()) ?? []
        var entries: [TOCEntry] = []
        func walk(_ links: [ReadiumShared.Link], level: Int) {
            for link in links {
                let key = link.url().removingFragment().string
                entries.append(TOCEntry(id: entries.count, title: link.title ?? "Untitled", level: level, link: link, progression: starts[key] ?? 0))
                walk(link.children, level: level + 1)
            }
        }
        walk(tocLinks, level: 0)
        let raw = entries.map { ContentsIndex.Entry(title: $0.title, href: $0.link.url().removingFragment().string, fragment: $0.link.url().fragment, level: $0.level) }
        // Contents start at chapter one, with human titles; the licence marks where the story ends.
        let kept = ContentsCleaner.clean(raw, bookTitle: fullTitle)
        toc = kept.enumerated().map { i, k in
            let e = entries[k.index]
            return TOCEntry(id: i, title: k.title, level: e.level, link: e.link, progression: e.progression)
        }
        if toc.isEmpty { toc = entries }
        storyEnd = BookEnd.backMatter(in: raw)
        readingOrderHrefs = publication.readingOrder.map { $0.url().removingFragment().string }
        resourceStarts = readingOrderHrefs.map { starts[$0] ?? 0 }
        contents = ContentsIndex(
            entries: toc.map { .init(title: $0.title, href: $0.link.url().removingFragment().string, fragment: $0.link.url().fragment, level: $0.level) },
            readingOrder: readingOrderHrefs
        )
        mapper = await BookPositions.mapper(for: publication)
        readerLog.notice("open: mapper after \(Date().timeIntervalSince(self.openedAt), privacy: .public) s; location \(self.page?.currentLocation != nil, privacy: .public)")
        chapterMap = ChapterMap(chapters: toc.filter { $0.level == 0 }.map { .init(title: $0.title, start: $0.progression) }, positionCount: max(1, count))

        // The first page can take seconds to lay out on a cold web view; nothing below means anything
        // until the navigator reports where it is.
        await waitForLocation()
        readerLog.notice("open: location after \(Date().timeIntervalSince(self.openedAt), privacy: .public) s")
        if LaunchOptions.goTo == nil, let initialLocator { await settle(on: initialLocator, move: moves) }
        // A test's launch jump shows its page once, after the jump, not the book's start first.
        if LaunchOptions.goTo == nil { markReady() }
        if let goTo = LaunchOptions.goTo, let locator = await publication.locate(progression: goTo) {
            hasMoved = true
            moves += 1
            // Readium refuses a jump while it is still loading; try until it takes.
            var tries = 0
            while await page?.go(to: locator) != true, tries < 50 {
                tries += 1
                try? await Task.sleep(for: .milliseconds(200))
            }
            // Readium can report the old resource for a moment after the jump; the first place taken
            // must name the resource whose words are on screen, so wait until it reports the new one.
            for _ in 0..<25 where page?.currentLocation.map({ !ContentsIndex.sameResource($0.href.string, locator.href.string) }) ?? true {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        try? await Task.sleep(for: .milliseconds(300))
        await captureAnchor()
        markReady()
        app.library.noteSession(bookID)
        await checkRemote()
        // Landed (or there was nowhere to land): show the page.
        if awaitingLanding {
            awaitingLanding = false
            markReady()
        }
    }

    /// The first page has painted: the cover placeholder cross-fades to it.
    private func markReady() {
        guard !pageReady, !awaitingLanding, page?.currentLocation != nil else { return }
        readerLog.notice("first page ready after \(Date().timeIntervalSince(self.openedAt), privacy: .public) s")
        withAnimation(.easeOut(duration: 0.3)) { pageReady = true }
    }

    /// The cover placeholder's own timeout: a page that never reports in still shows.
    func forceReady() {
        guard !pageReady else { return }
        readerLog.notice("first page forced ready after \(Date().timeIntervalSince(self.openedAt), privacy: .public) s")
        withAnimation(.easeOut(duration: 0.3)) { pageReady = true }
    }

    private func waitForLocation() async {
        for _ in 0..<150 where page?.currentLocation == nil {
            try? await Task.sleep(for: .milliseconds(200))
        }
        if location == nil { location = page?.currentLocation }
    }

    /// Ask the other device where it is; offer a jump if it's further ahead. A request that arrives while
    /// one is running (the app coming back to the foreground mid-load) runs once that one ends.
    func checkRemote() async {
        guard !isClosed else { return }
        if checkingRemote {
            recheckRemote = true
            return
        }
        checkingRemote = true
        defer { checkingRemote = false }
        repeat {
            recheckRemote = false
            await checkRemoteOnce()
        } while recheckRemote && !isClosed
    }

    private func checkRemoteOnce() async {
        // Our own place coming back is not news.
        guard let book = app.library.book(bookID), let remote = await app.library.remotePosition(for: book),
              remote.source != .gatefold, !isClosed else { return }
        let target = await place(of: remote)
        guard !isClosed else { return }
        // A place the Cloud only has as a whole percent compares as one: our own 30.1% reads back as 31%.
        let percentOnly = target.locator == nil
        readerLog.notice("remote check: remote \(target.totalProgression, privacy: .public) here \(self.totalProgression, privacy: .public)")
        guard JumpSuggestion.isAhead(remote: target.totalProgression, percentOnly: percentOnly, local: totalProgression) else { return }
        let aim = landingTarget(remote, at: target.totalProgression)
        // First time this book opens here: there's no place of ours to protect, so just open where
        // the InkPad is, like picking the book up off the nightstand.
        if openedSnapshot == nil, !hasMoved {
            readerLog.notice("first open: landing on the Cloud place \(remote.pointer ?? "no pointer", privacy: .public)")
            await land(on: target.locator, progression: target.totalProgression, target: aim, rememberBack: false)
            guard !isClosed else { return }
            awaitingLanding = false
            markReady()
            showSlip(.landed(device: remote.deviceName, updated: remote.updated, now: Date()), kind: .landed)
            if let locator = target.locator { host?.underline(locator, color: theme.palette.accent) }
            return
        }
        let made = JumpSuggestion.make(
            local: hasMoved ? app.library.book(bookID)?.localSnapshot : openedSnapshot,
            remote: ProgressSnapshot(totalProgression: target.totalProgression, updated: remote.updated, device: remote.deviceName),
            totalPages: chapterMap.positionCount > 1 ? chapterMap.positionCount : nil,
            remotePercentOnly: percentOnly
        )
        guard let made else { return }
        readerLog.notice("remote ahead: \(remote.pointer ?? "no pointer", privacy: .public) → \(target.locator?.text.highlight ?? "no text", privacy: .private)")
        suggestionLocator = target.locator
        suggestionRemote = aim
        withAnimation(Motion.banner) { suggestion = made }
        let pages = chapterMap.positionCount > 1 && !percentOnly
            ? chapterMap.page(at: target.totalProgression) - chapterMap.page(at: totalProgression) : nil
        let percent = ReadingPercent.whole(target.totalProgression) - ReadingPercent.whole(totalProgression)
        showSlip(.ahead(
            device: remote.deviceName,
            pagesAhead: pages,
            percentAhead: percent,
            chapter: chapterMap.chapter(at: target.totalProgression)?.title,
            passage: target.locator?.text.highlight
        ), kind: .ahead)
    }

    private func showSlip(_ new: SyncSlip, kind: SlipKind) {
        slipTask?.cancel()
        withAnimation(Motion.banner) {
            slip = new
            slipKind = kind
        }
        slipCount += 1
        // "From your InkPad" is news, not a question: it goes by itself.
        guard kind == .landed else { return }
        slipTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.hideSlip()
        }
    }

    func hideSlip() {
        slipTask?.cancel()
        withAnimation(.easeOut(duration: 0.35)) {
            slip = nil
            slipKind = nil
        }
    }

    /// The other device's place as we would record it: its own CFI, on our scale.
    private func landingTarget(_ remote: ReadingPosition, at totalProgression: Double) -> ReadingPosition {
        var aim = remote
        aim.totalProgression = totalProgression
        return aim
    }

    /// Where a Cloud position is in this book: the exact spot when its CFI resolves, on Readium's own
    /// scale so it compares fairly with ours; else the Cloud's percent.
    private func place(of remote: ReadingPosition) async -> (locator: Locator?, totalProgression: Double) {
        guard let mapper, let found = await mapper.location(for: remote),
              let index = readingOrderHrefs.firstIndex(where: { ContentsIndex.sameResource($0, found.href) }),
              let total = ReadingScale.totalProgression(resourceIndex: index, progression: found.progression ?? 0, resourceStarts: resourceStarts),
              let start = await publication.locate(publication.readingOrder[index]) else {
            return (nil, remote.totalProgression)
        }
        // The first words at the spot let Readium land on the exact page, whatever the layout.
        let words = found.textAfter.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(48)) }
        let locator = start.copy(
            locations: {
                $0.progression = found.progression
                $0.totalProgression = total
            },
            text: { $0 = Locator.Text(highlight: words.flatMap { $0.count >= 8 ? $0 : nil }) }
        )
        return (locator, total)
    }

    func acceptSuggestion() async {
        guard let s = suggestion, !isClosed else { return }
        withAnimation(Motion.banner) { suggestion = nil }
        hideSlip()
        let locator = suggestionLocator, aim = suggestionRemote
        suggestionLocator = nil
        suggestionRemote = nil
        // The pages riffle past on the way, the way a thumb finds a place in a real book.
        await veiled(riffle: true, forward: s.targetProgression >= totalProgression) {
            await self.land(on: locator, progression: s.targetProgression, target: aim, rememberBack: true)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        if let locator { host?.underline(locator, color: theme.palette.accent) }
        holdJumpBack()
    }

    /// The Back pill stays for 8 seconds after a Jump, controls or not.
    private func holdJumpBack() {
        jumpBackTask?.cancel()
        withAnimation(Motion.chrome) { showJumpBack = backLocator != nil }
        jumpBackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.chrome) { self?.showJumpBack = false }
        }
    }

    /// A jump keeps the old page on screen, dimmed, until the new one has painted, then cross-fades.
    private func veiled(riffle: Bool = false, forward: Bool = true, _ body: @escaping () async -> Void) async {
        if let host {
            await host.veiledJump(riffle: riffle && !reduceMotion && pageTurn == .curl, forward: forward, body)
        } else {
            await body()
        }
    }

    /// Goes to another device's place: the exact spot when its CFI resolved, else its percent.
    /// Records the place once, when the page has settled, and never earlier than `target`.
    private func land(on locator: Locator?, progression: Double, target: ReadingPosition?, rememberBack: Bool) async {
        guard !isClosed else { return }
        guard let locator else {
            await go(toProgression: progression, rememberBack: rememberBack)
            return
        }
        hasMoved = true
        if rememberBack { rememberPlace() }
        moves += 1
        let move = moves
        landingMove = move
        defer { if landingMove == move { landingMove = nil } }
        await page?.go(to: locator)
        // Opening another chapter, Readium places the page by progression before the chapter has laid
        // out; once it has, the same jump finds the exact words. Retry until they're on screen.
        await settle(on: locator, move: move)
        // Overtaken by a turn, another jump or the close: that move owns the place now.
        guard moves == move, !isClosed else { return }
        await captureAnchor()
        guard moves == move, !isClosed, let here = page?.currentLocation else { return }
        // Landed on the other device's page: that's the reader's place now.
        await recordLanding(here, target: target)
    }

    /// Records a settled landing. The first words on screen are the place, unless they come before the
    /// place we landed on (the page starts a few lines above it): then the target itself is, so the
    /// other device's place comes back unchanged instead of a few lines behind.
    private func recordLanding(_ here: Locator, target: ReadingPosition?) async {
        location = here
        let fresh = anchorLocator.flatMap { a in
            a.href == here.href && a.locations.progression == here.locations.progression ? a : nil
        }
        let settledLocator = fresh ?? here
        let now = Date()
        let settled = await mapper?.position(for: BookLocation(settledLocator), at: now)
            .map { var p = $0; p.totalProgression = here.locations.totalProgression ?? p.totalProgression; return p }
        guard !isClosed else { return }
        let chosen = LandingPlace.choose(settled: settled, target: target, at: now)
        if let json = try? settledLocator.jsonString() {
            app.library.recordPlace(
                bookID: bookID,
                locatorJSON: json,
                totalProgression: chosen?.totalProgression ?? here.locations.totalProgression ?? 0,
                progression: here.locations.progression ?? 0,
                position: chosen,
                at: now
            )
        }
        openedLocation = here
        refreshBookmarkState(await page?.visibleRange())
    }

    /// Readium places the page by its own progression, which counts layout, not text; once the
    /// chapter is on screen, find the locator's words in it and turn to their page. Stops as soon as
    /// anything else moves the page (`move` is no longer the latest) or the reader closes.
    private func settle(on locator: Locator, move: Int) async {
        guard let words = locator.text.highlight.map(ReaderJS.normalize), words.count >= 8 else { return }
        let probe = String(words.prefix(24))
        func current() -> Bool { moves == move && !isClosed }
        for _ in 0..<4 {
            try? await Task.sleep(for: .milliseconds(250))
            guard current() else { return }
            let onScreen = await page?.visibleRange()?.text.map(ReaderJS.normalize) ?? ""
            guard current() else { return }
            if onScreen.contains(probe) { return }
            guard let exact = await page?.progression(of: words) else { continue }
            guard current() else { return }
            _ = await page?.go(to: locator.copy(locations: { $0.progression = exact }, text: { $0 = Locator.Text() }))
        }
    }

    /// The reader closed the book: whatever is still settling or landing stops here, so nothing moves
    /// the page or records a place after the close has sent the last one.
    func close() {
        isClosed = true
        moves += 1
        slipTask?.cancel()
        jumpBackTask?.cancel()
        slip = nil
        suggestion = nil
        suggestionLocator = nil
        suggestionRemote = nil
    }

    func dismissSuggestion() {
        suggestionLocator = nil
        suggestionRemote = nil
        withAnimation(Motion.banner) { suggestion = nil }
        hideSlip()
    }

    // MARK: Layout

    func updateLayout(_ new: ReaderLayout, reason: ReflowReason) {
        guard new != layout else { return }
        readerLog.notice("layout \(new.posture.rawValue, privacy: .public) \(new.pageFrame.width, privacy: .public)x\(new.pageFrame.height, privacy: .public)")
        let columnsChanged = new.columns != layout.columns || (new.posture == .tabletop) != (layout.posture == .tabletop)
        if new.posture != layout.posture || new.pageFrame.size != layout.pageFrame.size {
            pendingReflowReason = reason
        }
        layout = new
        if columnsChanged { applyPreferences(reflow: true) }
    }

    func consumeReflowReason() -> ReflowReason? {
        defer { pendingReflowReason = nil }
        return pendingReflowReason
    }

    private var reflowCount = 0

    func reflowDidBegin() {
        reflowCount += 1
        anchorCheck = "settling \(reflowCount)"
    }

    private var reflowSettledAt: Date?

    func reflowDidFinish(visible: VisibleRange?) {
        reflowSettledAt = Date()
        if let visible, let anchor = keeper.anchor {
            anchorCheck = (visible.contains(anchor) ? "anchor-visible " : "anchor-lost ") + "\(reflowCount)"
            anchorDetail = "anchor \(anchor.href)@\(anchor.progression) [\(anchor.text?.prefix(40) ?? "-")] visible \(visible.href) \(visible.start)..\(visible.end) [\(visible.text?.prefix(60) ?? "nil")]"
        } else {
            anchorCheck = "no-anchor \(reflowCount)"
        }
        refreshBookmarkState(visible)
    }

    func locator(for anchor: ReadingAnchor) -> Locator? {
        anchorLocator
    }

    // MARK: Navigation events

    func locationDidChange(_ locator: Locator, duringTurn: Bool = false) async {
        guard !isClosed else { return }
        location = locator
        // The navigator opens on the saved place, so its first report is a page worth showing: don't
        // keep the cover up while the rest of the book is indexed.
        if !pageReady, LaunchOptions.goTo == nil { markReady() }
        if !duringTurn, hasMoved, isPastStory(locator) { reachedEnd() }
        // A landing records its place once it has settled; the steps on the way are not places.
        guard !landing else { return }
        // Mid-turn the navigator has moved under the overlay; the turn records the place when it lands.
        guard keeper.reflowing == nil, !duringTurn else { return }
        // A location that arrives as a reflow lands is the restore, not the reader moving: keep the
        // anchor, or repeated reflows would walk it backward a page at a time.
        if let settled = reflowSettledAt, Date().timeIntervalSince(settled) < 1.2 {
            readerLog.notice("location after reflow; anchor kept")
        } else {
            await captureAnchor()
            if touchedSinceLocation, !hasMoved {
                if let opened = openedLocation {
                    if opened.href != locator.href || opened.locations.progression != locator.locations.progression { hasMoved = true }
                } else {
                    openedLocation = locator
                }
            }
            if openedLocation == nil { openedLocation = locator }
        }
        touchedSinceLocation = false
        // Only the reader moves the place. Readium reopening a page boundary off from the saved one is
        // not a move, so opening a book never overwrites a further-ahead place on the InkPad.
        guard hasMoved else { return refreshBookmarkState(await page?.visibleRange()) }
        // The first words on screen make the place exact; Readium's progression is a page boundary.
        // Only words captured on this very page count; a capture a reflow cut short leaves the last page's.
        let fresh = anchorLocator.flatMap { a in
            a.href == locator.href && a.locations.progression == locator.locations.progression ? a : nil
        }
        let here = fresh ?? locator
        if let json = try? here.jsonString() {
            let now = Date()
            let exact = await mapper?.position(for: BookLocation(here), at: now)
            app.library.recordPlace(
                bookID: bookID,
                locatorJSON: json,
                totalProgression: locator.locations.totalProgression ?? 0,
                progression: locator.locations.progression ?? 0,
                position: exact.map { var p = $0; p.totalProgression = locator.locations.totalProgression ?? p.totalProgression; return p },
                at: now
            )
        }
        refreshBookmarkState(await page?.visibleRange())
        if let back = backLocator, abs((back.locations.totalProgression ?? 0) - totalProgression) < 0.0001 {
            backLocator = nil
        }
    }

    /// A touch on the page. If the next location (outside a reflow) differs from where the book
    /// opened, it was a swipe in slide or scroll mode and the place is the reader's own. A tap that
    /// only shows the controls changes no location, so it moves nothing.
    func noteInteraction() { touchedSinceLocation = true }
    private var touchedSinceLocation = false
    private var openedLocation: Locator?

    /// A turn landed or sprang back: take the place from where the navigator is now.
    func userTurnedPage() {
        hasMoved = true
        moves += 1
        Task {
            guard let first = page?.currentLocation else { return }
            await locationDidChange(first)
            // Turning into the next resource, Readium can name the old one until the new one has
            // loaded, and its update arrives mid-turn when it's ignored. Look again once it has.
            try? await Task.sleep(for: .milliseconds(700))
            if let later = page?.currentLocation, later.href != first.href
                || later.locations.progression != first.locations.progression {
                await locationDidChange(later)
            }
        }
    }

    /// Takes the first words on screen as the reader's place, unless a reflow is moving the page.
    func captureAnchor() async {
        guard keeper.reflowing == nil, let (anchor, anchorLoc) = await page?.currentAnchor(), keeper.reflowing == nil else { return }
        readerLog.notice("anchor \(anchor.text ?? "nil", privacy: .private)")
        keeper.userSettled(on: anchor)
        if keeper.anchor == anchor { anchorLocator = anchorLoc }
        // The first place taken says "ready", whether or not a reflow (an unfolded Duo's first layout)
        // came before it.
        if !anchorReady, anchor.text != nil {
            anchorReady = true
            anchorCheck = "ready \(reflowCount)"
        }
    }

    // MARK: The end

    struct EndLeaf: Equatable {
        var line: String
        var cloud: Bool
        var markedOnCloud = false
    }

    /// The page is in the back matter (a Project Gutenberg licence that has a file of its own). A book
    /// without one ends when a forward turn finds no next page.
    func isPastStory(_ locator: Locator) -> Bool {
        guard let end = storyEnd, end.fragment == nil else { return false }
        return ContentsIndex.sameResource(locator.href.string, end.href)
    }

    /// The reader turned past the last page of the story: the end leaf, once.
    func reachedEnd() {
        guard endLeaf == nil, !isClosed else { return }
        let now = Date()
        app.library.markFinished(bookID, at: now)
        let book = app.library.book(bookID)
        let line = FinishLine.text(started: book?.started, finished: book?.finished ?? now, sessions: book?.sessions ?? 1)
        setChrome(false)
        withAnimation(reduceMotion ? .easeOut(duration: 0.25) : .spring(duration: 0.6, bounce: 0.15)) {
            endLeaf = EndLeaf(line: line, cloud: book?.cloud != nil)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// "Mark Finished on InkPad": 100 % and read in the Cloud.
    func markFinishedOnCloud() async {
        guard endLeaf?.markedOnCloud == false else { return }
        withAnimation(.snappy) { endLeaf?.markedOnCloud = true }
        await app.library.markFinishedInCloud(bookID)
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.6)
    }

    /// Back from the end leaf to the last page of the story.
    func leaveEndLeaf() {
        withAnimation(.easeOut(duration: 0.25)) { endLeaf = nil }
    }

    // MARK: Chrome

    func setChrome(_ visible: Bool) {
        withAnimation(Motion.chrome) { chromeVisible = visible }
    }

    // MARK: Jumps

    func go(toProgression progression: Double, rememberBack: Bool) async {
        hasMoved = true
        moves += 1
        if rememberBack { rememberPlace() }
        if let locator = await publication.locate(progression: progression) {
            await veiled { _ = await self.page?.go(to: locator) }
            await captureAnchor()
        }
    }

    func go(to entry: TOCEntry) async {
        hasMoved = true
        moves += 1
        rememberPlace()
        await veiled { await self.page?.go(to: entry.link) }
        await captureAnchor()
    }

    func go(to bookmark: Bookmark) async {
        rememberPlace()
        await go(toProgression: bookmark.totalProgression, rememberBack: false)
    }

    func goBack() async {
        guard let back = backLocator else { return }
        hasMoved = true
        moves += 1
        backLocator = nil
        jumpBackTask?.cancel()
        withAnimation(Motion.chrome) { showJumpBack = false }
        await veiled { _ = await self.page?.go(to: back) }
        await captureAnchor()
    }

    private func rememberPlace() {
        backLocator = location
        backPage = chapterMap.page(at: totalProgression)
    }

    // MARK: Bookmarks

    func toggleBookmark() async {
        guard let page, let (anchor, _) = await page.currentAnchor(), let visible = await page.visibleRange() else { return }
        let change = bookmarks.toggle(
            at: anchor,
            visible: VisibleRange(href: visible.href, start: visible.start, end: anchor.progression + 0.0001, text: visible.text),
            title: chapterTitle ?? title,
            totalProgression: totalProgression
        )
        saveBookmarks()
        withAnimation(.spring(duration: 0.3, bounce: 0.35)) { isBookmarked = change == .added }
    }

    func removeBookmark(_ id: UUID) {
        bookmarks.remove(id)
        saveBookmarks()
        Task { refreshBookmarkState(await page?.visibleRange()) }
    }

    private func saveBookmarks() {
        let list = bookmarks
        app.library.update(bookID) { $0.bookmarks = list }
    }

    /// For UI tests: the words on screen, as of the last settled page.
    private(set) var visibleTextProbe = ""

    private func refreshBookmarkState(_ visible: VisibleRange?) {
        if LaunchOptions.isUITest, let text = visible?.text { visibleTextProbe = String(text.prefix(600)) }
        guard let location else { return }
        let here = location.href.string
        let p = location.locations.progression ?? 0
        // A bookmark marks this page when its anchor sits between this page's start and the next's.
        let marked = bookmarks.items.contains { mark in
            mark.anchor.href == here && abs(mark.anchor.progression - p) < 0.0005
                || (visible?.text.map { text in mark.anchor.text.map { text.contains($0) } ?? false } ?? false)
        }
        if marked != isBookmarked {
            withAnimation(.spring(duration: 0.3, bounce: 0.35)) { isBookmarked = marked }
        }
    }

    // MARK: Preferences

    func setPreferences(_ change: (inout ReaderPreferences) -> Void) {
        let before = preferences
        app.preferences.update(bookID, change)
        let after = preferences
        let reflows = before.font != after.font || before.fontScale != after.fontScale
            || before.lineSpacing != after.lineSpacing || before.margins != after.margins
            || before.justify != after.justify || (before.pageTurn == .scroll) != (after.pageTurn == .scroll)
        if reflows { pendingReflowReason = .typography }
        applyPreferences(reflow: reflows)
    }

    func useAsDefault() {
        app.preferences.useAsDefault(from: bookID)
    }

    func applyPreferences(reflow: Bool) {
        let prefs = preferences
        host?.apply(
            Self.epubPreferences(prefs, theme: theme, columns: layout.columns, tabletop: layout.posture == .tabletop),
            columns: layout.columns == .two ? 2 : 1,
            reflow: reflow
        )
        host?.disablePanningIfNeeded()
    }

    /// Tabletop's half-height page keeps no more than the Normal side margins.
    static func epubPreferences(_ prefs: ReaderPreferences, theme: ReaderTheme, columns: GatefoldCore.ColumnCount, tabletop: Bool = false) -> EPUBPreferences {
        let custom = prefs.font != .original || prefs.lineSpacing != .normal || prefs.justify
        return EPUBPreferences(
            backgroundColor: ReadiumNavigator.Color(hex: ThemePalette.hexString(theme.palette.background)),
            columnCount: columns == .two ? .two : .one,
            fontFamily: prefs.font.cssFamily.map { FontFamily(rawValue: $0) },
            fontSize: prefs.fontScale,
            hyphens: prefs.justify ? true : nil,
            lineHeight: custom ? prefs.lineSpacing.lineHeight : nil,
            pageMargins: tabletop ? min(prefs.margins.factor, PageMargins.normal.factor) : prefs.margins.factor,
            publisherStyles: !custom,
            scroll: prefs.pageTurn == .scroll,
            textAlign: prefs.justify ? .justify : nil,
            textColor: ReadiumNavigator.Color(hex: ThemePalette.hexString(theme.palette.text)),
            theme: theme.palette.isDark ? .dark : .light
        )
    }
}
