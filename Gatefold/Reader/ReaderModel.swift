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
    /// The reading view's frame in the picture, and whether it was a spread: the leaf a tap lifts.
    var reopenLeaf: CGRect?
    var reopenSpread = false
    var reopenCurl: CurlModel { app.reopenCurl }
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
        } else if hasMoved, moves != recordedMoves, landingMove == nil {
            // (A landing still waiting on a reflow records itself.)
            Task { [weak self] in await self?.keepMoveMadeBehindTheShelf() }
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

    /// A jump made while the book warmed behind the shelf (a test's launch jump reaches every book that
    /// opens) wrote nothing then; at his tap it is his, so the page he sees becomes the place, and a
    /// fresh open shows that page rather than making the jump afresh.
    private func keepMoveMadeBehindTheShelf() async {
        guard !isClosed, moves != recordedMoves, let here = page?.currentLocation else { return }
        readerLog.notice("place: a move made behind the shelf is kept at the tap (reported \(Self.placeTag(here), privacy: .public))")
        layoutOnly = false
        // Under a reflow the report is owed, and the reflow's end records it.
        guard keeper.reflowing == nil else { return await locationDidChange(here) }
        await captureAnchor()
        guard !isClosed, moves != recordedMoves, let now = page?.currentLocation else { return }
        let movesNow = moves
        recordingOwed = true
        await locationDidChange(now)
        recordingOwed = false
        if moves == movesNow, !touchedSinceLocation { layoutOnly = true }
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
    /// The bands above and below the text on the page (the host's own measure of where the words
    /// start and end), for the running heads and page numbers that sit in them.
    var textBand: (top: CGFloat, bottom: CGFloat) = (28, 28)
    /// A tablet page's Apple Books bands and furniture sizes; nil on a phone.
    var tabletBands: TabletPage.Bands?
    /// For UI tests: how the last turn landed: "landed <n> leaf <frames> page <frames> in place|moved".
    var turnPlacement = "none"
    /// For UI tests: how far a spread's outer page ever strayed from its rest, frame by frame, from the
    /// turn's last leg until 0.5 s after it landed: "settle <n> frames <k> worst <pt> pt".
    var turnSettle = "none"

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
    private var moves = 0 { didSet { layoutOnly = false } }
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

    /// Which reader a log line came from: two readers of one book can be alive at once (warm and opened).
    private static var made = 0
    let readerNumber: Int = { ReaderModel.made += 1; return ReaderModel.made }()

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
        readerLog.notice("place read [r\(self.readerNumber, privacy: .public)]: \(book.id, privacy: .public) opening on \(initial.map(Self.placeTag) ?? "none", privacy: .public)")
        // His saved words are the place from the first frame. A reflow can start before the page has
        // shown any words (an iPad relaunched in landscape lays out in portrait first, then rotates);
        // with nothing held, the spread stayed where Readium's re-layout guessed: two spreads early,
        // on the chapter opening before his (the build 15 review's page 98).
        if let anchor = Self.openingAnchor(from: initial) {
            keeper = AnchorKeeper(anchor: anchor)
            anchorLocator = initial
        }
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
                preferences: Self.epubPreferences(prefs, theme: prefs.resolvedTheme(systemIsDark: false), columns: .one, viewWidth: layout.pageFrame.width > 0 ? layout.pageFrame.width : 402, language: Self.hyphenationLanguage(publication))
            )
        } catch {
            errorMessage = FriendlyError.unreadable.message
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

    /// "12 of 340", in the pages he sees; empty until the book is counted at this layout, as Apple Books.
    var pageLabel: String {
        guard let page = screenNumbers?.compactMap({ $0 }).first, let total = screenPages?.total else { return "" }
        return "\(page) of \(total)"
    }
    var pagesLeftLabel: String? {
        guard let (href, geometry) = lastGeometry, let left = screenPages?.pagesLeft(href: href, column: geometry.column - (geometry.verso ? 1 : 0)) else { return nil }
        switch left {
        case 0, 1: return "Last page in chapter"
        default: return "\(left) pages left in chapter"
        }
    }

    // MARK: Screen pages

    /// The numbers on the pages in view, one a page (nil for a blank page); nil until they're known.
    /// They're the pages he sees, as Apple Books numbers them (`ScreenPageMap`), not Readium's positions.
    private(set) var screenNumbers: [Int?]? {
        didSet {
            if screenNumbers != oldValue {
                readerLog.debug("pages: numbers now \(String(describing: self.screenNumbers), privacy: .public)")
            }
            guard !numberShown, screenNumbers?.contains(where: { $0 != nil }) == true else { return }
            numberShown = true
            // A reopen's picture carries the kept number, so a number already up counts as at once.
            firstNumberDelay = pageShownAt.map { Date().timeIntervalSince($0) } ?? 0
            readerLog.notice("pages: first number after \(Date().timeIntervalSince(self.openedAt), privacy: .public) s from open, \(self.pageShownAt.map { Date().timeIntervalSince($0) } ?? -1, privacy: .public) s from the page showing")
        }
    }
    @ObservationIgnored private var numberShown = false
    /// Seconds from the page (or the reopen picture) showing to its first number, for the timing test:
    /// the app's own clock, which a slow accessibility read can't stretch.
    private(set) var firstNumberDelay: TimeInterval?
    /// When the live page took over from the cover or the reopen picture.
    @ObservationIgnored private var pageShownAt: Date?
    private(set) var screenPages: ScreenPageMap?
    /// The page is up in a paged layout and its number isn't known yet (its count not loaded, or
    /// chapters before it still being counted): the number's slot says so quietly instead of staying
    /// blank, which took half a minute on a Duo.
    /// Not after a count that ended with chapters still uncounted, nor after a minute in which nothing
    /// was counted (a count stopped and not restarted, or one that never began): the slot goes quiet
    /// again rather than promising a number that isn't coming. Counting moving again brings it back.
    var countingPages: Bool {
        pageReady && screenNumbers == nil && screenLayout != nil && !countGaveUp && !countStalled
    }
    /// No chapter counted, and no count begun, for a minute.
    private(set) var countStalled = false
    @ObservationIgnored private var stallTimer: Task<Void, Never>?
    private func countMoved() {
        countStalled = false
        stallTimer?.cancel()
        stallTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled, let self else { return }
            self.countStalled = true
            if self.screenNumbers == nil, self.screenLayout != nil {
                readerLog.error("pages: nothing counted for a minute and no number yet; the slot goes quiet")
            }
        }
    }
    /// UI tests: "Counting pages…" was drawn at least once (CI's slow reads can miss it on screen).
    var countingShownProbe = false
    /// The last count ended by itself with chapters it couldn't count; cleared when a count starts.
    private(set) var countGaveUp = false
    private var lastGeometry: (href: String, geometry: ScreenPageGeometry)?
    private static let pageStore: ScreenPageStore = {
        let directory = URL.cachesDirectory.appending(path: "ScreenPages", directoryHint: .isDirectory)
        // A clean start (`-GatefoldReset`) counts every book again.
        if LaunchOptions.resetState { try? FileManager.default.removeItem(at: directory) }
        return ScreenPageStore(directory: directory)
    }()

    /// What the book's pages are cut by now; nil in scroll, which has no pages.
    var screenLayout: ScreenPageLayout? {
        let prefs = preferences
        guard prefs.pageTurn != .scroll, !readingOrderHrefs.isEmpty else { return nil }
        let epub = Self.epubPreferences(prefs, theme: theme, columns: layout.columns, viewWidth: layout.pageFrame.width, tabletop: layout.posture == .tabletop)
        return ScreenPageLayout(width: layout.pageFrame.width, height: layout.pageFrame.height,
                                columnsPerScreen: layout.columns == .two ? 2 : 1, fontScale: prefs.fontScale,
                                lineHeight: epub.lineHeight ?? 0, margins: epub.pageMargins ?? 1,
                                font: prefs.font.rawValue, justify: prefs.justify)
    }

    /// The page a place in the book falls on, once its chapter and those before it are counted.
    func screenPage(atTotal total: Double) -> Int? {
        guard let map = screenPages, let index = resourceStarts.lastIndex(where: { $0 <= total }), index < readingOrderHrefs.count else { return nil }
        let start = resourceStarts[index]
        let end = index + 1 < resourceStarts.count ? resourceStarts[index + 1] : 1
        return map.number(href: readingOrderHrefs[index], progression: end > start ? (total - start) / (end - start) : 0)
    }

    /// Pages from one place to another: screen pages once counted, Readium's positions until then.
    func pagesBetween(_ from: Double, _ to: Double) -> Int? {
        if let a = (from == totalProgression ? screenNumbers?.compactMap({ $0 }).first : nil) ?? screenPage(atTotal: from), let b = screenPage(atTotal: to) { return b - a }
        guard chapterMap.positionCount > 1 else { return nil }
        return chapterMap.page(at: to) - chapterMap.page(at: from)
    }

    /// Numbers the screen in view. A new layout (size, spread, type) starts from its own kept counts,
    /// or none, and counts the rest behind the page; `recount` restarts that after a reflow stopped it.
    func refreshScreenNumbers(recount: Bool = false) async {
        guard !isClosed, let key = screenLayout else {
            if screenPages != nil { page?.stopCounting() }
            screenPages = nil; screenNumbers = nil; lastGeometry = nil
            return
        }
        if screenPages?.layout != key {
            screenPages = Self.pageStore.load(book: bookID, layout: key, readingOrder: readingOrderHrefs)
            screenNumbers = nil
            lastGeometry = nil
            // A new layout's count owes nothing to the last one's.
            countGaveUp = false
            countMoved()
            startCounting()
        } else if recount {
            startCounting()
        }
        // Mid-reflow the web view is between layouts; the reflow's end numbers the page.
        guard keeper.reflowing == nil, let (href, geometry) = await page?.screenGeometry(), screenLayout == key, screenPages?.layout == key else { return }
        // The chapter in view counts too, once two looks agree (a web view still laying out reads short).
        if screenPages?.pages(of: href) == nil, geometry.isClean {
            try? await Task.sleep(for: .milliseconds(200))
            if let (again, second) = await page?.screenGeometry(), again == href, second.columns == geometry.columns,
               keeper.reflowing == nil, screenPages?.layout == key {
                screenPages?.record(href: href, geometry: second)
                if let map = screenPages { Self.pageStore.save(map) }
            }
        }
        guard screenPages?.layout == key else { return }
        lastGeometry = (href, geometry)
        screenNumbers = screenPages?.screen(href: href, geometry: geometry)
        if screenNumbers == nil {
            readerLog.debug("pages: no number yet for \(href, privacy: .public): \(self.screenPages?.uncounted.count ?? -1, privacy: .public) uncounted, clean \(geometry.isClean, privacy: .public), this chapter \(self.screenPages?.pages(of: href).map(String.init) ?? "nil", privacy: .public)")
        }
    }

    private func startCounting() {
        // Never during a reflow: a second web view loading then holds up the reflow's own look at the
        // page and loses his place (a posture change on the Duo). The reflow's end starts it.
        guard pageReady, reopenPicture == nil, keeper.reflowing == nil,
              let map = screenPages, !map.uncounted.isEmpty else { return }
        let key = map.layout
        countGaveUp = false
        countMoved()
        page?.countPages(map.uncounted, record: { [weak self] href, columns in
            guard let self, self.screenPages?.layout == key else { return }
            self.countMoved()
            // The page is the truth: a chapter it already counted itself (his own, as it showed) keeps its
            // count, whichever chapter he's in by the time the counter's figure arrives.
            if let kept = self.screenPages?.columns[href] {
                if kept != columns {
                    readerLog.error("pages: counter disagrees with the page on \(href, privacy: .public): \(columns, privacy: .public) against \(kept, privacy: .public); the page's kept")
                }
                return
            }
            self.screenPages?.record(href: href, columns: columns)
            if let map = self.screenPages { Self.pageStore.save(map) }
            if let (here, geometry) = self.lastGeometry {
                self.screenNumbers = self.screenPages?.screen(href: here, geometry: geometry)
            } else {
                // No look at the page has landed yet (a reopen's picture swapping out, a reflow ending as
                // the count began): take one, or a finished count never shows its number.
                Task { await self.refreshScreenNumbers() }
            }
        }, finished: { [weak self] in
            guard let self, self.screenPages?.layout == key else { return }
            self.countGaveUp = self.screenPages?.uncounted.isEmpty == false
            if self.countGaveUp {
                readerLog.error("pages: count ended with \(self.screenPages?.uncounted.count ?? 0, privacy: .public) chapters uncounted; no number this time")
            }
        })
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
        Task { await refreshScreenNumbers() }
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
            // Checked often, and a page Readium would hold back after it has scrolled into place is
            // shown as soon as it has painted (`unveilPlacedPages`).
            for _ in 0..<320 where host?.isLoadingPage == true {
                await host?.unveilPlacedPages()
                guard host?.isLoadingPage == true else { break }
                try? await Task.sleep(for: .milliseconds(25))
            }
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
    @discardableResult
    func queueReopenTurn(forward: Bool) -> Bool { app.queueReopenTurn(forward: forward) }

    /// The picture was made for this launch from one in another paper or window: never pixel for
    /// pixel the live page, so it fades.
    var reopenAdapted = false

    private func showPage() {
        withAnimation(.easeOut(duration: 0.3)) { pageReady = true }
        if reopenPicture == nil { pageShownAt = Date() }
        // Counting the book's pages waits until the open has settled (the reopen picture gone too), so
        // it never slows the first page.
        Task {
            for _ in 0..<120 where reopenPicture != nil { try? await Task.sleep(for: .milliseconds(250)) }
            try? await Task.sleep(for: .milliseconds(400))
            await refreshScreenNumbers(recount: true)
        }
        guard reopenPicture != nil else { return }
        Task {
            // Long enough for the page's first paint to be the one that stays (two equal pictures of
            // it in a row); 400 ms here only made the picture stand longer.
            try? await Task.sleep(for: .milliseconds(100))
            await host?.waitForSettledPage()
            // A reflow under way still moves the page (an iPad relaunched in landscape lays out in
            // portrait first, then rotates): the picture stays until it has placed his words. Build 15
            // lifted it seconds before, onto an empty spread with grey where the right page would be.
            let reflowBudget = Date().addingTimeInterval(12)
            if keeper.reflowing != nil {
                while keeper.reflowing != nil, Date() < reflowBudget, !isClosed { try? await Task.sleep(for: .milliseconds(100)) }
                await host?.waitForSettledPage()
            }
            let same = !reopenAdapted && (reopenPageFrame.map { abs($0.minY - layout.pageFrame.minY) < 1 && abs($0.height - layout.pageFrame.height) < 1 && abs($0.width - layout.pageFrame.width) < 1 } ?? true)
            // A turn asked of the picture: its lifted leaf lands on the live page beneath, then the
            // picture goes. Without a lifted leaf (no leaf to lift), the turn plays on the live page.
            let queued = app.reopenQueuedTurn
            app.reopenQueuedTurn = nil
            var landed: Bool?
            if let forward = queued, app.reopenCurl.isActive, let host {
                landed = await host.landLiftedTurn(forward: forward, curl: app.reopenCurl)
                readerLog.notice("reopen: landed the lifted \(forward ? "forward" : "back", privacy: .public) turn at \(LaunchClock.sinceLaunch, privacy: .public) s after launch (moved \(landed ?? false, privacy: .public))")
            }
            if same || landed == true {
                reopenPicture = nil
            } else {
                reopenFades = true
                withAnimation(.easeInOut(duration: 0.3)) { reopenPicture = nil }
            }
            app.reopenCurl.reset()
            if landed == true { userTurnedPage() }
            if let forward = queued, landed == nil {
                readerLog.notice("reopen: played the kept \(forward ? "forward" : "back", privacy: .public) turn at \(LaunchClock.sinceLaunch, privacy: .public) s after launch")
                host?.turn(forward: forward)
            }
            pageShownAt = Date()
            if LaunchOptions.isUITest { refreshBookmarkState(await page?.visibleRange()) }
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
        let pages = pagesBetween(totalProgression, target.totalProgression)
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

    /// Up to `limit` places where `query` occurs, in reading order, each with a little text around it.
    func search(_ query: String, limit: Int) async -> [Locator] {
        nonisolated(unsafe) let publication = publication
        guard case let .success(iterator) = await publication.search(query: query) else {
            readerLog.notice("search: this book can't be searched")
            return []
        }
        nonisolated(unsafe) let pages = iterator
        var found: [Locator] = []
        while found.count < limit, !Task.isCancelled, case let .success(collection?) = await pages.next() {
            found += collection.locators
        }
        pages.close()
        return Array(found.prefix(limit))
    }

    /// The folded tab counts down as the reader catches up, and goes once they're there.
    private func refreshAheadTab() {
        guard let aim = aheadTarget, slipKind == .ahead, slip != nil, let pages = pagesBetween(totalProgression, aim.progression) else { return }
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
            // A place the Cloud holds only as a percent. The page this lands on is his place from now:
            // kept nothing, every reopen landed on the percent afresh and the spread could fall on the
            // page beside the one he left (build 20's reopen loop, 3 in 19). The landing's own steps are
            // not places (as below): `go` counts this move first thing.
            let move = moves + 1
            landingMove = move
            await go(toProgression: progression, rememberBack: rememberBack)
            guard moves == move, !isClosed else {
                if landingMove == move { landingMove = nil }
                return
            }
            guard keeper.reflowing != nil else {
                await keepPercentLanding(move: move, target: target, cloud: cloud)
                return
            }
            // A reflow under way (a warm open laid out upright, then turned) moves the page: keep the
            // words it settles on, not the boundary before it. Waited for apart from the landing, so the
            // cover never stays up for the reflow (on a slow runner that held a blank page past 20 s).
            Task { [weak self] in
                for _ in 0..<80 {
                    guard let self, self.keeper.reflowing != nil, self.moves == move, !self.isClosed else { break }
                    try? await Task.sleep(for: .milliseconds(250))
                }
                await self?.keepPercentLanding(move: move, target: target, cloud: cloud)
            }
            return
        }
        hasMoved = true
        let back = rememberBack ? rememberPlace() : nil
        defer { publishBack(back) }
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

    /// Keeps the page a percent landing settled on, unless he has moved since.
    private func keepPercentLanding(move: Int, target: ReadingPosition?, cloud: Double?) async {
        defer { if landingMove == move { landingMove = nil } }
        guard moves == move, !isClosed else { return }
        await captureAnchor()
        guard moves == move, !isClosed, let here = page?.currentLocation else { return }
        await recordLanding(here, target: target, cloud: cloud)
    }

    /// A place in the log without its words: the file, the progression in it and in the book.
    nonisolated static func placeTag(_ l: Locator) -> String {
        let file = l.href.string.split(separator: "/").last.map(String.init) ?? l.href.string
        return String(format: "%@ @%.5f total %.5f", file, l.locations.progression ?? -1, l.locations.totalProgression ?? -1)
    }

    /// Records a settled landing. The first words on screen are the place, unless they come before the
    /// place we landed on (the page starts a few lines above it): then the target itself is, so the
    /// other device's place comes back unchanged instead of a few lines behind.
    private func recordLanding(_ here: Locator, target: ReadingPosition?, cloud: Double? = nil, retake: Bool = true) async {
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
        // The landed page is the place now: until he turns, jumps or touches, a later report is the
        // layout settling (build 20's loop rewrote it to the chapter's first page and reopened beside him).
        layoutOnly = true
        let record: @MainActor (Date) -> Void = { [weak self] at in
            guard let self else { return }
            // The Cloud's percent for this place stands; reading on adds to it (`CloudScale`).
            if let cloud, let landedAt {
                self.app.library.landedOnCloudPlace(bookID: self.bookID, cloud: cloud, landed: landedAt)
                readerLog.notice("landed: the Cloud says \(cloud, privacy: .public), Readium \(landedAt, privacy: .public)")
            }
            if let json {
                self.recordedMoves = self.moves
                readerLog.notice("place write [r\(self.readerNumber, privacy: .public)]: landing (\(fresh != nil ? "his first words" : "Readium's boundary", privacy: .public)) \(Self.placeTag(settledLocator), privacy: .public); kept total \(chosen?.totalProgression ?? here.locations.totalProgression ?? 0, privacy: .public); move \(self.moves, privacy: .public)")
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
        if fresh == nil, retake {
            // His first words weren't captured on this page (a reflow that wouldn't settle cut the
            // capture short): Readium's boundary reopens a page beside the one he sees. Keep it only for
            // now, and once the layout is still, take his first words and keep those instead.
            let move = moves
            if isWarming {
                pendingRecord = { [weak self] _ in
                    Task { [weak self] in await self?.retakeLanding(move: move, target: target, cloud: cloud, orKeep: record) }
                }
            } else {
                record(now)
                Task { [weak self] in await self?.retakeLanding(move: move, target: target, cloud: cloud, orKeep: nil) }
            }
        } else if isWarming {
            pendingRecord = record
        } else {
            record(now)
        }
        openedLocation = here
        refreshBookmarkState(await page?.visibleRange())
    }

    /// A landing kept on Readium's boundary is provisional: when no reflow is moving the page, take his
    /// first words and keep them as the landing, unless he has moved since. `orKeep` (behind the shelf)
    /// is the boundary's record, kept at the tap if his words can't be had.
    private func retakeLanding(move: Int, target: ReadingPosition?, cloud: Double?, orKeep: (@MainActor (Date) -> Void)?) async {
        var captures = 0
        for _ in 0..<120 where !isClosed && moves == move && captures < 8 {
            if keeper.reflowing == nil {
                captures += 1
                await captureAnchor()
                guard !isClosed, moves == move else { return }
                if keeper.reflowing == nil, let now = page?.currentLocation, let a = anchorLocator,
                   a.href == now.href, a.locations.progression == now.locations.progression {
                    readerLog.notice("place: the landing's first words taken once the layout was still (try \(captures, privacy: .public))")
                    return await recordLanding(now, target: target, cloud: cloud, retake: false)
                }
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        if !isClosed, moves == move, let orKeep {
            readerLog.notice("place: no first words for the landing; keeping Readium's boundary")
            orKeep(Date())
        }
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
        stallTimer?.cancel()
        activation?.resume()
        activation = nil
        moves += 1
        slipTask?.cancel()
        jumpBackTask?.cancel()
        slip = nil
        suggestion = nil
        page?.dropStandby()
        page?.stopCounting()
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
            // The restore's verdict, numbers only (no book text), so a real unfold can be judged from the log.
            readerLog.notice("reflow check: \(self.anchorCheck, privacy: .public) columns \(self.layout.columns == .two ? 2 : 1, privacy: .public) anchor \(anchor.progression, privacy: .public) visible \(visible.start, privacy: .public)..\(visible.end, privacy: .public) same file \(visible.href == anchor.href, privacy: .public)")
        } else {
            anchorCheck = "no-anchor \(reflowCount)"
        }
        refreshBookmarkState(visible)
        Task { await refreshScreenNumbers(recount: true) }
        // The page now showing names its own chapter in the running head (a spread opened onto a
        // place is laid out by the reflow, after the first look at the words).
        Task { _ = await page?.currentAnchor() }
        if !placeOwed { layoutOnly = true }
        if placeOwed {
            Task { [weak self] in
                guard let self, self.placeOwed, !self.isClosed, !self.isWarming, self.keeper.reflowing == nil else { return }
                // The keeper ignored the move while the reflow ran, so its words are the page before it:
                // take them from the page he is on now.
                await self.captureAnchor()
                // A turn that landed meanwhile recorded its own page and paid the debt.
                guard self.placeOwed, !self.isClosed, self.keeper.reflowing == nil,
                      let here = self.page?.currentLocation else { return }
                let movesNow = self.moves
                readerLog.notice("place: recorded the move a reflow held, at \(here.locations.totalProgression ?? -1, privacy: .public) moves \(self.moves, privacy: .public) recorded \(self.recordedMoves, privacy: .public)")
                self.recordingOwed = true
                await self.locationDidChange(here)
                self.recordingOwed = false
                // Kept: later reports with no move of his are the layout again.
                if self.moves == movesNow, !self.touchedSinceLocation { self.layoutOnly = true }
            }
        }
    }
    /// A move arrived while a reflow was under way; the reflow's end records it.
    @ObservationIgnored private var placeOwed = false
    /// `moves` when the place was last recorded: a reflow only owes a move not yet kept, so an
    /// ordinary rotation never swaps his exact words for Readium's page boundary.
    @ObservationIgnored private var recordedMoves = -1
    /// Set when a reflow ends (or an owed place is kept) and cleared by a move of his, or a report his
    /// touch brought: while
    /// it's up, a location report is the layout (a rotation, an unfold, a late report from the new
    /// spread), never a reason to rewrite the place. It stays down until the next reflow, not just the
    /// next report, so a long scroll's later reports still count.
    @ObservationIgnored private var layoutOnly = false
    /// The owed place is being recorded: its words were just taken.
    @ObservationIgnored private var recordingOwed = false

    /// The saved place as an anchor, when it carries the words that opened his page.
    static func openingAnchor(from locator: Locator?) -> ReadingAnchor? {
        guard let locator, let words = locator.text.highlight.map(ReaderJS.normalize), !words.isEmpty else { return nil }
        return ReadingAnchor(href: locator.href.string, progression: locator.locations.progression ?? 0, text: words)
    }

    func locator(for anchor: ReadingAnchor) -> Locator? {
        anchorLocator
    }

    // MARK: Navigation events

    func locationDidChange(_ locator: Locator, duringTurn: Bool = false, hisMove: Bool = false) async {
        guard !isClosed else { return }
        location = locator
        // The reader turning on: the other device's line has done its job.
        if !landing, duringTurn || touchedSinceLocation { host?.clearUnderline() }
        refreshAheadTab()
        // The navigator opens on the saved place, so its first report is a page worth showing: don't
        // keep the cover up while the rest of the book is indexed.
        if !pageReady, LaunchOptions.goTo == nil { markReady() }
        Task { await refreshScreenNumbers() }
        if !duringTurn, hasMoved, isPastStory(locator) { reachedEnd() }
        // A landing records its place once it has settled; the steps on the way are not places.
        guard !landing else { return }
        // Mid-turn the navigator has moved under the overlay; the turn records the place when it lands.
        // A move reported mid-reflow (a turn or a jump while an iPad's first layout is still settling)
        // is owed: the reflow's end records it, or the place he went to is never kept (build 17 reopened
        // a book jumped to during that reflow at its start, then landed on the Cloud's older place).
        // A reader warmed behind the shelf has no place of his to owe.
        if keeper.reflowing != nil, hasMoved, moves != recordedMoves, !duringTurn, !isWarming {
            if !placeOwed { readerLog.notice("place: owed by a reflow, at \(locator.locations.totalProgression ?? -1, privacy: .public) moves \(self.moves, privacy: .public) recorded \(self.recordedMoves, privacy: .public)") }
            placeOwed = true
        }
        guard keeper.reflowing == nil, !duringTurn else { return }
        placeOwed = false
        // Only he moves the place: a turn, a jump or a touch since the last report. A report after a
        // reflow, with none of them since, is the layout (a rotation, an unfold, a late report from the new spread), and it never
        // re-anchors or rewrites the saved place: a spread that slips a verso before his page starts a
        // page early, and saving its start reopened him a page early (build 17's rotation miss).
        // One move, one place: once a move is kept, a further report with no turn, jump or touch since
        // is the layout's too (build 20's real unfold: the web view finishing its load had Readium name
        // the chapter's first page after a kept jump, and saving it lost his words on the next unfold).
        let alreadyKept = moves == recordedMoves && !hisMove
        let touchedAtReport = touchedSinceLocation
        let readerMoved = (!layoutOnly && !alreadyKept) || touchedAtReport
        // A touch that brought a report is his gesture (a slide or a scroll, which Readium owns and
        // `moves` never sees): the rest of its reports are his too. A tap that only shows the controls
        // brings none, so it never opens the place to a late report from the layout.
        if touchedSinceLocation { layoutOnly = false }
        // A location that arrives as a reflow lands is the restore, not the reader moving: keep the
        // anchor, or repeated reflows would walk it backward a page at a time.
        if recordingOwed {
            readerLog.notice("location of a move a reflow held; anchor just taken (reported \(Self.placeTag(locator), privacy: .public))")
        } else if let settled = reflowSettledAt, Date().timeIntervalSince(settled) < 1.2 {
            readerLog.notice("location after reflow; anchor kept (reported \(Self.placeTag(locator), privacy: .public))")
        } else if !readerMoved, keeper.anchor != nil {
            readerLog.notice("location without a move; anchor and place kept (reported \(Self.placeTag(locator), privacy: .public))")
        } else {
            let held = keeper.anchor, heldLocator = anchorLocator
            await captureAnchor()
            // No turn, no jump and no swipe since the last report, and his words are still the first on
            // screen: the layout moved Readium's page boundary (page numbers coming on, a number taking
            // the "Counting pages…" slot), not the reader. His page, its words and its place stay.
            if !hisMove, !touchedSinceLocation, moves == movesAtLastReport, let held, held.text != nil,
               keeper.anchor?.text == held.text {
                keeper.userSettled(on: held)
                anchorLocator = heldLocator
                layoutReport = true
                readerLog.notice("location from the layout; his words still on screen, anchor and place kept")
            }
            if touchedSinceLocation, !hasMoved {
                if let opened = openedLocation {
                    if opened.href != locator.href || opened.locations.progression != locator.locations.progression { hasMoved = true }
                } else {
                    openedLocation = locator
                }
            }
            if openedLocation == nil { openedLocation = locator }
        }
        touchesSinceLocation = 0
        movesAtLastReport = moves
        // A report that isn't his move leaves "where he is" on his words: the running head, the
        // Cloud's "here" and the scrubber read `location`, so it names the page on screen, not
        // Readium's boundary (build 19: the head said the next chapter while his words stayed put).
        let justReflowed = !recordingOwed && reflowSettledAt.map { Date().timeIntervalSince($0) < 1.2 } == true
        let notHisMove = layoutReport || !readerMoved || justReflowed
        if notHisMove, let words = anchorLocator, keeper.anchor?.text != nil { location = words }
        let fromLayout = layoutReport
        layoutReport = false
        // Only the reader moves the place. Readium reopening a page boundary off from the saved one is
        // not a move, so opening a book never overwrites a further-ahead place on the InkPad.
        // A book warmed behind the shelf has had no move of his yet: nothing it reports is his place.
        // Asked again here, after the waits above: a second report that arrived while this one captured
        // its words found the move not yet kept, and both wrote (build 20's loop saved two places for one
        // jump, 0.3 s apart, from one reader).
        let keptMeanwhile = moves == recordedMoves && !hisMove && !touchedAtReport
        guard hasMoved, readerMoved, !keptMeanwhile, !fromLayout, !isWarming else { return refreshBookmarkState(await page?.visibleRange()) }
        // Kept as of now, before any further wait.
        recordedMoves = moves
        // The first words on screen make the place exact; Readium's progression is a page boundary.
        // Only words captured on this very page count; a capture a reflow cut short leaves the last page's.
        let fresh = anchorLocator.flatMap { a in
            a.href == locator.href && a.locations.progression == locator.locations.progression ? a : nil
        }
        let here = fresh ?? locator
        if let json = try? here.jsonString() {
            let now = Date()
            let exact = await mapper?.position(for: BookLocation(here), at: now)
            readerLog.notice("place write [r\(self.readerNumber, privacy: .public)]: his move (\(fresh != nil ? "his first words" : "Readium's boundary", privacy: .public)) \(Self.placeTag(here), privacy: .public); reported \(Self.placeTag(locator), privacy: .public); move \(self.moves, privacy: .public), touched \(self.touchedSinceLocation, privacy: .public), layoutOnly \(self.layoutOnly, privacy: .public)")
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
    func noteInteraction() { touchesSinceLocation += 1 }
    /// Touches on the page since the last location report; a tap that only shows or hides the controls
    /// clears them.
    @ObservationIgnored private var touchesSinceLocation = 0
    private var touchedSinceLocation: Bool { touchesSinceLocation > 0 }
    /// `moves` at the last location report: a report with none since is no turn or jump of his.
    @ObservationIgnored private var movesAtLastReport = 0
    /// This report came from the layout (see `locationDidChange`).
    @ObservationIgnored private var layoutReport = false
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
                // His turn's own report, corrected: never taken for the layout's (same words, no move since).
                await locationDidChange(later, hisMove: true)
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

    /// A tap on the page that showed or hid the controls, and did nothing else.
    /// The touch that began it is not a swipe, so the next location report (the layout settling under
    /// the controls, page numbers coming on) is not his move.
    func controlsTapped(visible: Bool) {
        // Every touch since the last report, not only this tap's: a counter that took off one touch per
        // tap kept a tap Readium never passed on (one whose touch began but whose tap went nowhere) as
        // a move of his, and the next layout report moved his place (2 in 20 reopens). A swipe that a
        // tap follows before Readium reports it is the rarer case and is left to that report.
        touchesSinceLocation = 0
        setChrome(visible)
    }

    /// Without the animation: the controls go down before the page is pictured for a reopen.
    func setChromeNow(_ visible: Bool) {
        chromeVisible = visible
    }

    // MARK: Jumps

    func go(toProgression progression: Double, rememberBack: Bool) async {
        hasMoved = true
        moves += 1
        let back = rememberBack ? rememberPlace() : nil
        defer { publishBack(back) }
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
        let back = rememberPlace()
        defer { publishBack(back) }
        await veiled { await self.page?.go(to: entry.link) }
        await captureAnchor()
    }

    func follow(_ link: ReadiumShared.Link) async {
        hasMoved = true
        moves += 1
        let back = rememberPlace()
        defer { publishBack(back) }
        await veiled { await self.page?.go(to: link) }
        await captureAnchor()
    }

    /// A highlight's exact place: Readium finds its words, so the page is the one they are on.
    func go(to locator: Locator, rememberBack: Bool) async {
        hasMoved = true
        moves += 1
        let back = rememberBack ? rememberPlace() : nil
        defer { publishBack(back) }
        await veiled { _ = await self.page?.go(to: locator) }
        await captureAnchor()
    }

    func go(to bookmark: Bookmark) async {
        let back = rememberPlace()
        defer { publishBack(back) }
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

    /// The place a jump leaves, held until the jump has moved the page: "Back to page" offered while
    /// the old page was still up (3.6 to 8.8 s on a cold Contents jump in build 19) read as a jump that
    /// had already happened. An earlier jump's way back goes down meanwhile; it isn't this jump's.
    private func rememberPlace() -> Int {
        backJumps += 1
        pendingBack = (backJumps, location, chapterMap.page(at: totalProgression))
        backLocator = nil
        backPage = nil
        return backJumps
    }
    @ObservationIgnored private var backJumps = 0
    @ObservationIgnored private var pendingBack: (jump: Int, locator: Locator?, page: Int?)?

    /// Offers the way back once its jump has landed (a veiled jump returns once the new page has
    /// painted), and only for the newest jump: one overtaken by another offers nothing.
    private func publishBack(_ jump: Int?) {
        guard let jump, let pending = pendingBack, pending.jump == jump else { return }
        pendingBack = nil
        backLocator = pending.locator
        backPage = pending.page
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

    /// For UI tests: the words on screen, as of the last settled page. While the reopen picture covers
    /// the page the screen shows the picture, not the web view laying out under it, so nothing is
    /// reported until the live page takes its place (CI's reviewer check hashed the page under a
    /// picture that stayed up 24 s on a slow runner, and called a correct reopen a miss).
    private(set) var visibleTextProbe = ""

    private func refreshBookmarkState(_ visible: VisibleRange?) {
        if LaunchOptions.isUITest, reopenPicture == nil, let text = visible?.text { visibleTextProbe = String(text.prefix(2400)) }
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
        // Page furniture is drawn over the page, not in it: the web view never hears of it.
        var bare = after
        bare.showsPageNumbers = before.showsPageNumbers
        bare.showsPositionLabel = before.showsPositionLabel
        bare.showsPagesLeft = before.showsPagesLeft
        guard bare != before else { return }
        applyPreferences(reflow: reflows)
    }

    func useAsDefault() {
        app.preferences.useAsDefault(from: bookID)
    }

    func applyPreferences(reflow: Bool) {
        let prefs = preferences
        host?.apply(
            Self.epubPreferences(prefs, theme: theme, columns: layout.columns, viewWidth: layout.pageFrame.width, tabletop: layout.posture == .tabletop, language: Self.hyphenationLanguage(publication)),
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

    static func epubPreferences(_ prefs: ReaderPreferences, theme: ReaderTheme, columns: GatefoldCore.ColumnCount, viewWidth: CGFloat, tabletop: Bool = false, language: Language? = nil) -> EPUBPreferences {
        let custom = prefs.font != .original || prefs.lineSpacing != .normal || prefs.justify
        // Each choice keeps a share of the page's width (Classic Apple Books' measure on an iPad page),
        // a spread's pages included; tabletop's half-height page keeps no more than Classic.
        let choice: PageMargins = tabletop && prefs.margins == .wide ? .normal : prefs.margins
        let view = Double(viewWidth)
        let page: Double = columns == .two ? view / 2 : view
        let margins: Double = choice.readiumFactor(pageWidth: page, viewWidth: view)
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
            pageMargins: margins,
            publisherStyles: false,
            scroll: prefs.pageTurn == .scroll,
            textAlign: prefs.justify ? .justify : nil,
            textColor: ReadiumNavigator.Color(hex: ThemePalette.hexString(theme.palette.text)),
            theme: theme.palette.isDark ? .dark : .light
        )
    }
}
