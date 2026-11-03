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
    /// The "read on without you" slip, tucked into a tab at the page's top edge: a turn means stay.
    private(set) var slipFolded = false
    private(set) var aheadTab: String?
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
    /// The InkPad's highlights and notes, and the reader's own (Highlights.swift).
    let highlights: HighlightStore
    /// The first page is on screen and legible.
    private(set) var pageReady = false
    /// Reopened at launch: the page as he left it, shown until the live page has laid out beneath it.
    var reopenPicture: UIImage? {
        didSet { if reopenPicture != nil { reopened = true } }
    }
    /// Opened at launch over his page's picture (stays true after the picture goes): the reader then
    /// came up without the zoom from its cover, and must keep that one presentation throughout.
    private(set) var reopened = false
    /// The page frame the reopen picture was laid out with, if known.
    var reopenPageFrame: CGRect?
    /// The live page laid out differently from the picture (the first launch after an install can
    /// place the page a little lower): the picture then fades out instead of being swapped away.
    private(set) var reopenFades = false
    let openedAt = Date()
    /// When the reader asked for the book: the tap, for a book opened ahead of it behind the shelf.
    var askedAt = Date()
    /// The shelf state a warm open was made for; a change opens it afresh.
    var warmKey: String?
    /// Opened ahead of a tap, behind the shelf: everything up to the first page, nothing the reader
    /// would notice (no session, no Cloud check, no slip) until `activate()`.
    private(set) var isWarming = false
    private var activation: CheckedContinuation<Void, Never>?
    private var loadStarted = false
    /// A landing made behind the shelf, recorded when the reader taps the book.
    @ObservationIgnored private var pendingRecord: (@MainActor (Date) -> Void)?

    /// Opens the book behind the shelf, so a tap on it shows a page that's already there.
    func warm() {
        guard !loadStarted else { return }
        isWarming = true
        Task { await load() }
    }

    /// The reader tapped the book: carry on from wherever the warm open got to.
    func activate() {
        guard isWarming else { return }
        isWarming = false
        askedAt = Date()
        readerLog.notice("open: tapped a warm book; page ready \(self.pageReady, privacy: .public)")
        if pageReady { readerLog.notice("first page ready after 0 s (opened ahead of the tap)") }
        activation?.resume()
        activation = nil
        if let record = pendingRecord {
            pendingRecord = nil
            record(Date())
        }
        if let landed = pendingLanded {
            pendingLanded = nil
            // After the zoom has brought the page up, so the line draws in where the reader can see it.
            Task {
                try? await Task.sleep(for: .milliseconds(450))
                guard !isClosed else { return }
                showLanded(landed.slip, underline: landed.underline)
            }
        }
    }

    private func untilActive() async {
        guard isWarming, !isClosed else { return }
        await withCheckedContinuation { activation = $0 }
    }
    /// Set once the reader has settled after a reflow (for UI tests): whether the anchor is on screen.
    private(set) var anchorCheck = "pending 0"
    private var anchorReady = false
    /// For UI tests: what the last check compared.
    private(set) var anchorDetail = ""

    var keeper = AnchorKeeper()
    private var anchorLocator: Locator?
    private var pendingReflowReason: ReflowReason?
    weak var host: ReaderHostController?
    /// A picture of the page taken as the hinge started to move (`ReaderHostController.holdPageForUnfold`).
    /// It lives here, not in the host, so it survives the app moving to the Duo's inner screen.
    @ObservationIgnored var heldPicture: UIImage?
    @ObservationIgnored var heldPage: HeldPage?
    private(set) var hostController: ReaderHostController?
    /// A scripted page for unit tests; the app always reads the host's.
    @ObservationIgnored private var injectedPage: (any ReaderPage)?
    private var page: (any ReaderPage)? { injectedPage ?? host }
    /// This device's place when the book was opened, for the "further ahead" comparison.
    private let openedSnapshot: ProgressSnapshot?
    /// First open here of a book the InkPad has a place in: the cover stays up until the reader has
    /// landed there, so the book's first page never flashes past (or loads blank) on the way.
    private var awaitingLanding: Bool
    /// Our own place was front matter, so the InkPad's place is opened directly, as on a first open.
    private var landsOverFrontMatter = false
    /// The Cloud's place as the shelf last saw it, to decide before asking whether to land there.
    private let cloudHint: Double?
    /// A landing made behind the shelf says so once the reader is looking.
    private var pendingLanded: (slip: SyncSlip, underline: Locator?)?
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
    /// The Cloud's own progress at the suggested place, for keeping our numbers on its scale.
    private var suggestionCloud: Double?
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
        self.cloudHint = book.remote?.totalProgression ?? book.cloud?.readPercent.map { Double($0) / 100 }
        self.highlights = HighlightStore(bookID: book.id, cloudBook: book.cloud, sync: app.sync)
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
                preferences: Self.epubPreferences(prefs, theme: prefs.resolvedTheme(systemIsDark: false), columns: .one, language: Self.hyphenationLanguage(publication))
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
    /// The running head held on the old page's chapter while a jump's veil or riffle still shows that
    /// page; nil when it follows the page (see `runningHead`).
    var heldRunningHead: String??
    /// What the running head shows: the chapter of the page the reader can see.
    var runningHead: String? {
        if let held = heldRunningHead { return held }
        return chapterTitle
    }
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
        guard !loadStarted else { activate(); return }
        loadStarted = true
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
        readerLog.notice("open: toc after \(Date().timeIntervalSince(self.openedAt), privacy: .public) s")
        let raw = entries.map { ContentsIndex.Entry(title: $0.title, href: $0.link.url().removingFragment().string, fragment: $0.link.url().fragment, level: $0.level) }
        // Contents start at chapter one, with human titles; the licence marks where the story ends.
        let kept = ContentsCleaner.clean(raw, bookTitle: fullTitle)
        toc = kept.enumerated().map { i, k in
            let e = entries[k.index]
            return TOCEntry(id: i, title: k.title, level: e.level, link: e.link, progression: e.progression)
        }
        if toc.isEmpty { toc = entries }
        readerLog.notice("open: cleaned after \(Date().timeIntervalSince(self.openedAt), privacy: .public) s")
        storyEnd = BookEnd.backMatter(in: raw)
        readingOrderHrefs = publication.readingOrder.map { $0.url().removingFragment().string }
        resourceStarts = readingOrderHrefs.map { starts[$0] ?? 0 }
        contents = ContentsIndex(
            entries: toc.map { .init(title: $0.title, href: $0.link.url().removingFragment().string, fragment: $0.link.url().fragment, level: $0.level) },
            readingOrder: readingOrderHrefs
        )
        mapper = await BookPositions.mapper(for: publication)
        if let mapper { Task { await highlights.start(model: self, mapper: mapper) } }
        readerLog.notice("open: mapper after \(Date().timeIntervalSince(self.openedAt), privacy: .public) s; location \(self.page?.currentLocation != nil, privacy: .public)")
        chapterMap = ChapterMap(chapters: toc.filter { $0.level == 0 }.map { .init(title: $0.title, start: $0.progression) }, positionCount: max(1, count))
        // Chapters that begin partway through a file take their own page, after the page is up.
        Task { [weak self] in await self?.placeFragments(starts: starts, positionCount: max(1, count)) }
        // A place of ours that's still in the front matter (a list of illustrations, a title page) isn't
        // reading yet: when the InkPad has the book further on, open there instead of offering a Jump.
        if !awaitingLanding, let local = openedSnapshot?.totalProgression, let cloud = cloudHint, cloud > local + JumpSuggestion.threshold,
           FrontMatter.isUnread(local, storyStart: toc.first(where: { $0.level == 0 })?.progression ?? 0) {
            readerLog.notice("open: our place \(local, privacy: .public) is front matter; landing on the InkPad's")
            awaitingLanding = true
            landsOverFrontMatter = true
        }

        // The first page can take seconds to lay out on a cold web view; nothing below means anything
        // until the navigator reports where it is.
        await waitForLocation()
        readerLog.notice("open: location after \(Date().timeIntervalSince(self.openedAt), privacy: .public) s")
        if LaunchOptions.goTo == nil, let initialLocator { await settle(on: initialLocator, move: moves) }
        readerLog.notice("open: settled after \(Date().timeIntervalSince(self.openedAt), privacy: .public) s")
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
        // A book about to land on the InkPad's place takes its first place there, not on the cover.
        if !awaitingLanding {
            try? await Task.sleep(for: .milliseconds(300))
            await captureAnchor()
            markReady()
        }
        // A book landing on the InkPad's place lands before it shows, warm or not.
        var checked = false
        if awaitingLanding {
            await checkRemote()
            checked = true
            // Landed (or there was nowhere to land): show the page.
            awaitingLanding = false
            markReady()
        }
        await untilActive()
        guard !isClosed else { return }
        app.library.noteSession(bookID)
        if !checked { await checkRemote() }
    }

    /// The first page has painted: the cover placeholder cross-fades to it.
    private func markReady() {
        guard !pageReady, !awaitingLanding, !revealing, page?.currentLocation != nil else { return }
        revealing = true
        Task {
            // The cover stays until Readium has finished loading the page it reports (its spinner).
            let held = Date()
            for _ in 0..<80 where host?.isLoadingPage == true { try? await Task.sleep(for: .milliseconds(100)) }
            readerLog.notice("open: Readium's loading held \(Date().timeIntervalSince(held), privacy: .public) s (asked \(Date().timeIntervalSince(self.askedAt), privacy: .public) s ago)")
            revealing = false
            guard !pageReady else { return }
            Task { [weak self] in await self?.host?.logTypography() }
            readerLog.notice("first page ready after \(Date().timeIntervalSince(self.isWarming ? self.openedAt : self.askedAt), privacy: .public) s\(self.isWarming ? " (behind the shelf)" : "", privacy: .public)")
            showPage()
        }
    }
    private var revealing = false

    /// The cover gives way to the page. A reopen's picture of the page stays over it a moment longer,
    /// while the running head and footer come up beneath, then goes at once: the two are the same
    /// page, so nothing moves.
    private func showPage() {
        withAnimation(.easeOut(duration: 0.3)) { pageReady = true }
        guard reopenPicture != nil else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            await host?.waitForSettledPage()
            let same = reopenPageFrame.map { abs($0.minY - layout.pageFrame.minY) < 1 && abs($0.height - layout.pageFrame.height) < 1 && abs($0.width - layout.pageFrame.width) < 1 } ?? true
            if same {
                reopenPicture = nil
            } else {
                reopenFades = true
                withAnimation(.easeInOut(duration: 0.3)) { reopenPicture = nil }
            }
            readerLog.notice("reopen: the live page took the picture's place at \(LaunchClock.sinceLaunch, privacy: .public) s after launch (\(same ? "same layout, swapped" : "laid out differently, faded", privacy: .public))")
        }
    }

    /// The cover placeholder's own timeout: a page that never reports in still shows.
    func forceReady() {
        guard !pageReady else { return }
        readerLog.notice("first page forced ready after \(Date().timeIntervalSince(self.openedAt), privacy: .public) s")
        showPage()
    }

    /// Moves each contents entry that names a place inside its file (`ch.xhtml#ch8`) from the file's first
    /// page to its own: several chapters in one file otherwise all show that file's first page.
    private func placeFragments(starts: [String: Double], positionCount: Int) async {
        var ends: [String: Double] = [:]
        for (i, href) in readingOrderHrefs.enumerated() {
            ends[href] = i + 1 < readingOrderHrefs.count ? (starts[readingOrderHrefs[i + 1]] ?? 1) : 1
        }
        var files: [String: Data] = [:]
        var placed = toc
        for (i, entry) in toc.enumerated() {
            guard let fragment = entry.link.url().fragment, !fragment.isEmpty else { continue }
            let file = entry.link.url().removingFragment()
            let href = file.string
            guard let start = starts[href], let end = ends[href], end > start else { continue }
            if files[href] == nil {
                guard let data = try? await publication.get(file)?.read().get() else { continue }
                files[href] = data
            }
            guard !isClosed, let data = files[href], let fraction = FragmentPlace.fraction(of: fragment, in: data) else { continue }
            let progression = FragmentPlace.progression(fileStart: start, fileEnd: end, fraction: fraction)
            placed[i] = TOCEntry(id: entry.id, title: entry.title, level: entry.level, link: entry.link, progression: progression)
        }
        guard !isClosed, placed != toc else { return }
        toc = placed
        chapterMap = ChapterMap(chapters: toc.filter { $0.level == 0 }.map { .init(title: $0.title, start: $0.progression) }, positionCount: positionCount)
        readerLog.notice("contents: placed \(placed.filter { $0.link.url().fragment != nil }.count, privacy: .public) chapters inside their files")
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
        guard let book = app.library.book(bookID), let remote = await app.library.remotePosition(for: book),
              !isClosed else { return }
        // Our own place coming back is not news, except on a fresh install (a reinstall wipes the
        // shelf but not the Cloud): then it's where to open, and it's ours, never the InkPad's.
        let ours = remote.source == .gatefold
        if ours, openedSnapshot != nil || hasMoved { return }
        let target = await place(of: remote)
        guard !isClosed else { return }
        // A place the Cloud only has as a whole percent compares as one: our own 30.1% reads back as 31%.
        let percentOnly = target.locator == nil
        readerLog.notice("remote check: remote \(target.totalProgression, privacy: .public) here \(self.totalProgression, privacy: .public)")
        guard JumpSuggestion.isAhead(remote: target.totalProgression, percentOnly: percentOnly, local: totalProgression) else { return }
        let aim = landingTarget(remote, at: target.totalProgression)
        // First time this book opens here: there's no place of ours to protect, so just open where
        // the InkPad is, like picking the book up off the nightstand.
        if openedSnapshot == nil || landsOverFrontMatter, !hasMoved {
            readerLog.notice("first open: landing on the Cloud place \(remote.pointer ?? "no pointer", privacy: .public)")
            await land(on: target.locator, progression: target.totalProgression, target: aim, cloud: remote.totalProgression, rememberBack: false)
            guard !isClosed else { return }
            awaitingLanding = false
            markReady()
            let landed = ours
                ? SyncSlip.resumed(updated: remote.updated, now: Date())
                : SyncSlip.landed(device: remote.deviceName, updated: remote.updated, now: Date())
            if isWarming {
                pendingLanded = (landed, target.locator)
            } else {
                showLanded(landed, underline: target.locator)
            }
            return
        }
        if ours { return }
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
        suggestionCloud = remote.totalProgression
        withAnimation(Motion.banner) { suggestion = made }
        let pages = chapterMap.positionCount > 1
            ? chapterMap.page(at: target.totalProgression) - chapterMap.page(at: totalProgression) : nil
        let percent = ReadingPercent.whole(target.totalProgression) - ReadingPercent.whole(totalProgression)
        // A place the Cloud only has as a percent still gets its words: the sentence starting there.
        var passage = target.locator?.text.highlight
        if passage == nil, let found = await sentence(atTotalProgression: target.totalProgression) {
            passage = found.text
            // The words give the jump an exact place to land and a line to underline.
            if suggestionLocator == nil { suggestionLocator = found.locator }
        }
        guard !isClosed else { return }
        // The tap should land at once: load the Cloud place's page now, behind this one.
        if let locator = suggestionLocator { page?.prepareStandby(at: locator) }
        aheadTab = SyncSlip.tab(device: remote.deviceName, pagesAhead: pages)
        aheadTarget = (target.totalProgression, remote.deviceName)
        slipFolded = false
        showSlip(.ahead(
            device: remote.deviceName,
            pagesAhead: pages,
            approximate: percentOnly,
            percentAhead: percent,
            updated: remote.updated,
            now: Date(),
            passage: passage
        ), kind: .ahead)
    }

    /// The first words of the sentence at a place in the book, read from the book itself, and a
    /// locator that finds them.
    private func sentence(atTotalProgression total: Double) async -> (text: String, locator: Locator?)? {
        guard let index = resourceStarts.lastIndex(where: { $0 <= total }), index < publication.readingOrder.count else { return nil }
        let start = resourceStarts[index]
        let end = index + 1 < resourceStarts.count ? resourceStarts[index + 1] : 1
        let within = end > start ? (total - start) / (end - start) : 0
        nonisolated(unsafe) let publication = publication
        let link = publication.readingOrder[index]
        guard let resource = publication.get(link), let data = try? await resource.read().get(),
              let text = PassageText.sentence(inHTML: String(decoding: data, as: UTF8.self), at: within) else { return nil }
        // Cut at a word's end, so the underline that marks it never stops mid-word.
        let words = WordEdge.complete(highlight: String(text.prefix(60)), after: String(text.dropFirst(60))).highlight
        let locator = await publication.locate(link).map {
            $0.copy(locations: { $0.progression = within; $0.totalProgression = total },
                    text: { $0 = Locator.Text(highlight: words) })
        }
        return (text, locator)
    }

    @ObservationIgnored private var aheadTarget: (progression: Double, device: String)?

    /// The folded tab counts down as the reader catches up, and goes once they're there.
    private func refreshAheadTab() {
        guard let aim = aheadTarget, slipKind == .ahead, slip != nil, chapterMap.positionCount > 1 else { return }
        let pages = chapterMap.page(at: aim.progression) - chapterMap.page(at: totalProgression)
        if pages <= 0 {
            aheadTarget = nil
            dismissSuggestion()
            return
        }
        let label = SyncSlip.tab(device: aim.device, pagesAhead: pages)
        if label != aheadTab { aheadTab = label }
    }

    /// A page turn while the slip is up means "carry on here": it folds into its tab.
    func foldSlip() {
        guard slipKind == .ahead, slip != nil, !slipFolded else { return }
        slipTask?.cancel()
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.4, bounce: 0.15)) { slipFolded = true }
    }

    /// The tab, tapped: the slip opens again with its offer.
    func unfoldSlip() {
        guard slipFolded else { return }
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.4, bounce: 0.2)) { slipFolded = false }
        foldSlipLater()
    }

    /// Unanswered, the offer folds itself away after a while rather than sitting on the page.
    private func foldSlipLater() {
        slipTask?.cancel()
        slipTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.foldSlip()
        }
    }

    private func showLanded(_ landed: SyncSlip, underline: Locator?) {
        showSlip(landed, kind: .landed)
        if let underline { host?.underline(underline, color: theme.palette.accent) }
    }

    private func showSlip(_ new: SyncSlip, kind: SlipKind) {
        slipTask?.cancel()
        withAnimation(Motion.banner) {
            slip = new
            slipKind = kind
        }
        slipCount += 1
        // "From your InkPad" is news, not a question: it goes by itself. An offer folds away.
        guard kind == .landed else { return foldSlipLater() }
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
            slipFolded = false
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
        let words = found.textAfter.map {
            let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return WordEdge.complete(highlight: String(trimmed.prefix(48)), after: String(trimmed.dropFirst(48))).highlight
        }
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
        let locator = suggestionLocator, aim = suggestionRemote, cloud = suggestionCloud
        let tapped = ContinuousClock.now
        readerLog.notice("catch-up: tapped (exact place \(locator != nil, privacy: .public))")
        suggestionLocator = nil
        suggestionRemote = nil
        suggestionCloud = nil
        // The pages riffle past on the way, the way a thumb finds a place in a real book.
        await veiled(riffle: true, forward: s.targetProgression >= totalProgression) {
            await self.land(on: locator, progression: s.targetProgression, target: aim, cloud: cloud, rememberBack: true)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        if let locator {
            host?.underline(locator, color: theme.palette.accent)
            watchUnderline()
        }
        readerLog.notice("catch-up: underlined \(Self.ms(since: tapped), privacy: .public) ms after the tap")
        holdJumpBack()
    }

    /// For UI tests: the underline boxes drawn on screen, read every quarter second while it lasts.
    private(set) var underlineProbe = ""
    @ObservationIgnored private var underlineWatch: Task<Void, Never>?

    private func watchUnderline() {
        guard LaunchOptions.isUITest else { return }
        underlineWatch?.cancel()
        underlineWatch = Task { [weak self] in
            for _ in 0..<44 {
                guard let self, !Task.isCancelled, let host = self.host else { return }
                self.underlineProbe = "underline \(await host.underlineProbe())"
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    static func ms(since start: ContinuousClock.Instant) -> Int {
        let d = ContinuousClock.now - start
        return Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
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
        // Behind the cover placeholder there's nothing to veil.
        if let host, pageReady {
            await host.veiledJump(riffle: riffle && !reduceMotion && pageTurn == .curl, forward: forward, body)
        } else {
            await body()
        }
    }

    /// Goes to another device's place: the exact spot when its CFI resolved, else its percent.
    /// Records the place once, when the page has settled, and never earlier than `target`.
    private func land(on locator: Locator?, progression: Double, target: ReadingPosition?, cloud: Double? = nil, rememberBack: Bool) async {
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
        let started = ContinuousClock.now
        let ready = await page?.promoteStandby(for: locator) ?? false
        if !ready { await page?.go(to: locator) }
        let went = Self.ms(since: started)
        // Opening another chapter, Readium places the page by progression before the chapter has laid
        // out; once it has, the same jump finds the exact words. Retry until they're on screen.
        await settle(on: locator, move: move, loaded: ready)
        let settled = Self.ms(since: started)
        // Overtaken by a turn, another jump or the close: that move owns the place now.
        guard moves == move, !isClosed else { return }
        await captureAnchor()
        let anchored = Self.ms(since: started)
        guard moves == move, !isClosed, let here = page?.currentLocation else { return }
        // Landed on the other device's page: that's the reader's place now.
        await recordLanding(here, target: target, cloud: cloud)
        readerLog.notice("landing timing (standby \(ready, privacy: .public)): go \(went, privacy: .public) ms, settled \(settled, privacy: .public) ms, anchored \(anchored, privacy: .public) ms, recorded \(Self.ms(since: started), privacy: .public) ms")
    }

    /// Records a settled landing. The first words on screen are the place, unless they come before the
    /// place we landed on (the page starts a few lines above it): then the target itself is, so the
    /// other device's place comes back unchanged instead of a few lines behind.
    private func recordLanding(_ here: Locator, target: ReadingPosition?, cloud: Double? = nil) async {
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
        let landedAt = target?.totalProgression ?? here.locations.totalProgression
        let json = try? settledLocator.jsonString()
        let record: @MainActor (Date) -> Void = { [weak self] at in
            guard let self else { return }
            // The Cloud's percent for this place stands; reading on adds to it (`CloudScale`).
            if let cloud, let landedAt {
                self.app.library.landedOnCloudPlace(bookID: self.bookID, cloud: cloud, landed: landedAt)
                readerLog.notice("landed: the Cloud says \(cloud, privacy: .public), Readium \(landedAt, privacy: .public)")
            }
            if let json {
                self.app.library.recordPlace(
                    bookID: self.bookID,
                    locatorJSON: json,
                    totalProgression: chosen?.totalProgression ?? here.locations.totalProgression ?? 0,
                    progression: here.locations.progression ?? 0,
                    position: chosen.map { var p = $0; p.updated = at; return p },
                    at: at
                )
            }
        }
        // Behind the shelf nothing is opened yet: recording now would make the book "just read",
        // shuffle Reading Now under the reader's eyes and send the Cloud a place nobody read. The tap records it.
        if isWarming { pendingRecord = record } else { record(now) }
        openedLocation = here
        refreshBookmarkState(await page?.visibleRange())
    }

    /// Readium places the page by its own progression, which counts layout, not text; once the
    /// chapter is on screen, find the locator's words in it and turn to their page. Stops as soon as
    /// anything else moves the page (`move` is no longer the latest) or the reader closes.
    private func settle(on locator: Locator, move: Int, loaded: Bool = false) async {
        guard let words = locator.text.highlight.map(ReaderJS.normalize), words.count >= 8 else { return }
        let probe = String(words.prefix(24))
        func current() -> Bool { moves == move && !isClosed }
        let t0 = ContinuousClock.now
        for round in 0..<4 {
            // A page already loaded (the standby) can be read at once.
            if round > 0 || !loaded { try? await Task.sleep(for: .milliseconds(250)) }
            guard current() else { return }
            let onScreen = await page?.visibleRange()?.text.map(ReaderJS.normalize) ?? ""
            let read = Self.ms(since: t0)
            guard current() else { return }
            if onScreen.contains(probe) { readerLog.notice("settle \(round, privacy: .public): on screen at \(read, privacy: .public) ms"); return }
            guard let exact = await page?.progression(of: words) else { readerLog.notice("settle \(round, privacy: .public): words not found at \(Self.ms(since: t0), privacy: .public) ms (read \(read, privacy: .public))"); continue }
            let found = Self.ms(since: t0)
            guard current() else { return }
            _ = await page?.go(to: locator.copy(locations: { $0.progression = exact }, text: { $0 = Locator.Text() }))
            readerLog.notice("settle \(round, privacy: .public): read \(read, privacy: .public), found \(found, privacy: .public), went \(Self.ms(since: t0), privacy: .public) ms")
        }
    }

    /// The reader closed the book: whatever is still settling or landing stops here, so nothing moves
    /// the page or records a place after the close has sent the last one.
    func close() {
        if isWarming, !pageReady { hostController?.halt() }
        isClosed = true
        activation?.resume()
        activation = nil
        moves += 1
        slipTask?.cancel()
        jumpBackTask?.cancel()
        slip = nil
        suggestion = nil
        page?.dropStandby()
        suggestionLocator = nil
        suggestionRemote = nil
        suggestionCloud = nil
    }

    func dismissSuggestion() {
        page?.dropStandby()
        suggestionLocator = nil
        suggestionRemote = nil
        suggestionCloud = nil
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
        // A reflow throws away the page loading behind this one; the catch-up still on offer gets a new one.
        if let waiting = suggestionLocator, !isClosed { page?.prepareStandby(at: waiting) }
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
        // The reader turning on: the other device's line has done its job.
        if !landing, duringTurn || touchedSinceLocation { host?.clearUnderline() }
        refreshAheadTab()
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
        foldSlip()
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

    /// Without the animation: the controls go down before the page is pictured for a reopen.
    func setChromeNow(_ visible: Bool) {
        chromeVisible = visible
    }

    // MARK: Jumps

    func go(toProgression progression: Double, rememberBack: Bool) async {
        hasMoved = true
        moves += 1
        if rememberBack { rememberPlace() }
        if let locator = await publication.locate(progression: progression) {
            await veiled { _ = await self.page?.go(to: locator) }
            await captureAnchor()
            // Behind the cover nothing hides a chapter still loading, so keep the cover up until the
            // words are there.
            for _ in 0..<25 where !pageReady && keeper.anchor?.text == nil && !isClosed {
                try? await Task.sleep(for: .milliseconds(200))
                await captureAnchor()
            }
        }
    }

    func go(to entry: TOCEntry) async {
        hasMoved = true
        moves += 1
        rememberPlace()
        await veiled { await self.page?.go(to: entry.link) }
        await captureAnchor()
    }

    func follow(_ link: ReadiumShared.Link) async {
        hasMoved = true
        moves += 1
        rememberPlace()
        await veiled { await self.page?.go(to: link) }
        await captureAnchor()
    }

    /// A highlight's exact place: Readium finds its words, so the page is the one they are on.
    func go(to locator: Locator, rememberBack: Bool) async {
        hasMoved = true
        moves += 1
        if rememberBack { rememberPlace() }
        await veiled { _ = await self.page?.go(to: locator) }
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
        if LaunchOptions.isUITest, let text = visible?.text { visibleTextProbe = String(text.prefix(2400)) }
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
            Self.epubPreferences(prefs, theme: theme, columns: layout.columns, tabletop: layout.posture == .tabletop, language: Self.hyphenationLanguage(publication)),
            columns: layout.columns == .two ? 2 : 1,
            reflow: reflow
        )
        host?.disablePanningIfNeeded()
    }

    /// Tabletop's half-height page keeps no more than the Normal side margins.
    /// WebKit hyphenates only text that says its language, and many Gutenberg chapters don't: the
    /// book's own language, or English, goes on the page so justified lines break words, not gaps.
    static func hyphenationLanguage(_ publication: Publication) -> Language {
        publication.metadata.language ?? Language(code: .bcp47("en"))
    }

    static func epubPreferences(_ prefs: ReaderPreferences, theme: ReaderTheme, columns: GatefoldCore.ColumnCount, tabletop: Bool = false, language: Language? = nil) -> EPUBPreferences {
        let custom = prefs.font != .original || prefs.lineSpacing != .normal || prefs.justify
        return EPUBPreferences(
            backgroundColor: ReadiumNavigator.Color(hex: ThemePalette.hexString(theme.palette.background)),
            columnCount: columns == .two ? .two : .one,
            fontFamily: prefs.font.cssFamily.map { FontFamily(rawValue: $0) },
            fontSize: prefs.fontScale,
            // Gutenberg justifies its own text; without hyphenation the narrow page opens rivers.
            // ReadiumCSS applies hyphens only in its advanced mode, which on its own changes nothing
            // else (every other user setting stays nil unless chosen).
            hyphens: true,
            language: language,
            lineHeight: custom ? prefs.lineSpacing.lineHeight : nil,
            // Facing pages give their width to the line, not the margins (the spine is margin enough),
            // so each page keeps a book's measure.
            pageMargins: tabletop ? min(prefs.margins.factor, PageMargins.normal.factor)
                : columns == .two ? min(prefs.margins.factor, PageMargins.narrow.factor) : prefs.margins.factor,
            publisherStyles: false,
            scroll: prefs.pageTurn == .scroll,
            textAlign: prefs.justify ? .justify : nil,
            textColor: ReadiumNavigator.Color(hex: ThemePalette.hexString(theme.palette.text)),
            theme: theme.palette.isDark ? .dark : .light
        )
    }
}
