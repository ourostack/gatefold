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
    /// After any jump that is not a turn, the way back stays on screen with the controls hidden, until
    /// he has read on `JumpBack.turnsToKeep` turns or taken it.
    private(set) var showJumpBack = false
    /// Turns since the way back came up.
    @ObservationIgnored private var turnsSinceJump = 0
    @ObservationIgnored private var slipTask: Task<Void, Never>?
    /// The end leaf, once the reader turns past the story's last page.
    private(set) var endLeaf: EndLeaf?
    /// The book's cover, shown while the first page lays out and on the end leaf.
    let cover: UIImage?
    /// The InkPad's highlights and notes, and the reader's own (Highlights.swift).
    let highlights: HighlightStore
    /// The first page is on screen and legible.
    private(set) var pageReady = false
    /// The opening cover has finished fading off the first page: until then the controls sit above it (#104).
    private(set) var coverLifted = false
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
        hostController?.becameTheOpenBook()
        if pageReady { readerLog.notice("first page ready after 0 s (opened ahead of the tap)") }
        activation?.resume()
        activation = nil
        foldOnceSeen()
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
    /// A test's launch jump is still on its way to its page.
    @ObservationIgnored private var launchJumpInFlight = false { didSet { if !launchJumpInFlight { launchJumpDone() } } }
    @ObservationIgnored private var launchJumpWaiters: [CheckedContinuation<Void, Never>] = []
    /// Returns once a launch jump on its way has landed or given up (or the reader closed): an event,
    /// not a count of beats, so a starved host's slow reads can't outlast the wait.
    private func waitForLaunchJump() async {
        guard launchJumpInFlight, !isClosed else { return }
        await withCheckedContinuation { launchJumpWaiters.append($0) }
    }
    private func launchJumpDone() {
        let waiting = launchJumpWaiters
        launchJumpWaiters = []
        waiting.forEach { $0.resume() }
    }

    private func keepMoveMadeBehindTheShelf() async {
        // A jump still on its way is kept where it lands, not where it passes through.
        // Twice the landing's reads in beats: a read also asks the web view for its page, so it runs longer than a beat.
        await waitForLaunchJump()
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
    /// UI tests: "<turn> <looks>": the newest turn, and how many looks it waited for the page beneath to paint.
    var turnWaitProbe = ""
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
    /// A landing made behind the shelf says so once the reader is looking.
    private var pendingLanded: (slip: SyncSlip, underline: Locator?)?
    /// Where the book opened; nothing is recorded or pushed until the reader moves from it,
    /// so opening a book never overwrites a further-ahead place on the other device.
    private var hasMoved = false
    /// The saved place, with the first words that were on screen.
    private let initialLocator: Locator?
    /// `-GatefoldGoTo`, if it applies to this open (see `init`).
    private let launchGoTo: Double?
    /// The wait between a launch jump's reads of the page; tests pass a yield (counted in reads, either way).
    private let jumpBeat: () async -> Void
    /// Counts every move of the page (a turn, a jump, a landing, the close). A settle or a landing
    /// that started before the latest move has been overtaken and must not move or record anything.
    /// Every move of his counts a step too (see `steps`).
    private var moves = 0 { didSet { layoutOnly = false; if moves > oldValue { steps += 1 } } }
    /// His own moves only (his turns, the jumps and links he chose, the offer he took): never the app's (a
    /// launch jump, a Cloud landing, the close). A restore gives way once this has changed since its reflow
    /// began; a restore's own moves go straight to the navigator and are not counted at all.
    @ObservationIgnored private(set) var hisMoves = 0
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

    /// `goTo`: tests name the launch jump here rather than through the shared `-GatefoldGoTo` default,
    /// which another suite's reader running alongside would pick up too. `jumpBeat`: the wait between
    /// the jump's reads of the page.
    init(book: LibraryBook, publication: Publication, app: AppModel, page: (any ReaderPage)? = nil, goTo: Double? = nil,
         jumpBeat: (() async -> Void)? = nil) {
        self.jumpBeat = jumpBeat ?? { try? await Task.sleep(for: .milliseconds(200)) }
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
        self.highlights = HighlightStore(bookID: book.id, cloudBook: book.cloud, sync: app.sync)
        let initial = book.locatorJSON.flatMap { try? Locator(jsonString: $0) }
        self.initialLocator = initial
        // From the first moment: Readium reports its first page while load() is still reading the
        // book, before the settle has begun, and that report must not reveal the page either.
        self.openSettling = initial != nil
        // A test's launch jump sets up the book it opens, once: a book he already has a place in (or
        // another book opened in the same launch) opens on its own place. Jumping every open re-made
        // the jump on a return and called the page it reached his (CI's page-numbers check).
        self.launchGoTo = initial == nil && (LaunchOptions.openBook == nil || LaunchOptions.openBook == book.id) ? (goTo ?? LaunchOptions.goTo) : nil
        readerLog.notice("place read [r\(self.readerNumber, privacy: .public)]: \(book.id, privacy: .public) opening on \(initial.map(Self.placeTag) ?? "none", privacy: .public)")
        // UI tests: the place read carries his words or not (a reopen of a bare progression lands on a boundary).
        if LaunchOptions.isUITest { self.savedWordsProbe = initial?.text.highlight.map(ReaderJS.normalize) ?? "" }
        // His saved words are the place from the first frame. A reflow can start before the page has
        // shown any words (an iPad relaunched in landscape lays out in portrait first, then rotates);
        // with nothing held, the spread stayed where Readium's re-layout guessed: two spreads early,
        // on the chapter opening before his (the build 15 review's page 98).
        if let anchor = Self.openingAnchor(from: initial) {
            keeper = AnchorKeeper(anchor: anchor)
            anchorLocator = initial
        } else if let initial {
            // A place with no words holds no anchor: a restore whose page stalled on the chapter's start
            // left him there (gatefold#250). Kept to put him back once, while the open's restore is pending.
            openedOnBarePlace = initial
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
                initialLocation: LaunchOptions.reopenOnChapterStart && Self.openingAnchor(from: initial) == nil
                    ? initial?.copy(locations: { $0 = Locator.Locations(progression: 0) }) : initial,
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
    /// A count held back (the page not up, the reopen picture, a reflow, Your Page) isn't stalled: the
    /// minute starts once it can run (gatefold#262).
    var countingPages: Bool { screenNumbers == nil && awaitingNumber }
    /// The page is up in a paged layout and its number is still coming: no count has given up or stalled.
    var awaitingNumber: Bool {
        pageReady && screenLayout != nil && !countGaveUp && !countStalled
    }
    /// The count can't run yet: the page isn't up, the reopen picture still covers it, or a reflow is under way
    /// (each one's end starts the count).
    private var countHeld: Bool { !pageReady || reopenPicture != nil || keeper.reflowing != nil }
    /// Your Page is open: he is still tuning the page, so no count starts behind it (gatefold#162). Each
    /// Justify tap in a landscape spread began a count (four to six hidden web views) that the next tap
    /// threw away before it counted a chapter, and making them held the page for seconds a tap. Closing it
    /// counts the layout he chose.
    @ObservationIgnored var tuning = false {
        didSet {
            guard oldValue, !tuning, countHeldForTuning else { return }
            countHeldForTuning = false
            Task { await refreshScreenNumbers(recount: true) }
        }
    }
    /// A count Your Page held back; only then does closing it count (a count still running is left alone).
    @ObservationIgnored private var countHeldForTuning = false
    /// No chapter counted, and no count begun, for a minute.
    private(set) var countStalled = false
    @ObservationIgnored private var stallTimer: Task<Void, Never>?
    /// Tests only: the minute's watch for a count that never moves is running.
    var countStallArmed: Bool { stallTimer != nil }
    private func countMoved() {
        countStalled = false
        stallTimer?.cancel()
        stallTimer = Task { [weak self] in
            try? await Task.sleep(for: Self.countStallWait)
            guard !Task.isCancelled, let self else { return }
            // Held, not stalled (gatefold#262): a count waiting on the page or its reflow hasn't stopped, and its
            // minute starts again. A fresh open on the iPad's side whose opening reflow ran past a minute blanked the slot.
            if self.countHeld { self.countMoved(); return }
            self.countStalled = true
            if self.screenNumbers == nil, self.screenLayout != nil {
                readerLog.error("pages: nothing counted for a minute and no number yet; the slot goes quiet")
            }
        }
    }
    /// How long a count may go without counting a chapter before the slot goes quiet; unit tests shorten it.
    static var countStallWait: Duration = .seconds(60)
    /// UI tests: "Counting pages…" was drawn at least once (CI's slow reads can miss it on screen).
    var countingShownProbe = false
    /// UI tests: how many times the number's slot was drawn empty on a page he can see, with page numbers on
    /// in a paged layout: neither the number nor "Counting pages…" (gatefold#262). Never set outside UI tests.
    var slotBlankProbe = 0
    /// UI tests only: the latest reflow's number and how far it has got ("3 reflowing", "3 placed", then
    /// "3 settled" once its page is fully shown, its cover faded or its swing played; a restore that gave way
    /// to his move counts as settled when its page starts showing), so a test can let a reflow settle before
    /// its next touch (gatefold#175). Never set outside UI tests.
    var reflowProbe = ""
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
        // Held, not stalled: the slot keeps saying "Counting pages…" (never blank) until he closes it.
        guard !tuning else { countHeldForTuning = true; stallTimer?.cancel(); stallTimer = nil; countStalled = false; return }
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
        // Every open has the same bound on its cover, the placeholder's or a reopen's picture (which
        // has no placeholder behind it): a page that hasn't shown by then is forced, counted in looks.
        // Only looks while he has the book open count: a book warming behind the shelf has no cover he
        // can see, and forcing it there would show him its unsettled page when he taps it.
        Task { [weak self] in
            var looks = 0
            while looks < Self.coverLooks {
                guard let model = self, !model.pageReady, !model.isClosed else { return }
                if !model.isWarming { looks += 1 }
                _ = consume model
                try? await Task.sleep(for: .milliseconds(50))
            }
            self?.forceReady()
        }
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
        // A place of ours in the front matter is still his place: the InkPad's further one is offered
        // once the page shows, never landed over (build 21).

        // The first page can take seconds to lay out on a cold web view; nothing below means anything
        // until the navigator reports where it is.
        await waitForLocation()
        readerLog.notice("open: location after \(Date().timeIntervalSince(self.openedAt), privacy: .public) s")
        if launchGoTo == nil, let initialLocator {
            // The cover stays up until his words are on screen: Readium's first report can arrive
            // before this finds them, and showing it then showed another page and jumped to his about
            // 10 s later (a cold relaunch with no picture of his page, build 20).
            // A starved host can outlast the cover's bound: then the page is already in view when his
            // words are found, and it stays where it is, with his place offered as a Jump.
            await settle(on: initialLocator, move: moves, offerOnceInView: true)
        }
        openSettling = false
        readerLog.notice("open: settled after \(Date().timeIntervalSince(self.openedAt), privacy: .public) s")
        // A test's launch jump shows its page once, after the jump, not the book's start first.
        if launchGoTo == nil { markReady() }
        if let goTo = launchGoTo, let locator = await publication.locate(progression: goTo) {
            launchJumpInFlight = true
            noteLeftBehind()
            hasMoved = true
            moves += 1
            let jumpMove = moves
            // Sent until the page says it is there: Readium refuses a jump while it is loading, and a
            // web view still loading can take one, open the file's first page and drop the place inside
            // it (CI's Duo opened a jump to 0.993 at 0.938 and stayed; #30). Counted in reads.
            // Landed when the page on screen holds the target's place in its file (`JumpLanding`). A place
            // with no progression in its file can't be checked, so it is sent once and not called landed.
            let target = locator.locations.totalProgression ?? goTo
            let landed: Bool
            if let inFile = locator.locations.progression {
                landed = await JumpLanding.land(
                    target: ReadingAnchor(href: locator.href.string, progression: inFile, text: nil),
                    go: { [weak self] in await self?.page?.go(to: locator) == true },
                    visible: { [weak self] in await self?.page?.pageRange() },
                    reported: { [weak self] in
                        self?.page?.currentLocation.map { ReadingAnchor(href: $0.href.string, progression: $0.locations.progression ?? 0, text: nil) }
                    },
                    // A turn of his ends it: a page forced into view while the jump still reads as loading
                    // takes his tap, and a resend then put the page back over his turn (CI's Duo at c57dfcd).
                    stillWanted: { [weak self] in self.map { $0.moves == jumpMove && !$0.isClosed } ?? false },
                    beat: jumpBeat)
            } else {
                await page?.go(to: locator)
                landed = false
            }
            readerLog.notice("open: the launch jump to \(target, privacy: .public) \(landed ? "landed" : locator.locations.progression == nil ? "was sent once (no place in its file to check)" : "ran out of reads", privacy: .public) at \(self.page?.currentLocation?.locations.totalProgression ?? -1, privacy: .public)")
            launchJumpInFlight = false
            // The jump is one move, kept where it ended: Readium's reports on the way (its file's first page)
            // were not places, and a report can't be counted on after it (gatefold#83).
            // It is his move even if a reflow ended while it was on its way and marked reports as layout.
            layoutOnly = false
            if moves != jumpMove {
                // He moved while the jump was on its way (its reports were dropped): his page is the place.
                if let here = page?.currentLocation { await locationDidChange(here) }
            } else if landed {
                if let here = page?.currentLocation { await locationDidChange(here) }
            } else {
                // Not landed (the page never showed it, or Readium's own report never caught up): the place
                // kept is where he was sent, never the file start it passed through. Only the place: the
                // running head and the end check stay with what Readium names until it reports again.
                owedJumpTarget = (locator, jumpMove)
                await locationDidChange(locator, placeOnly: true)
                if !placeOwed { owedJumpTarget = nil }
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
        guard !pageReady, !awaitingLanding, !revealing, !openSettling, page?.currentLocation != nil else { return }
        revealing = true
        Task {
            // A reflow under way when the page is ready (an iPad opened in landscape lays out upright
            // first, then turns) is still moving the spread under its cover, a picture that can be half
            // painted: the page shows once it has placed his words. Counted in looks.
            var looks = 0
            while keeper.reflowing != nil, looks < Self.revealLooks, !isClosed {
                looks += 1
                try? await Task.sleep(for: .milliseconds(50))
            }
            await host?.waitForSettledPage()
            // The cover stays until Readium has finished loading the page it reports (its spinner).
            let held = Date()
            // Checked often, and a page Readium would hold back after it has scrolled into place is
            // shown as soon as it has painted (`unveilPlacedPages`).
            // Waited out in looks, however long the chapter takes: the cover gave up after 8 s and
            // showed a blank page and a spinner on a slow device (#38).
            await host?.waitWhileLoading()
            readerLog.notice("open: Readium's loading held \(Date().timeIntervalSince(held), privacy: .public) s (asked \(Date().timeIntervalSince(self.askedAt), privacy: .public) s ago)")
            revealing = false
            guard !pageReady, !isClosed else { return }
            Task { [weak self] in await self?.host?.logTypography() }
            readerLog.notice("first page ready after \(Date().timeIntervalSince(self.isWarming ? self.openedAt : self.askedAt), privacy: .public) s\(self.isWarming ? " (behind the shelf)" : "", privacy: .public)")
            showPage()
        }
    }
    private var revealing = false
    /// A saved place not yet settled on: from init until load() has settled the page on his words,
    /// nothing but the placeholder's bounded `forceReady` reveals the page.
    @ObservationIgnored private var openSettling = false
    /// Looks (one check every 50 ms) the reveal waits for the open's settle or a reflow before showing
    /// anyway: 60, about 3 s. The settle itself is bounded at 4 rounds of two page reads; this only
    /// bounds a page whose reads never come back.
    static let revealLooks = 60
    /// How long Catch up, taken over the opening cover, waits for the first page to show, in looks: past
    /// the cover's own worst case (its 11.5 s, `revealLooks`, then a load waited out over up to 1200 looks
    /// that each take longer than 50 ms), so on a starved host it never lands into a page still loading.
    static let catchUpReadyLooks = 6000
    /// Looks (one every 50 ms) any open keeps its cover before the page is forced: 230, about 11.5 s,
    /// the placeholder's own timeout.
    static let coverLooks = 230
    /// Looks (one every 50 ms) a reopen's picture of his page waits for the open's settle: 900, about 45 s.
    /// The picture is his page, so waiting costs nothing he can see; the settle ends long before on a
    /// device (29 s on CI's starved Duo).
    static let pictureSettleLooks = 900

    /// The cover gives way to the page. A reopen's picture of the page stays over it a moment longer,
    /// while the running head and footer come up beneath, then goes at once: the two are the same
    /// page, so nothing moves.
    @discardableResult
    func queueReopenTurn(forward: Bool) -> Bool { app.queueReopenTurn(forward: forward) }

    /// The picture was made for this launch from one in another paper or window: never pixel for
    /// pixel the live page, so it fades.
    var reopenAdapted = false

    /// The count gave up waiting for the reopen's picture: the picture's lift counts the book instead.
    @ObservationIgnored private var countsWhenPictureLifts = false

    private func showPage() {
        // Shown with no restore under way: nothing pending to put the open's bare place back.
        if keeper.reflowing == nil { openedOnBarePlace = nil }
        withAnimation(.easeOut(duration: 0.3)) { pageReady = true } completion: { [weak self] in self?.coverLifted = true }
        foldOnceSeen()
        if reopenPicture == nil { pageShownAt = Date() }
        // Counting the book's pages waits until the open has settled (the reopen picture gone too), so
        // it never slows the first page.
        Task {
            for _ in 0..<120 where reopenPicture != nil { try? await Task.sleep(for: .milliseconds(250)) }
            // A picture still up (a long settle beneath it) counts the book itself when it lifts.
            guard reopenPicture == nil else { countsWhenPictureLifts = true; return }
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
            // The picture is his page: it stays while the open settles, so the settle moves the page beneath
            // it, not in view. A starved Duo forced the page at 27 s, lifted the picture onto the page
            // Readium guessed (306, his was 326), then found his words and could only offer them (#46).
            // Bounded, and a turn he asks of the picture ends the wait.
            for _ in 0..<Self.pictureSettleLooks where openSettling && app.reopenQueuedTurn == nil && !isClosed {
                try? await Task.sleep(for: .milliseconds(50))
            }
            // The picture never lifts onto a page still loading (#38), nor one the open's settle is moving.
            await host?.waitWhileLoading()
            for _ in 0..<Self.revealLooks where openSettleGoing && !isClosed { try? await Task.sleep(for: .milliseconds(50)) }
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
            if countsWhenPictureLifts {
                countsWhenPictureLifts = false
                Task { [weak self] in try? await Task.sleep(for: .milliseconds(400)); await self?.refreshScreenNumbers(recount: true) }
            }
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
        Task {
            // The open's settle on his words is bounded in rounds; this bounds the wait for it in looks,
            // so a settle whose page never answers can't leave him looking at the cover.
            var looks = 0
            while openSettling, looks < Self.revealLooks, !isClosed {
                looks += 1
                try? await Task.sleep(for: .milliseconds(50))
            }
            // A move the settle has begun finishes behind the cover: shown mid-move, the page jumps.
            // A page still loading isn't forced into view: a blank page and a spinner is no first page.
            // A later round can begin a move while it loads, so both are waited for together.
            looks = 0
            repeat {
                while openSettleGoing, looks < Self.revealLooks, !isClosed {
                    looks += 1
                    try? await Task.sleep(for: .milliseconds(50))
                }
                await host?.waitWhileLoading()
            } while openSettleGoing && looks < Self.revealLooks && !isClosed
            guard !pageReady, !isClosed else { return }
            readerLog.notice("first page forced ready after \(Date().timeIntervalSince(self.openedAt), privacy: .public) s")
            showPage()
        }
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
        // First time this book opens here, the cover still up: there's no place of ours to protect, so
        // just open where the InkPad is, like picking the book up off the nightstand. Only on its exact
        // words: a place the Cloud has as a whole percent can land pages away. Anything else (a place
        // of ours, a percent, a page he can already see) is offered, never landed on: only he moves
        // the place (build 20 moved it under him on a foreground check).
        if Self.landsAtOpen(neverOpenedHere: openedSnapshot == nil,
                            exact: target.locator != nil, coverUp: awaitingLanding && !pageReady, moved: hasMoved) {
            readerLog.notice("first open: landing on the Cloud place \(remote.pointer ?? "no pointer", privacy: .public)")
            await land(on: target.locator, progression: target.totalProgression, target: aim, cloud: remote.totalProgression, rememberBack: true)
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
        // Ours on a fresh install, not landed (a percent, or the cover already gone): offered like the
        // InkPad's, never dropped.
        let made = JumpSuggestion.make(
            local: hasMoved ? app.library.book(bookID)?.localSnapshot : openedSnapshot,
            remote: ProgressSnapshot(totalProgression: target.totalProgression, updated: remote.updated, device: remote.deviceName),
            totalPages: chapterMap.positionCount > 1 ? chapterMap.positionCount : nil,
            remotePercentOnly: percentOnly
        )
        guard let made else { return }
        readerLog.notice("remote ahead: \(remote.pointer ?? "no pointer", privacy: .public) → \(target.locator?.text.highlight ?? "no text", privacy: .private)")
        offersHisPlace = false
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

    /// Whether a Cloud place is landed on rather than offered: a book never opened here, on the Cloud's
    /// exact words, before its first page has shown.
    nonisolated static func landsAtOpen(neverOpenedHere: Bool, exact: Bool, coverUp: Bool, moved: Bool) -> Bool {
        neverOpenedHere && exact && coverUp && !moved
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
        foldOwed = false
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.4, bounce: 0.15)) { slipFolded = true }
    }

    /// The tab, tapped: the slip opens again with its offer.
    func unfoldSlip() {
        guard slipFolded else { return }
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.4, bounce: 0.2)) { slipFolded = false }
        foldSlipLater()
    }

    /// Unanswered, the offer folds itself away after a while rather than sitting on the page. The while
    /// counts from when he can see it and answer: an offer made behind the shelf, or under the opening
    /// cover, waits for the tap and the page (`foldOnceSeen`). Made at a warm open's start, it folded about
    /// 10 s later, before a starved iPad's page had shown, and Catch up found only its tab (gatefold#156).
    private func foldSlipLater() {
        slipTask?.cancel()
        guard !isWarming, pageReady else {
            foldOwed = true
            return
        }
        foldOwed = false
        slipTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(LaunchOptions.offerFoldSeconds))
            guard !Task.isCancelled else { return }
            self?.foldSlip()
        }
    }

    /// An offer whose fold waits for him to see it.
    @ObservationIgnored private var foldOwed = false

    /// He can see the offer now (the book tapped, its page up): its wait before folding starts.
    private func foldOnceSeen() {
        guard foldOwed else { return }
        guard slipKind == .ahead, slip != nil, !slipFolded, !isClosed else { foldOwed = false; return }
        foldSlipLater()
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
        // "From your e-reader" is news, not a question: it goes by itself. An offer folds away.
        guard kind == .landed else { return foldSlipLater() }
        slipTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.hideSlip()
        }
    }

    func hideSlip() {
        slipTask?.cancel()
        foldOwed = false
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

    /// His own saved place, found only after a forced reveal: offered through the Jump banner, landed on
    /// (and underlined) only when he taps it. A Cloud place offered later replaces it.
    private func offerHisPlace(_ locator: Locator, at exact: Double) async {
        guard !isClosed, suggestion == nil else { return }
        // The page in view is where he is now: a reflow keeps it, not the place on offer.
        await captureAnchor()
        guard !isClosed, suggestion == nil else { return }
        let total = locator.locations.totalProgression ?? totalProgression
        // Counted from the page in view (Readium's guess), not the place saved: that's what he sees.
        let shown = page?.currentLocation?.locations.totalProgression
        let pages = shown.flatMap { from in locator.locations.totalProgression.flatMap { pagesBetween(from, $0) } }
        suggestionLocator = locator.copy(locations: { $0.progression = exact })
        suggestionRemote = nil
        suggestionCloud = nil
        offersHisPlace = true
        withAnimation(Motion.banner) {
            suggestion = .ownPlace(at: total, page: chapterMap.positionCount > 1 ? chapterMap.page(at: total) : nil)
        }
        page?.prepareStandby(at: suggestionLocator ?? locator)
        aheadTab = SyncSlip.ownPlaceTab
        aheadTarget = nil
        slipFolded = false
        showSlip(.ownPlace(pagesAway: pages, passage: locator.text.highlight), kind: .ahead)
    }
    /// The slip up is his own place, offered after a forced reveal (not another device's).
    @ObservationIgnored private var offersHisPlace = false
    /// The open's settle is moving the page: a forced reveal waits for the move to finish.
    @ObservationIgnored private var openSettleGoing = false

    func acceptSuggestion() async {
        guard let s = suggestion, !isClosed else { return }
        hisMoves += 1
        withAnimation(Motion.banner) { suggestion = nil }
        hideSlip()
        let locator = suggestionLocator, aim = suggestionRemote, cloud = suggestionCloud
        // His own place: the guessed page he was shown is not a place to come back to.
        let own = offersHisPlace
        offersHisPlace = false
        let tapped = ContinuousClock.now
        readerLog.notice("catch-up: tapped (exact place \(locator != nil, privacy: .public))")
        if LaunchOptions.holdOpeningLoadUntilCatchUp { host?.releaseHoldForCatchUp() }
        suggestionLocator = nil
        suggestionRemote = nil
        suggestionCloud = nil
        // Taken while the first page still loads behind the opening cover (the offer sits above it):
        // Readium refuses a jump then, and the landing's few reads can't outwait a chapter's load. The
        // landing goes once the page shows, which the cover itself bounds (`forceReady`); counted in looks.
        for _ in 0..<Self.catchUpReadyLooks where !pageReady && !isClosed { try? await Task.sleep(for: .milliseconds(50)) }
        guard !isClosed else { return }
        // The pages riffle past on the way, the way a thumb finds a place in a real book.
        await veiled(riffle: true, forward: s.targetProgression >= totalProgression) {
            await self.land(on: locator, progression: s.targetProgression, target: aim, cloud: cloud, rememberBack: !own)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        if let locator {
            host?.underline(locator, color: theme.palette.accent)
            watchUnderline()
        }
        readerLog.notice("catch-up: underlined \(Self.ms(since: tapped), privacy: .public) ms after the tap")
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

    /// The Back pill comes up after a jump, controls or not, and stays until he reads on: a timer took
    /// it away before he noticed a jump he never meant (build 20), and then the way back took two taps.
    private func holdJumpBack() {
        turnsSinceJump = 0
        readerLog.notice("back: up \(self.backLocator != nil, privacy: .public)")
        withAnimation(Motion.chrome) { showJumpBack = backLocator != nil }
    }

    /// A turn or a scroll of his: after a few the jump is where he reads, and the pill goes.
    private func readOnAfterJump() {
        guard showJumpBack else { return }
        turnsSinceJump += 1
        readerLog.notice("back: read on \(self.turnsSinceJump, privacy: .public)")
        if turnsSinceJump >= JumpBack.turnsToKeep { withAnimation(Motion.chrome) { showJumpBack = false; backGaveUp = false } }
    }

    /// What the pill says: the start, or just "where you were" (a counted page number could still be the
    /// page before a jump within the chapter, and Readium's positions are not the pages he sees).
    var backLabel: String {
        if backGaveUp { return "Couldn't go back. Try again" }
        if (backLocator?.locations.totalProgression ?? 1) < 0.005 { return "Back to the start" }
        return "Back to where you were"
    }

    /// The pages jumps have left since his place was last kept, as Readium last named each: a report of
    /// exactly one of them, while Readium names another page and the newest move isn't kept, is a late
    /// one (gatefold#174). Every jump adds its page, so a second jump before the first is kept still
    /// knows the first page left. A turn or scroll back to such a page has his touch, or Readium naming
    /// it, so it is never taken for one. The rule rests on Readium's own page, not the jump's target:
    /// Readium reports its page boundary, which a target needn't match, and the report reaches here
    /// through a task hop, by which time Readium has usually moved on (when it hasn't, the late
    /// report is still kept).
    @ObservationIgnored private var pagesLeft: [Locator] = []
    /// A report whose reads outlasted a newer move: that move's own report keeps the place.
    private func noteOvertaken(_ l: Locator) {
        readerLog.notice("place: a report from before move \(self.moves, privacy: .public) (\(Self.placeTag(l), privacy: .public)); that move keeps the place")
    }
    private func noteLeftBehind() {
        if let here = page?.currentLocation, !pagesLeft.contains(where: { Self.samePage($0, here) }) { pagesLeft.append(here) }
    }
    private func isLateReportOfThePageLeft(_ l: Locator) -> Bool {
        guard recordedMoves < moves, pagesLeft.contains(where: { Self.samePage(l, $0) }),
              let now = page?.currentLocation, !Self.samePage(now, l) else { return false }
        return true
    }
    private static func samePage(_ a: Locator, _ b: Locator) -> Bool {
        a.href == b.href && abs((a.locations.progression ?? -1) - (b.locations.progression ?? -1)) < 0.000_1
    }

    /// A jump keeps the old page on screen, dimmed, until the new one has painted, then cross-fades.
    /// Returns the jump's step; `step` is one the caller took for it beforehand.
    @discardableResult
    private func veiled(riffle: Bool = false, forward: Bool = true, step: Int? = nil, _ body: @escaping () async -> Void) async -> Int {
        let jump = step ?? takeStep()
        noteLeftBehind()
        // Where the newest move left the page, noted the moment its jump is back: a jump overtaken
        // meanwhile (a Back freed by its count) that lands late is put back there.
        let tracked: () async -> Void = { [weak self] in
            await body()
            guard let self else { return }
            self.landed(jump, at: self.page?.currentLocation)
        }
        // Behind the cover placeholder there's nothing to veil.
        if let host, pageReady {
            await host.veiledJump(riffle: riffle && !reduceMotion && pageTurn == .curl, forward: forward, jump: jump, tracked)
        } else {
            await tracked()
        }
        return jump
    }
    /// Every move of the page, his or ours: a jump, a turn, a swipe. Only the newest one's landing is
    /// where the page belongs.
    @ObservationIgnored private var steps = 0
    @ObservationIgnored private var landedStep = 0
    @ObservationIgnored private var lastLanded: Locator?
    private func takeStep() -> Int { steps += 1; return steps }
    private func landed(_ step: Int, at here: Locator?) {
        guard step == steps, let here else { return }
        lastLanded = here
        landedStep = step
    }
    /// The page is on the newest move's landing (none still on its way).
    private var newestHasLanded: Bool { landedStep == steps }

    /// Goes to another device's place: the exact spot when its CFI resolved, else its percent.
    /// Records the place once, when the page has settled, and never earlier than `target`.
    private func land(on locator: Locator?, progression: Double, target: ReadingPosition?, cloud: Double? = nil, rememberBack: Bool) async {
        guard !isClosed else { return }
        // A Cloud landing makes his own place's offer stale.
        if offersHisPlace { dismissSuggestion() }
        guard let locator else {
            // A place the Cloud holds only as a percent. The page this lands on is his place from now:
            // kept nothing, every reopen landed on the percent afresh and the spread could fall on the
            // page beside the one he left (build 20's reopen loop, 3 in 19). The landing's own steps are
            // not places (as below): `go` counts this move first thing.
            let move = moves + 1
            landingMove = move
            await go(toProgression: progression, rememberBack: rememberBack, his: false)
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
        let step = steps
        landingMove = move
        defer { if landingMove == move { landingMove = nil } }
        let started = ContinuousClock.now
        let ready = await page?.promoteStandby(for: locator) ?? false
        if ready, keeper.reflowing != nil { endReflowForSwap() }
        if !ready { await page?.go(to: locator) }
        let went = Self.ms(since: started)
        // Opening another chapter, Readium places the page by progression before the chapter has laid
        // out; once it has, the same jump finds the exact words. Retry until they're on screen.
        await settle(on: locator, move: move, loaded: ready)
        // Overtaken by a turn, another jump or the close: that move owns the place now.
        guard moves == move, !isClosed else { return }
        // The spread the place it keeps reopens on: its words to the top of a left page, as a restore
        // puts them. Given way to any move of his, another jump or the close meanwhile.
        if let words = locator.text.highlight.map(ReaderJS.normalize), !words.isEmpty {
            let his = hisMoves, step = steps
            let anchor = ReadingAnchor(href: locator.href.string, progression: locator.locations.progression ?? 0, text: words)
            // A reflow's restore owns the page once it begins (one settler at a time), and a swipe of his
            // takes a step without counting a move.
            settlingLanding = (move, locator)
            await page?.settleLanding(anchor) { [weak self] in
                guard let self else { return false }
                return self.moves == move && self.hisMoves == his && self.steps == step
                    && self.keeper.reflowing == nil && !self.isClosed
            }
            if settlingLanding?.move == move { settlingLanding = nil }
        }
        let settled = Self.ms(since: started)
        guard moves == move, !isClosed else { return }
        await captureAnchor()
        let anchored = Self.ms(since: started)
        guard moves == move, !isClosed, let here = page?.currentLocation else { return }
        // Landed on the other device's page: that's the reader's place now.
        landed(step, at: here)
        await recordLanding(here, target: target, cloud: cloud)
        readerLog.notice("landing timing (standby \(ready, privacy: .public)): go \(went, privacy: .public) ms, settled \(settled, privacy: .public) ms, anchored \(anchored, privacy: .public) ms, recorded \(Self.ms(since: started), privacy: .public) ms")
    }

    /// The standby page swapped in was laid out at the size the open reflow brought; the page that
    /// reflow was laying out is retired, so it can never settle. Left open, it held every settle and
    /// retake of the landing's words for good, and the place kept was Readium's boundary, which
    /// reopened on another page (gatefold#261, a catch-up tapped while a reflow restarted).
    private func endReflowForSwap() {
        readerLog.notice("reflow: a standby page swapped in during reflow \(self.reflowCount, privacy: .public); the reflow ends with the page it was laying out")
        keeper.restoreGaveWay()
        page?.endReflowForSwap()
        reflowDidFinish(visible: nil)
        reflowShown(reflowCount)
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
                self.pagesLeft = []
                self.newestWrittenMove = max(self.newestWrittenMove, self.moves)
                readerLog.notice("place write [r\(self.readerNumber, privacy: .public)]: landing (\(fresh != nil ? "his first words" : "Readium's boundary", privacy: .public)) \(Self.placeTag(settledLocator), privacy: .public); kept total \(chosen?.totalProgression ?? here.locations.totalProgression ?? 0, privacy: .public); move \(self.moves, privacy: .public)")
                self.placeRecords += 1
                if LaunchOptions.isUITest { self.savedPlaceProbe = Self.probeTag(settledLocator) }
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
        } else if !isClosed, moves == move {
            readerLog.notice("place: no first words for the landing after \(captures, privacy: .public) captures (reflow open \(self.keeper.reflowing != nil, privacy: .public)); Readium's boundary stays")
        }
    }

    /// Readium places the page by its own progression, which counts layout, not text; once the
    /// chapter is on screen, find the locator's words in it and turn to their page. Stops as soon as
    /// anything else moves the page (`move` is no longer the latest) or the reader closes.
    /// `offerOnceInView`: the open's settle under the cover. If the cover's bound has already shown the
    /// page (forced ready, no picture over it), moving it now would jump a page he can see, so his place
    /// is offered as a Jump instead (build 21 on a starved iPad: forced at 25.3 s, moved 0.5 s later).
    private func settle(on locator: Locator, move: Int, loaded: Bool = false, offerOnceInView: Bool = false) async {
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
            if offerOnceInView, pageReady, reopenPicture == nil {
                // The read can take seconds on a starved host: look again, he may be on his words by now.
                let now = await page?.visibleRange()?.text.map(ReaderJS.normalize) ?? ""
                guard current(), !now.contains(probe) else { return }
                // A Cloud landing is on its way: it moves the page itself, and his own place isn't news.
                guard !awaitingLanding else { return }
                readerLog.notice("settle \(round, privacy: .public): found at \(found, privacy: .public) ms with the page in view; offering his place, not moving it")
                await offerHisPlace(locator, at: exact)
                return
            }
            if offerOnceInView { openSettleGoing = true }
            _ = await page?.go(to: locator.copy(locations: { $0.progression = exact }, text: { $0 = Locator.Text() }))
            if offerOnceInView { openSettleGoing = false }
            readerLog.notice("settle \(round, privacy: .public): read \(read, privacy: .public), found \(found, privacy: .public), went \(Self.ms(since: t0), privacy: .public) ms")
        }
    }

    /// The reader closed the book: whatever is still settling or landing stops here, so nothing moves
    /// the page or records a place after the close has sent the last one.
    func close() {
        if isWarming, !pageReady { hostController?.halt() }
        // A move a reflow still owes is his place: kept now, since that reflow will never end (gatefold#96).
        let owed = owedPlaceOnLeaving()
        isClosed = true
        launchJumpDone()
        stallTimer?.cancel()
        activation?.resume()
        activation = nil
        moves += 1
        slipTask?.cancel()
        slip = nil
        suggestion = nil
        page?.dropStandby()
        page?.stopCounting()
        hostController?.close()
        suggestionLocator = nil
        suggestionRemote = nil
        suggestionCloud = nil
        if let owed {
            keepShownPageNow(owed)
            Task {
                await keepOwedPlace(owed)
                // Sent now: the close's own send may have gone before this write.
                app.library.flushPushes()
            }
        }
    }

    /// What a reflow still owes as he leaves: an unreached jump's target, or the page he is on. Read
    /// before the page goes, so a reflow that never settles (a slow device, a load stuck as in gatefold#94)
    /// can't drop the move he made under it (gatefold#96).
    func owedPlaceOnLeaving() -> Locator? {
        guard !isClosed, !isWarming else { return nil }
        // A jump of his still on its way (its chapter loading, Readium's page not yet reported) is owed its
        // target: the page on screen is still the one before it, and with no report nothing was written,
        // so the reopen had no place at all (gatefold#279). Not a contents jump's (gatefold#254 keeps the
        // place before), and not once a touch or a report has made the page his.
        if let (target, move, _) = jumpOnItsWay, move == moves, recordedMoves != moves, !touchedSinceLocation,
           fragmentJumpMove != moves {
            readerLog.notice("place: leaving a jump still on its way; its target kept at \(Self.placeTag(target), privacy: .public)")
            owedJumpTarget = (target, move)
            placeOwed = true
        }
        // No move owed, but a restore that never settled left him the page as it was: that page is what he
        // saw, so it is what the reopen shows (gatefold#133).
        if !placeOwed {
            // Named once, here, before the close counts its move: the write, the inactive write and the
            // reopen picture's tag all carry the same place (`withKeptWords`).
            leavingOnShownPage = shownOnLeaving.map(withKeptWords)
            return leavingOnShownPage
        }
        // A contents jump still on its way (or closed mid-way) shows its file's first page, a place he never
        // chose: nothing is written for the owed move, the place saved before stands, and a jump that goes
        // on writes its own place where it ends (gatefold#254).
        if fragmentJumpMove == moves {
            readerLog.notice("place: leaving mid contents jump; the page on its way (\(self.page?.currentLocation.map(Self.placeTag) ?? "none", privacy: .public)) is not written")
            return nil
        }
        return owedJumpTarget.flatMap { $0.1 == moves && !touchedSinceLocation ? $0.0 : nil } ?? page?.currentLocation
    }

    /// Writes the place a reflow owed, as he leaves: the reader may have closed, and the reflow may
    /// still be under way. Only the place; nothing on screen changes. If he hasn't closed the book
    /// (the app only went inactive), the debt stands: a reflow that settles later still records his
    /// own words over this write, as it would have without it. So does the page a stalled restore left
    /// him (`reflowDidFinish` writes the settled page back over it).
    func keepOwedPlace(_ here: Locator) async {
        keepShownPageNow(here)
        let shown = shownKeptNow.map { $0.href == here.href && $0.locations.progression == here.locations.progression } == true
        shownKeptNow = nil
        leavingOnShownPage = nil
        guard placeOwed || shown, !isWarming else { return }
        let recordedBefore = recordedMoves
        // A jump still on its way (gatefold#279): its own report may arrive during this write's waits and
        // be judged already kept, clearing the debt; the move stays open to it either way, so his page's
        // words are still written once Readium reports it.
        let jumpOwed = jumpOnItsWay.map { $0.1 == moves } == true && owedJumpTarget.map { $0.0.href == here.href && $0.0.locations.progression == here.locations.progression } == true
        if !shown {
            readerLog.notice("place: recorded the move a reflow held, on leaving, at \(here.locations.totalProgression ?? -1, privacy: .public) moves \(self.moves, privacy: .public) recorded \(self.recordedMoves, privacy: .public)")
        }
        if isClosed { owedJumpTarget = nil }
        // Still open (the app only went inactive): once the restore settles, the page it settles on is
        // the one he sees again, and it is written back over this one. Noted before the write's own wait.
        // The shown page's write took its move when it was written (`keepShownPageNow`), not now.
        let movesAtWrite = shown ? (shownLeaveWrite?.move ?? moves) : moves
        if shown { await mapShownPagePosition(here) } else {
            if jumpOwed { leaveWriteMove = moves; reportWroteInLeave = false }
            await locationDidChange(here, hisMove: true, placeOnly: true, leaving: true)
            if jumpOwed { leaveWriteMove = nil }
        }
        // The restore settled during that wait: its write-back may have gone first, so this one follows it.
        if shown, !isClosed, keeper.reflowing == nil, moves == movesAtWrite, !touchedSinceLocation, let words = anchorLocator {
            shownWrittenOpen = nil
            readerLog.notice("place: the restore settled while the page it left was written; its page written back at \(words.locations.totalProgression ?? -1, privacy: .public)")
            layoutOnly = false
            await locationDidChange(words, hisMove: true, placeOnly: true)
            if moves == movesAtWrite, !touchedSinceLocation { layoutOnly = true }
        }
        // Handed back to the next report, unless the jump's own report already wrote his page meanwhile: a
        // later report of the same move (the layout settling) would then write over his words.
        if !isClosed, placeOwed || jumpOwed, recordedMoves == moves, !(jumpOwed && reportWroteInLeave) {
            recordedMoves = recordedBefore
        }
    }

    /// Leaving on the page a stalled restore left him: written now, in the caller's own turn (the close,
    /// the app going inactive), before any Task or wait. The page under a stalled restore can hold any
    /// script or resource load, and the app may be ended a moment after he leaves (gatefold#133: the
    /// write waited on the chapter's mapping, and the reopen kept the page from before the rotation).
    /// His words go with it if the page gave them; the mapped position follows on the same place (`keepOwedPlace`).
    /// Does nothing unless `owedPlaceOnLeaving` named that page; safe to call again.
    func keepShownPageNow(_ here: Locator) {
        guard let leaving = leavingOnShownPage, !isWarming else { return }
        leavingOnShownPage = nil
        guard leaving.href == here.href, leaving.locations.progression == here.locations.progression else { return }
        shownKeptNow = here
        // The page as shown is the place now: no longer the layout's, whatever the reflow before it set.
        layoutOnly = false
        readerLog.notice("place write [r\(self.readerNumber, privacy: .public)]: the page a restore left unsettled, on leaving, at \(here.locations.totalProgression ?? -1, privacy: .public)")
        writeShownPageAtOnce(here)
        if !isClosed, let written = shownLeaveWrite { shownWrittenOpen = written.move }
        // Sent now too: the caller's own send may already have gone.
        app.library.flushPushes()
    }
    @ObservationIgnored private var shownKeptNow: Locator?

    /// The place the library keeps for this book now.
    var keptPlace: Locator? { app.library.book(bookID)?.locatorJSON.flatMap { try? Locator(jsonString: $0) } }

    /// `here` with his first words when it has none and the place kept now is that very place with words
    /// (his turn's write before the stalled restore showed the same page). Readium's bare progression sits
    /// on a page boundary, and a reopen can land on either side of it (gatefold#133: one page early).
    /// Only while nothing has moved since that write (no turn, jump or landing not yet kept; or no move at
    /// all since the open, the kept place being the one opened): a new page never inherits the old page's words.
    private func withKeptWords(_ here: Locator) -> Locator {
        guard here.text.highlight == nil, !hasMoved || recordedMoves == moves,
              let kept = keptPlace,
              kept.text.highlight != nil, kept.href == here.href,
              kept.locations.progression == here.locations.progression else { return here }
        readerLog.notice("place write [r\(self.readerNumber, privacy: .public)]: the page left has no words; the kept place's words go with it (same place)")
        return here.copy(text: { $0 = kept.text })
    }

    /// The shown page's leave write, at once: the place as noted (with his first words if the page gave
    /// them before he left, `reflowShownUnsettled`), no position mapped, no wait. The words matter: under a
    /// stalled restore Readium's progression can name a page beside the one shown, and the reopen found
    /// that page (CI 43034011191: written at once, words never attached before the app was ended).
    @ObservationIgnored private var shownLeaveWrite: (records: Int, move: Int, json: String)?
    /// Each step of that write, for tests: "written", "position mapped (cfi)" or "(percent only)", "gave up".
    @ObservationIgnored private(set) var shownLeaveSteps: [String] = []
    private func writeShownPageAtOnce(_ here: Locator) {
        guard let json = try? here.jsonString() else {
            readerLog.notice("place write [r\(self.readerNumber, privacy: .public)]: the page left unsettled could not be encoded; not written")
            return
        }
        // As the ordinary leave write keeps it (`locationDidChange(leaving:)`): kept as of now.
        if isClosed { placeOwed = false }
        lastReported = here
        recordedMoves = moves
        pagesLeft = []
        newestWrittenMove = max(newestWrittenMove, moves)
        placeRecords += 1
        if LaunchOptions.isUITest { savedPlaceProbe = Self.probeTag(here) }
        app.library.recordPlace(bookID: bookID, locatorJSON: json, totalProgression: here.locations.totalProgression ?? 0,
                                progression: here.locations.progression ?? 0, at: Date())
        shownLeaveWrite = (placeRecords, moves, json)
        shownLeaveSteps.append("written")
        if LaunchOptions.isUITest { savedWordsProbe = here.text.highlight.map(ReaderJS.normalize) ?? "" }
        readerLog.notice("place write [r\(self.readerNumber, privacy: .public)]: the page left unsettled written on leaving, at once, at \(here.locations.totalProgression ?? -1, privacy: .public), \(here.text.highlight == nil ? "no words" : "with his first words", privacy: .public)")
    }
    /// The exact position for that same write, when the chapter's mapping comes (it reads the chapter, which a
    /// stalled page can hold: gatefold#240): written only over that very write (no newer place, no newer
    /// move, the library still holding it), the same locator, never anywhere else.
    private func mapShownPagePosition(_ here: Locator) async {
        guard let written = shownLeaveWrite else { return }
        guard here.text.highlight != nil else {
            readerLog.notice("place write [r\(self.readerNumber, privacy: .public)]: no words for the page left unsettled; its place kept without them")
            return
        }
        let now = Date()
        await placeWriteWait()
        let exact = await mapper?.position(for: BookLocation(here), at: now)
        guard placeRecords == written.records, moves == written.move, newestWrittenMove == written.move,
              app.library.book(bookID)?.locatorJSON == written.json else {
            shownLeaveSteps.append("gave up")
            readerLog.notice("place write [r\(self.readerNumber, privacy: .public)]: the position for the page left unsettled gave up (a newer place or move came first)")
            return
        }
        placeRecords += 1
        if LaunchOptions.isUITest { savedPlaceProbe = Self.probeTag(here) }
        app.library.recordPlace(bookID: bookID, locatorJSON: written.json, totalProgression: here.locations.totalProgression ?? 0,
                                progression: here.locations.progression ?? 0,
                                position: exact.map { var p = $0; p.totalProgression = here.locations.totalProgression ?? p.totalProgression; return p },
                                at: now)
        shownLeaveWrite = (placeRecords, written.move, written.json)
        shownLeaveSteps.append(exact?.cfi != nil ? "position mapped (cfi)" : "position mapped (percent only)")
        readerLog.notice("place write [r\(self.readerNumber, privacy: .public)]: position mapped for the page left unsettled, at \(here.locations.totalProgression ?? -1, privacy: .public), cfi \(exact?.cfi != nil, privacy: .public)")
    }

    func dismissSuggestion() {
        offersHisPlace = false
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

    /// The page the 12 s watchdog showed him while the restore under it hadn't settled, and `moves` then.
    /// Until that restore ends or he moves, that page is the one he sees (gatefold#133).
    @ObservationIgnored private var shownUnsettled: (locator: Locator, move: Int)?
    /// Leaving on that page: `keepOwedPlace` keeps it though no move is owed. Set as he leaves, before
    /// `close()` counts its own move.
    @ObservationIgnored private var leavingOnShownPage: Locator?
    private var shownOnLeaving: Locator? {
        guard let shown = shownUnsettled, shown.move == moves, keeper.reflowing != nil, !touchedSinceLocation else { return nil }
        return shown.locator
    }

    /// `moves` when the page a stalled restore left him was written while the book stayed open.
    @ObservationIgnored private var shownWrittenOpen: Int?

    /// The watchdog showed the page as it is, its restore still unsettled: noted as Readium names it, then
    /// by its first words (`words`) if the page answers while the note stands.
    /// Returns the note's number; its words come back with it (`wordsFor`), and count only while that
    /// note is still the one standing.
    @discardableResult
    func reflowShownUnsettled(_ here: Locator, onScreen: ClosedRange<Double>? = nil, wordsFor note: Int? = nil) -> Int? {
        guard keeper.reflowing != nil, !isClosed, !isWarming else { return nil }
        if let note { guard let shown = shownUnsettled, shown.move == moves, note == shownNotes else { return nil } }
        else { shownNotes += 1 }
        var here = here
        if note == nil, let onScreen, here.text.highlight == nil { here = pageOnScreen(here, onScreen) }
        // The words come paired with Readium's location, the very name a note from the screen distrusts:
        // only the words are taken, on the note's own place (gatefold#276).
        if note != nil, let shown = shownUnsettled { here = shown.locator.copy(text: { $0 = here.text }) }
        shownUnsettled = (here, moves)
        readerLog.notice("reflow: the page shown unsettled is at \(here.locations.totalProgression ?? -1, privacy: .public)")
        return shownNotes
    }
    @ObservationIgnored private var shownNotes = 0

    /// The page shown unsettled as the screen has it (`onScreen`: the chapter's span in view), not as
    /// Readium names it. Under a stalled restore Readium's location can be stale (the chapter's start, with
    /// the page further on: PR #285's run 43147454242), and even when right it is the page's first column,
    /// a boundary the reopen can round onto the page before (CI 43075159905). So the place is the middle of
    /// the page on screen, gatefold#276. When that page starts at his kept place and nothing has moved
    /// since, it is his kept page: its own place, so his words go with it (`withKeptWords`, gatefold#133).
    private func pageOnScreen(_ named: Locator, _ onScreen: ClosedRange<Double>) -> Locator {
        let width = onScreen.upperBound - onScreen.lowerBound
        if !hasMoved || recordedMoves == moves, let kept = keptPlace, kept.text.highlight != nil,
           kept.href == named.href, let at = kept.locations.progression, abs(at - onScreen.lowerBound) <= width * 0.05 {
            return named.copy(locations: { $0.progression = at; $0.totalProgression = kept.locations.totalProgression ?? $0.totalProgression })
        }
        let middle = onScreen.lowerBound + width / 2
        var total = named.locations.totalProgression
        let href = named.href.string
        if let i = readingOrderHrefs.firstIndex(of: href) ?? readingOrderHrefs.firstIndex(where: { href.hasPrefix($0) }),
           i < resourceStarts.count {
            let start = resourceStarts[i]
            let end = i + 1 < resourceStarts.count ? resourceStarts[i + 1] : 1
            total = start + middle * (end - start)
        }
        readerLog.notice("reflow: the page shown unsettled is on screen at \(onScreen.lowerBound, privacy: .public)..\(onScreen.upperBound, privacy: .public) of its chapter (Readium named \(named.locations.progression ?? -1, privacy: .public)); kept at its middle")
        return named.copy(locations: { $0.progression = middle; $0.totalProgression = total })
    }

    func reflowDidBegin() {
        shownUnsettled = nil
        shownNotes += 1
        reflowCount += 1
        reflowTouches = 0
        landingChecks = 0
        anchorCheck = "settling \(reflowCount)"
        if LaunchOptions.isUITest { reflowProbe = "\(reflowCount) reflowing" }
    }

    private var reflowSettledAt: Date?
    @ObservationIgnored private var landingChecks = 0

    /// A report that is the layout's, not his move, may mean the page moved under the restore (the
    /// navigator laying out again after the restore's last look; CI's reopen landed a page beside him).
    /// Until he moves, his words are looked for on the left page again, a few times per reflow.
    private func recheckLanding() {
        guard !hasMoved, !touchedSinceLocation, !isClosed, !isWarming, keeper.reflowing == nil,
              let anchor = keeper.anchor, anchor.text != nil, landingChecks < 3 else { return }
        landingChecks += 1
        let movesNow = moves
        Task { [weak self] in
            await self?.page?.keepWordsOnLeft(anchor, stillWanted: { [weak self] in
                guard let self else { return false }
                return !self.isClosed && self.moves == movesNow && !self.hasMoved
                    && !self.touchedSinceLocation && self.keeper.reflowing == nil
            })
        }
    }

    /// The latest reflow's number, for `reflowShown`.
    var reflowNumber: Int { reflowCount }

    /// UI tests only: reflow `number`'s page is fully shown. A newer reflow begun meanwhile keeps its own state.
    func reflowShown(_ number: Int) {
        guard LaunchOptions.isUITest, number == reflowCount else { return }
        reflowProbe = "\(number) settled"
    }

    func reflowDidFinish(visible: VisibleRange?) {
        // A restore landed: the open's bare place is never put back after it.
        openedOnBarePlace = nil
        shownUnsettled = nil
        shownNotes += 1
        // He came back to a restore that then settled: the page it settled on is his again, not the one
        // written as he went (his words, which the restore put back on the left page).
        if let written = shownWrittenOpen {
            shownWrittenOpen = nil
            if written == moves, !isClosed, !isWarming, !touchedSinceLocation, let words = anchorLocator {
                Task { [weak self] in
                    guard let self, self.moves == written, !self.isClosed, !self.touchedSinceLocation, self.keeper.reflowing == nil else {
                        readerLog.notice("place: the settled page's write-back skipped (a move, a touch or a new reflow first)")
                        return
                    }
                    readerLog.notice("place: the restore settled after he came back; its page written back at \(words.locations.totalProgression ?? -1, privacy: .public)")
                    self.layoutOnly = false
                    await self.locationDidChange(words, hisMove: true, placeOnly: true)
                    if self.moves == written, !self.touchedSinceLocation { self.layoutOnly = true }
                }
            }
        }
        reflowSettledAt = Date()
        if LaunchOptions.isUITest { reflowProbe = "\(reflowCount) placed" }
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
                // A launch jump still on its way is kept where it lands, not where it passes through: kept
                // at its file's first page, the reopen came back pages early (main at 379fda7, iPad taps).
                // Its landing's report records it; this waits as `keepMoveMadeBehindTheShelf` does.
                await self.waitForLaunchJump()
                guard self.placeOwed, !self.isClosed, self.keeper.reflowing == nil else { return }
                // The keeper ignored the move while the reflow ran, so its words are the page before it:
                // take them from the page he is on now.
                await self.captureAnchor()
                // A turn that landed meanwhile recorded its own page and paid the debt.
                // A jump that never landed owes where he was sent, not Readium's stale file start.
                // A slide or scroll since (no move counted; a report under the reflow leaves the touch
                // pending) makes his page the place, not the target. A tap that only shows the controls doesn't.
                let target = self.owedJumpTarget.flatMap { $0.1 == self.moves && !self.touchedSinceLocation ? $0.0 : nil }
                guard self.placeOwed, !self.isClosed, self.keeper.reflowing == nil,
                      let here = target ?? self.page?.currentLocation else { return }
                // Kept until now: a reflow that began meanwhile owes it still.
                self.owedJumpTarget = nil
                let movesNow = self.moves
                readerLog.notice("place: recorded the move a reflow held, at \(here.locations.totalProgression ?? -1, privacy: .public) moves \(self.moves, privacy: .public) recorded \(self.recordedMoves, privacy: .public)")
                self.recordingOwed = true
                await self.locationDidChange(here, placeOnly: target != nil)
                self.recordingOwed = false
                // Kept: later reports with no move of his are the layout again.
                if self.moves == movesNow, !self.touchedSinceLocation { self.layoutOnly = true }
            }
        }
    }
    /// A move arrived while a reflow was under way; the reflow's end records it.
    @ObservationIgnored private(set) var placeOwed = false
    /// `moves` when the place was last recorded: a reflow only owes a move not yet kept, so an
    /// ordinary rotation never swaps his exact words for Readium's page boundary.
    @ObservationIgnored private var recordedMoves = -1
    /// The newest move whose place a write has taken, never lowered (`keepOwedPlace` lowers
    /// `recordedMoves` after its write): a write still on its way for an older move yields to it.
    @ObservationIgnored private var newestWrittenMove = -1
    /// Every place recorded, by any path: a later write-back of words counts only if none came since.
    @ObservationIgnored private var placeRecords = 0
    /// The move whose first report is still reading his words before its write (`locationDidChange`).
    @ObservationIgnored private var claimedMove: Int?
    /// A launch jump that never landed, and its move: owed by a reflow, its target is the place kept.
    @ObservationIgnored private var owedJumpTarget: (Locator, Int)?
    /// The newest jump of his to a place (the scrubber, a bookmark, a search result) and its move: the place
    /// a leave keeps while that move has no report yet (gatefold#279).
    /// `from` is Readium's last report before the jump: the page it leaves, which a leave's write never
    /// takes for the jump's own report (the leave's own call names the target as the last report).
    @ObservationIgnored private var jumpOnItsWay: (target: Locator, move: Int, from: Locator?)?
    /// A jump of his to a place is being sent to the page (a UI test's `-GatefoldHoldJumpSends` holds it).
    @ObservationIgnored private(set) var isJumpingToPlace = false
    /// The move whose jump target a leave is writing (`keepOwedPlace`), while that write waits.
    @ObservationIgnored private var leaveWriteMove: Int?
    /// The jump's own report wrote while that leave's write waited.
    @ObservationIgnored private var reportWroteInLeave = false
    /// The latest report of the claimed move that was dropped for the claim.
    @ObservationIgnored private var contestingReport: Locator?
    /// Set when a reflow ends (or an owed place is kept) and cleared by a move of his, or a report his
    /// touch brought: while
    /// it's up, a location report is the layout (a rotation, an unfold, a late report from the new
    /// spread), never a reason to rewrite the place. It stays down until the next reflow, not just the
    /// next report, so a long scroll's later reports still count.
    @ObservationIgnored private var layoutOnly = false
    /// The owed place is being recorded: its words were just taken.
    @ObservationIgnored private var recordingOwed = false

    /// The saved place this reader opened on when it had no words (`init`): until the open's restore has
    /// landed or he has moved, a restore that finds the page elsewhere puts him back on it, once.
    @ObservationIgnored private var openedOnBarePlace: Locator?

    /// The open's bare place, if a restore should put it back now (gatefold#250): only while no anchor
    /// is held, the restore may still move the page, he hasn't moved since the open, and only once per
    /// open. Nil once he has turned, jumped, tapped a link or Contents, or a restore has landed.
    func openPlaceToReapply(visible: VisibleRange) -> (ReadingAnchor, Locator)? {
        guard let bare = openedOnBarePlace else { return nil }
        guard keeper.anchor == nil, hisMoves == 0, !touchedSinceLocation, page?.isTurning != true,
              keeper.restoreMayMove(move: hisMoves), !isClosed else {
            openedOnBarePlace = nil
            return nil
        }
        openedOnBarePlace = nil
        let anchor = ReadingAnchor(href: bare.href.string, progression: bare.locations.progression ?? 0, text: nil)
        guard !visible.contains(anchor) else { return nil }
        readerLog.notice("reflow: the open's place (no words) is off screen at \(visible.start, privacy: .public)..\(visible.end, privacy: .public); put back once at \(anchor.progression, privacy: .public)")
        return (anchor, bare)
    }

    /// The saved place as an anchor, when it carries the words that opened his page.
    static func openingAnchor(from locator: Locator?) -> ReadingAnchor? {
        guard let locator, let words = locator.text.highlight.map(ReaderJS.normalize), !words.isEmpty else { return nil }
        return ReadingAnchor(href: locator.href.string, progression: locator.locations.progression ?? 0, text: words)
    }

    func locator(for anchor: ReadingAnchor) -> Locator? {
        // A landing being settled: its own words' place, not the page he left (the last one captured).
        // Its words too, not the chapter alone: a restore that overtakes the settle (a rotation) asks for
        // his kept place in the same chapter before the settle has returned.
        if let landing = settlingLanding?.locator, landing.href.string == anchor.href,
           landing.text.highlight.map(ReaderJS.normalize) == anchor.text { return landing }
        return anchorLocator
    }
    /// The landing a settle is moving the page to, while it does, and the move that made it.
    @ObservationIgnored private var settlingLanding: (move: Int, locator: Locator)?

    // MARK: Navigation events

    /// `placeOnly`: keep `locator` as the place without naming it on screen (a launch jump that never
    /// landed: the page still shows what Readium names, so the running head and the end check stay there).
    /// `leaving`: the place a reflow owes, written as he leaves (`keepOwedPlace`), past a close and a reflow
    /// still under way.
    func locationDidChange(_ locator: Locator, duringTurn: Bool = false, hisMove: Bool = false, placeOnly: Bool = false,
                           leaving: Bool = false) async {
        guard !isClosed || leaving else { return }
        // A late report of the page a jump left, once the page has moved on and before the jump's move is
        // kept, is that page's, not a move of his: kept, it took the jump's move and his place was saved
        // as the page he had left; the jump's own report then found it kept (gatefold#174, CI's iPad: the
        // book's first file written 36 ms after a jump landed at 0.309).
        if !hisMove, !duringTurn, !leaving, !touchedSinceLocation, isLateReportOfThePageLeft(locator) {
            readerLog.notice("place: a late report of the page a jump left (\(Self.placeTag(locator), privacy: .public)); not his move, nothing kept")
            return
        }
        let reportedBefore = lastReported
        lastReported = locator
        if LaunchOptions.isUITest { shownPlaceProbe = Self.probeTag(locator) }
        if !placeOnly {
            location = locator
            // The reader turning on: the other device's line has done its job.
            if !landing, duringTurn || touchedSinceLocation { host?.clearUnderline() }
            refreshAheadTab()
            // The navigator opens on the saved place, so its first report is a page worth showing: don't
            // keep the cover up while the rest of the book is indexed.
            if !pageReady, launchGoTo == nil { markReady() }
            Task { await refreshScreenNumbers() }
            if !duringTurn, hasMoved, isPastStory(locator) { reachedEnd() }
        }
        // A landing records its place once it has settled; the steps on the way are not places. So does a
        // test's launch jump: a report on its way (its file's first page) could finish after the landing and
        // be kept as his move, and Back then went there (gatefold#83). `load()` reports where it ended.
        guard !landing, !launchJumpInFlight, fragmentJumpMove != moves || leaving else { return }
        // Mid-turn the navigator has moved under the overlay; the turn records the place when it lands.
        // A move reported mid-reflow (a turn or a jump while an iPad's first layout is still settling)
        // is owed: the reflow's end records it, or the place he went to is never kept (build 17 reopened
        // a book jumped to during that reflow at its start, then landed on the Cloud's older place).
        // A reader warmed behind the shelf has no place of his to owe.
        // A scroll or swipe of his while the reflow lays out (a touch, and the page moved since the last
        // report) is his move too: the restore gives way to it and his page is owed, never put back under
        // him (gatefold#171: switching to Scroll on a slow iPad, six swipes, then the restore brought the
        // words from before the switch back).
        // Only a touch made after the reflow began counts (one from before it, such as holding the iPad as
        // it turns, would hand the restore's place to the layout's page boundary), and each touch once.
        if keeper.reflowing != nil, !leaving, !duringTurn, !isWarming, reflowTouches > 0, Self.pageMoved(reportedBefore, locator) {
            reflowTouches = 0
            hisMoves += 1
            hasMoved = true
            moves += 1
            // A move of the page, as a swipe's is: a late Back after it puts the page back here.
            landed(takeStep(), at: locator)
            // Reading on after a jump, as a turn is (the report's own step sees this move as overtaken).
            readOnAfterJump()
            readerLog.notice("reflow: a scroll of his while it lays out; the restore gives way (reported \(Self.placeTag(locator), privacy: .public))")
        }
        if keeper.reflowing != nil, !leaving, hasMoved, moves != recordedMoves, !duringTurn, !isWarming {
            if !placeOwed { readerLog.notice("place: owed by a reflow, at \(locator.locations.totalProgression ?? -1, privacy: .public) moves \(self.moves, privacy: .public) recorded \(self.recordedMoves, privacy: .public)") }
            placeOwed = true
        }
        // A touch that brought a report under the reflow was a slide or scroll, his own move: his page is
        // the place now, not an unreached jump's target. The report is dropped below and its touch stays
        // pending, so a tap for the controls before the reflow ends would otherwise bring the target back.
        // A layout report between a tap's touch-down and its recognition looks the same and drops the
        // target too: the rule outside reflows ("a report after a touch is his") errs the same way.
        if keeper.reflowing != nil, !leaving, touchedSinceLocation { owedJumpTarget = nil }
        guard keeper.reflowing == nil || leaving, !duringTurn else { return }
        // A reader still open keeps the debt for its reflow's end (`keepOwedPlace`).
        if !leaving || isClosed { placeOwed = false }
        // Only he moves the place: a turn, a jump or a touch since the last report. A report after a
        // reflow, with none of them since, is the layout (a rotation, an unfold, a late report from the new spread), and it never
        // re-anchors or rewrites the saved place: a spread that slips a verso before his page starts a
        // page early, and saving its start reopened him a page early (build 17's rotation miss).
        // One move, one place: once a move is kept, a further report with no turn, jump or touch since
        // is the layout's too (build 20's real unfold: the web view finishing its load had Readium name
        // the chapter's first page after a kept jump, and saving it lost his words on the next unfold).
        // The first report of a move owns its write, from the moment it arrives: another report of the
        // same move while that one is still reading his words (Readium's boundary a beat after the jump)
        // is the layout's. Judged only after the reads, the later report could finish first and keep the
        // boundary (#82, on a busy runner).
        let claimedByEarlier = claimedMove == moves && !hisMove && !touchedSinceLocation
        // A report dropped for a claim may be the real place (a two-step jump names its file's start,
        // then the place): the claimant then keeps whichever of the two the page on screen holds.
        if claimedByEarlier { contestingReport = locator }
        // A leave still writing a jump's target (gatefold#279) hasn't kept the move: the jump's own report,
        // arriving during that write's waits, is his page with its words, and it writes. Only a page that
        // moved: a re-report of the page before the jump (the layout, the app going inactive) is not it.
        let leaveWriting = leaveWriteMove == moves && !leaving && Self.pageMoved(jumpOnItsWay?.from, locator)
        let alreadyKept = (moves == recordedMoves && !hisMove && !leaveWriting) || claimedByEarlier
        let touchedAtReport = touchedSinceLocation
        let readerMoved = (!layoutOnly && !alreadyKept) || touchedAtReport
        // The move this report was judged for. Its reads below can outlast a jump (a report of the book's
        // start, read before a launch jump, waited for the web view and resumed after the jump landed).
        let judgedMove = moves
        let claim = readerMoved && !hisMove && !touchedAtReport && hasMoved && !isWarming ? moves : nil
        if let claim { claimedMove = claim; contestingReport = nil }
        // A claim that ends without a write leaves the move to the next report.
        defer { if let claim, claimedMove == claim, recordedMoves != claim { claimedMove = nil } }
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
            recheckLanding()
        } else if !readerMoved, keeper.anchor != nil {
            // Words read before this page's start were read on a page he has left (gatefold#143: a slow
            // launch landing read them on the chapter's first page). Kept, a reflow's restore or the
            // landing check would take the page back to them, so they are read again from his page.
            if keeper.reflowing == nil, !openSettling, let words = anchorLocator, Self.lies(words, before: locator) {
                await captureAnchor()
                let taken = anchorLocator.map { !Self.lies($0, before: locator) } == true
                readerLog.notice("location without a move; his words were before this page, \(taken ? "anchor taken again" : "anchor read failed, kept", privacy: .public) at \(self.anchorLocator.map(Self.placeTag) ?? "none", privacy: .public) (reported \(Self.placeTag(locator), privacy: .public))")
            } else {
                readerLog.notice("location without a move; anchor and place kept, anchor at \(self.anchorLocator.map(Self.placeTag) ?? "none", privacy: .public) (reported \(Self.placeTag(locator), privacy: .public))")
            }
            recheckLanding()
        } else {
            let held = keeper.anchor, heldLocator = anchorLocator
            await captureAnchor()
            // Overtaken while reading (below): not the layout's either, so it neither puts back older words
            // nor marks the newer move's report as the layout's.
            guard moves == judgedMove else { return noteOvertaken(locator) }
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
        // A move made during those reads owns the place and its bookkeeping: this report names where the
        // page was before it. Kept, it took that move's write (gatefold#201: the book's start, reported
        // before a launch jump, was written as the jump's move after it landed, and every reopen opened on
        // the cover); left to note this report, the move's own report read as the layout's and kept nothing.
        guard moves == judgedMove else { return noteOvertaken(locator) }
        // No turn or jump of ours since the last report: a page move his touch brought is Readium's own
        // swipe or scroll (a turn counts itself in `userTurnedPage`).
        let noMoveOfOurs = moves == movesAtLastReport
        touchesSinceLocation = 0
        movesAtLastReport = moves
        // A report that isn't his move leaves "where he is" on his words: the running head, the
        // Cloud's "here" and the scrubber read `location`, so it names the page on screen, not
        // Readium's boundary (build 19: the head said the next chapter while his words stayed put).
        let justReflowed = !recordingOwed && reflowSettledAt.map { Date().timeIntervalSince($0) < 1.2 } == true
        let notHisMove = layoutReport || !readerMoved || justReflowed
        // Not words read before the page on screen, though (gatefold#143: after a slow launch landing
        // his words were read on the chapter's start and his page came up with no move of his; the head,
        // the scrubber and the Cloud's "here" all named the start). Mid-reflow or while the open settles,
        // Readium's place is a guess, and from the layout his words were just seen first on screen (their
        // place is the old layout's): his words stand.
        if notHisMove, !placeOnly, let words = anchorLocator, keeper.anchor?.text != nil,
           layoutReport || keeper.reflowing != nil || openSettling || !Self.lies(words, before: locator) { location = words }
        let fromLayout = layoutReport
        layoutReport = false
        // A swipe or a scroll of his that moved the page is reading on, as a turn is (slide and scroll
        // never call `userTurnedPage`). A jump's own landing brings no touch, nor does a tap that only
        // shows the controls.
        let swiped = touchedAtReport && readerMoved && !fromLayout && Self.pageMoved(reportedBefore, locator)
        if swiped && noMoveOfOurs { readOnAfterJump() }
        // A swipe is a move of the page too (a late Back after it puts the page back here). A Back freed
        // by its count never reported its move, so with one out a swipe counts without a report since;
        // but not one in its chapter, which may be that trip landing (Readium reports before the jump
        // returns). Whatever such a report kept, the trip's return writes his place again (`goBack`),
        // unless a newer move still on its way does.
        if swiped && (noMoveOfOurs || strayBack != nil) && !isStrayChapter(locator) { landed(takeStep(), at: locator) }
        // Only the reader moves the place. Readium reopening a page boundary off from the saved one is
        // not a move, so opening a book never overwrites a further-ahead place on the InkPad.
        // A book warmed behind the shelf has had no move of his yet: nothing it reports is his place.
        // Asked again here, after the waits above: a second report that arrived while this one captured
        // its words found the move not yet kept, and both wrote (build 20's loop saved two places for one
        // jump, 0.3 s apart, from one reader).
        let keptMeanwhile = moves == recordedMoves && !hisMove && !touchedAtReport && !leaveWriting
        guard hasMoved, readerMoved, !keptMeanwhile, !fromLayout, !isWarming else {
            // No write: the move is the next report's to keep, from now, not after the wait below.
            if let claim, claimedMove == claim { claimedMove = nil }
            return refreshBookmarkState(await page?.visibleRange())
        }
        // Kept as of now, before any further wait.
        recordedMoves = moves
        if leaveWriting { reportWroteInLeave = true }
        pagesLeft = []
        let keeping = moves
        newestWrittenMove = max(newestWrittenMove, keeping)
        // The first words on screen make the place exact; Readium's progression is a page boundary.
        // Only words captured on this very page count; a capture a reflow cut short leaves the last page's.
        let fresh = anchorLocator.flatMap { a in
            a.href == locator.href && a.locations.progression == locator.locations.progression ? a : nil
        }
        // A contested claim keeps the report the page on screen holds: by the page's own range, never
        // by which report came first (the boundary after a jump, or a jump's file start before its place).
        var reported = locator
        var here = fresh ?? locator
        // The page's own geometry (`pageRange`), not `visibleRange`, which starts at Readium's latest
        // report; a page that can't be measured keeps the claimant. Read after the wait, so a report
        // that came during it counts.
        if claim != nil, contestingReport != nil, let range = await page?.pageRange(), let other = contestingReport {
            func shown(_ l: Locator) -> Bool {
                range.contains(ReadingAnchor(href: l.href.string, progression: l.locations.progression ?? 0, text: nil))
            }
            if !shown(locator), shown(other) {
                reported = other
                here = anchorLocator.flatMap { a in
                    a.href == other.href && a.locations.progression == other.locations.progression ? a : nil
                } ?? other
            }
        }
        if let json = try? here.jsonString() {
            let now = Date()
            let recordsBefore = placeRecords
            await placeWriteWait()
            // UI tests: a turn's write never lands, as on a device that ends Gatefold first (gatefold#301).
            if LaunchOptions.holdTurnWrites, lastTurnMove == keeping {
                readerLog.notice("place write [r\(self.readerNumber, privacy: .public)]: move \(keeping, privacy: .public), a turn's, held for good (test)")
                while true { try? await Task.sleep(for: .seconds(3600)) }
            }
            let exact = await mapper?.position(for: BookLocation(here), at: now)
            // The jump's target written as he left gives way to the jump's own report, written meanwhile:
            // that one is his page, with its words (gatefold#279).
            if leaving, leaveWriteMove == keeping, placeRecords != recordsBefore {
                readerLog.notice("place write [r\(self.readerNumber, privacy: .public)]: the jump's own report was written while its target was; target not written")
                return refreshBookmarkState(await page?.visibleRange())
            }
            // A newer move kept during those waits owns the place: this write, resumed after it, would land
            // over it (#46 at c4c3b6a: the Contents jump's write landed after Back's and kept the jump's page).
            guard newestWrittenMove == keeping else {
                readerLog.notice("place write [r\(self.readerNumber, privacy: .public)]: move \(keeping, privacy: .public) overtaken by move \(self.newestWrittenMove, privacy: .public)'s write, not written")
                return refreshBookmarkState(await page?.visibleRange())
            }
            if LaunchOptions.isUITest {
                savedWordsProbe = here.text.highlight.map(ReaderJS.normalize) ?? ""
                savedPlaceProbe = Self.probeTag(here)
            }
            readerLog.notice("place write [r\(self.readerNumber, privacy: .public)]: his move (\(fresh != nil ? "his first words" : "Readium's boundary", privacy: .public)) \(Self.placeTag(here), privacy: .public); reported \(Self.placeTag(locator), privacy: .public); move \(self.moves, privacy: .public), touched \(self.touchedSinceLocation, privacy: .public), layoutOnly \(self.layoutOnly, privacy: .public)")
            placeRecords += 1
            app.library.recordPlace(
                bookID: bookID,
                locatorJSON: json,
                totalProgression: reported.locations.totalProgression ?? 0,
                progression: reported.locations.progression ?? 0,
                position: exact.map { var p = $0; p.totalProgression = reported.locations.totalProgression ?? p.totalProgression; return p },
                at: now
            )
        }
        refreshBookmarkState(await page?.visibleRange())
        // Not while Back's trip lands on it: that one's way back replaces it when the jump is done.
        // (A trip slower than its reads is freed first, and its way back briefly clears here until
        // `publishBack` puts the new one up.)
        if goingBack == nil, let back = backLocator, abs((back.locations.totalProgression ?? 0) - (reported.locations.totalProgression ?? totalProgression)) < 0.0001 {
            readerLog.notice("back: on its own place, cleared")
            backLocator = nil
        }
    }

    /// A touch on the page. If the next location (outside a reflow) differs from where the book
    /// opened, it was a swipe in slide or scroll mode and the place is the reader's own. A tap that
    /// only shows the controls changes no location, so it moves nothing.
    func noteInteraction() {
        touchesSinceLocation += 1
        if host?.veilIsUp != true { unveiledInputs += 1 }
    }
    /// He opened Contents: a jump still on its way with no veil over it gives way to him (gatefold#254).
    func contentsOpened() {
        if host?.veilIsUp != true { unveiledInputs += 1 }
    }
    /// His touches on the page, and his openings of Contents, made with no jump's veil over the page.
    @ObservationIgnored private var unveiledInputs = 0
    /// A finger that travelled on the page: a scroll or swipe, never a tap. Only one made while a reflow
    /// lays out can be a move of his under it (gatefold#171); a finger already moving when the reflow
    /// began brings no new drag, so it never counts.
    /// In curl and fade the page moves only by a turn (`userTurnedPage`), never under the finger, so a
    /// drag there (one that springs back, or runs up the page) is no scroll.
    func noteDrag() {
        guard keeper.reflowing != nil, pageTurn == .scroll || pageTurn == .slide else { return }
        reflowTouches += 1
    }
    /// A curl that sprang back turned nothing: no drag of it is left to count.
    func dragDidNotTurn() { reflowTouches = 0 }
    /// Touches on the page since the last location report; a tap that only shows or hides the controls
    /// clears them.
    @ObservationIgnored private var touchesSinceLocation = 0
    /// Drags on the page since the reflow under way began and not yet counted as a move of his
    /// (gatefold#171); a tap that only shows or hides the controls, a turn and a jump clear them.
    @ObservationIgnored private var reflowTouches = 0
    /// The page moved between two reports (no report before counts as a move).
    private static func pageMoved(_ before: Locator?, _ now: Locator) -> Bool {
        before.map { $0.href != now.href || $0.locations.progression != now.locations.progression } ?? true
    }
    var touchedSinceLocation: Bool { touchesSinceLocation > 0 }
    /// `moves` at the last location report: a report with none since is no turn or jump of his.
    @ObservationIgnored private var movesAtLastReport = 0
    /// This report came from the layout (see `locationDidChange`).
    @ObservationIgnored private var layoutReport = false
    private var openedLocation: Locator?
    /// The navigator's last report, to tell a swipe that moved the page from a touch that didn't.
    @ObservationIgnored private var lastReported: Locator?

    /// A turn landed or sprang back: take the place from where the navigator is now.
    func userTurnedPage() {
        // The turn counts itself; its tap or swipe is no second move under a reflow.
        reflowTouches = 0
        hisMoves += 1
        foldSlip()
        readOnAfterJump()
        hasMoved = true
        moves += 1
        lastTurnMove = moves
        let step = steps
        Task {
            guard let first = page?.currentLocation else { return }
            // A turn is a move too: a Back that comes back late after it puts the page back here.
            landed(step, at: first)
            await locationDidChange(first)
            // Turning into the next resource, Readium can name the old one until the new one has
            // loaded, and its update arrives mid-turn when it's ignored. Look again once it has.
            try? await Task.sleep(for: .milliseconds(700))
            // Not a freed Back's chapter while it is out: that page may be the trip landing, not this turn.
            if let later = page?.currentLocation, isStrayChapter(later) {
                readerLog.notice("turn: second look found a freed Back's chapter, skipped")
                return
            }
            if let later = page?.currentLocation, later.href != first.href
                || later.locations.progression != first.locations.progression {
                landed(step, at: later)
                // His turn's own report, corrected: never taken for the layout's (same words, no move since).
                await locationDidChange(later, hisMove: true)
            }
        }
    }

    /// The move of his latest landed turn.
    @ObservationIgnored private var lastTurnMove: Int?

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

    /// "Mark Finished on Your E-reader": 100 % and read in the Cloud.
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
        // tap follows before Readium reports it is the rarer case and is left to that report. A swipe
        // reported under a reflow has already dropped the jump's target (`locationDidChange`).
        touchesSinceLocation = 0
        reflowTouches = 0
        readerLog.notice("controls: \(visible ? "up" : "down", privacy: .public) by a tap")
        setChrome(visible)
    }

    /// Without the animation: the controls go down before the page is pictured for a reopen.
    func setChromeNow(_ visible: Bool) {
        chromeVisible = visible
    }

    // MARK: Jumps

    /// `his`: false for a landing's own percent step (the Cloud's place), which is not a move of his.
    func go(toProgression progression: Double, rememberBack: Bool, his: Bool = true) async {
        reflowTouches = 0
        if his { hisMoves += 1 }
        hasMoved = true
        moves += 1
        let back = rememberBack ? rememberPlace() : nil
        defer { publishBack(back) }
        if let locator = await publication.locate(progression: progression) {
            // His own jumps only: a Cloud landing (`his: false`) records its place once it has settled.
            if his { jumpOnItsWay = (locator, moves, lastReported ?? page?.currentLocation) }
            isJumpingToPlace = his
            await veiled { _ = await self.page?.go(to: locator) }
            isJumpingToPlace = false
            await captureAnchor()
            // Behind the cover nothing hides a chapter still loading, so keep the cover up until the
            // words are there.
            for _ in 0..<25 where !pageReady && keeper.anchor?.text == nil && !isClosed {
                try? await Task.sleep(for: .milliseconds(200))
                await captureAnchor()
            }
        }
    }

    /// VoiceOver's adjust on the scrubber: a swipe jumps a hundredth of the book, a jump like any other
    /// that isn't a turn, so one tap on Back undoes it.
    func adjustScrubber(forward: Bool) async {
        let target = totalProgression + (forward ? 0.01 : -0.01)
        await go(toProgression: min(1, max(0, target)), rememberBack: true)
    }

    func go(to entry: TOCEntry) async {
        reflowTouches = 0
        hisMoves += 1
        hasMoved = true
        moves += 1
        let back = rememberPlace()
        defer { publishBack(back) }
        // Scrolled, Readium's own fragment scroll finds the chapter: only columns lose it.
        if pageTurn != .scroll, let fragment = entry.link.url().fragment?.removingPercentEncoding, !fragment.isEmpty {
            let move = moves, step = takeStep()
            await veiled(step: step) { await self.land(on: entry.link, inside: fragment, move: move, jump: step) }
        } else {
            await veiled { await self.page?.go(to: entry.link) }
        }
        await captureAnchor()
    }

    /// A contents entry that starts partway through its file lands on its own page, kept once.
    ///
    /// Readium places a link's fragment with the file's script as the file loads. On a web view still
    /// laying out, that opens the file's first page and reports it, and the fragment is lost or comes late
    /// (gatefold#166: "Chapter XL", 0.80 into its file, was kept at the file's start, an earlier chapter).
    /// Where a fragment's page is exists only once the file is laid out in the page's own columns, so it
    /// can't be known before the jump: the jump goes to the file, the fragment's place is read there once
    /// the layout is done, and the page is sent to it (`JumpLanding`). All of it runs under the jump's veil,
    /// which lifts on the landed page: he sees one move, to the chapter he chose. Readium's reports on the
    /// way are not places; the place is written once, where the jump ends.
    private func land(on link: ReadiumShared.Link, inside fragment: String, move: Int, jump: Int) async {
        fragmentJumpMove = move
        await page?.go(to: link)
        let href = link.url().removingFragment().string
        // His page from the moment he takes it: a turn (a new move), or, with no veil over the page (one
        // that let go, or a jump that ran unveiled), a touch or Contents. The chapter's place arriving
        // after that moves nothing (gatefold#254: a page that jumps once he's reading is the spazz).
        let inputsAtStart = unveiledInputs
        let heTookOver = { [weak self] in self.map { $0.unveiledInputs != inputsAtStart } ?? false }
        let wanted = { [weak self] in self.map { $0.moves == move && !$0.isClosed && !heTookOver() } ?? false }
        var target: Double?, lastRead: Double?
        var absent = false
        // Reads while the chapter is still loading come from their own, larger count, as Back's do (gatefold#170,
        // #254: a load past the flat 30 s ended the jump on the file's first page and kept it). The veil lets
        // go at its old limit while the reads go on: from then his touch, turn or Contents ends the trip.
        let loading = { [weak self] in self?.page?.isLoadingChapter == true }
        var budget = JumpLanding.Budget(), read = 0
        while target == nil, !absent, wanted(), budget.take(loading: loading()) {
            read += 1
            if read == JumpLanding.reads + 1, budget.waited > 0 {
                readerLog.notice("contents: the jump to \(fragment, privacy: .public) still on its way after \(JumpLanding.reads, privacy: .public) reads; the veil lets go, the jump goes on")
                host?.abandonVeil(jump: jump)
            }
            if let here = page?.currentLocation, ContentsIndex.sameResource(here.href.string, href) {
                // -1: laid out, and no such element (a broken anchor): Readium's landing stands. A place is
                // taken once two reads agree: a layout still settling (its columns not final) can read
                // another (CI run 42852464361 took 0 for a place 0.79 into its file).
                if let p = await page?.progression(ofFragment: fragment) {
                    if p < 0 { absent = true } else if let last = lastRead, abs(last - p) < 0.001 { target = p } else { lastRead = p }
                } else { lastRead = nil }
            } else if read % JumpLanding.resendEvery == 0 {
                // Refused while a web view loaded (the page never reached the file): asked again.
                await page?.go(to: link)
            }
            if target == nil, !absent { await jumpBeat() }
        }
        var landed = false
        if let target, wanted(), let at = page?.currentLocation {
            let place = ReadingAnchor(href: at.href.string, progression: target, text: nil)
            if let shown = await page?.pageRange(), shown.contains(place) {
                landed = true
            } else {
                let locator = at.copy(locations: { $0.fragments = []; $0.progression = target }, text: { $0 = Locator.Text() })
                landed = await JumpLanding.land(
                    target: place,
                    go: { [weak self] in await self?.page?.go(to: locator) == true },
                    visible: { [weak self] in await self?.page?.pageRange() },
                    reported: { [weak self] in
                        self?.page?.currentLocation.map { ReadingAnchor(href: $0.href.string, progression: $0.locations.progression ?? 0, text: nil) }
                    },
                    stillWanted: wanted,
                    loading: loading,
                    beat: jumpBeat)
            }
        }
        if heTookOver(), moves == move {
            readerLog.notice("contents: the jump to \(fragment, privacy: .public) inside its file gave way to his touch or Contents; the page stays at \(self.page?.currentLocation.map(Self.placeTag) ?? "none", privacy: .public)\(target.map { String(format: " (the chapter was at %.5f)", $0) } ?? "", privacy: .public)")
        } else if moves != move {
            readerLog.notice("contents: the jump to \(fragment, privacy: .public) inside its file gave way to his move \(self.moves, privacy: .public); the page stays at \(self.page?.currentLocation.map(Self.placeTag) ?? "none", privacy: .public)")
        }
        readerLog.notice("contents: the jump to \(fragment, privacy: .public) inside its file \(landed ? "landed" : absent ? "has no such place" : target == nil ? "found no place for it" : "ran out of reads", privacy: .public) at \(self.page?.currentLocation.map(Self.placeTag) ?? "none", privacy: .public)")
        if fragmentJumpMove == move { fragmentJumpMove = nil }
        // One move, one place: kept where the jump ended. Overtaken (another move of his, or the close),
        // it writes nothing: reports were held only while this jump was the newest move, so the newer one
        // keeps its own place.
        guard moves == move, !isClosed, let here = page?.currentLocation else { return }
        layoutOnly = false
        await locationDidChange(here)
    }
    /// A contents jump inside its file still on its way: while it is the newest move, its reports are not
    /// places (`land(on:inside:move:)`).
    @ObservationIgnored private var fragmentJumpMove: Int?

    func follow(_ link: ReadiumShared.Link) async {
        reflowTouches = 0
        hisMoves += 1
        hasMoved = true
        moves += 1
        let back = rememberPlace()
        defer { publishBack(back) }
        await veiled { await self.page?.go(to: link) }
        await captureAnchor()
    }

    /// A highlight's exact place: Readium finds its words, so the page is the one they are on.
    func go(to locator: Locator, rememberBack: Bool) async {
        reflowTouches = 0
        hisMoves += 1
        hasMoved = true
        moves += 1
        let back = rememberBack ? rememberPlace() : nil
        defer { publishBack(back) }
        jumpOnItsWay = (locator, moves, lastReported ?? page?.currentLocation)
        await veiled { _ = await self.page?.go(to: locator) }
        await captureAnchor()
    }

    func go(to bookmark: Bookmark) async {
        let back = rememberPlace()
        defer { publishBack(back) }
        await go(toProgression: bookmark.totalProgression, rememberBack: false)
    }

    /// Back is a jump too: the page it leaves gets its own way back, so a stray tap on it is undone
    /// with one more.
    func goBack() async {
        guard let back = backLocator, goingBack == nil else { return }
        backGaveUp = false
        reflowTouches = 0
        hisMoves += 1
        backTrips += 1
        let trip = backTrips
        goingBack = trip
        // Released on every way out, and by the count if the jump never comes back (a load that hangs
        // must not leave Back dead for the rest of the session).
        defer { if goingBack == trip { goingBack = nil } }
        hasMoved = true
        moves += 1
        let move = moves
        // Its own step, apart from the move's: a newer step of any kind means another move came since.
        let jump = takeStep()
        // Reads while the chapter is still loading come from their own, larger count: a slow load is waited
        // for (gatefold#170), and only one that has died gives the trip up. The veil isn't: at its old
        // limit (`JumpLanding.reads` beats, about 30 s) it lets go and the chapter shows its own loading,
        // never a screen frozen for minutes, while the trip goes on and lands when the load comes in.
        // A move of his meanwhile (a turn, a swipe, a jump) ends the trip quietly: his new page stands.
        Task { [weak self] in
            var budget = JumpLanding.Budget(), beats = 0
            while let self, self.goingBack == trip, !self.isClosed {
                guard self.moves == move, self.steps == jump else {
                    // No jump of it out (none sent yet, or one between re-sends): the landing sees the move
                    // and sends nothing more. Still watched, so a jump already on its way that hangs is
                    // ended here, never left holding Back.
                    guard self.backGoOut == trip else { await self.backBeat(); continue }
                    readerLog.notice("back: trip \(trip, privacy: .public) overtaken by a move of his after \(beats, privacy: .public) beats; ended quietly")
                    self.goingBack = nil
                    self.strayBack = (jump, back.href)
                    self.host?.abandonVeil(jump: jump)
                    return
                }
                guard budget.take(loading: self.page?.isLoadingChapter == true) else { break }
                await self.backBeat()
                beats += 1
                // Only while the trip still has reads to wait on the load: one about to give up says so instead.
                if beats == JumpLanding.reads, budget.waited > 0, self.goingBack == trip {
                    readerLog.notice("back: trip \(trip, privacy: .public) still on its way after \(beats, privacy: .public) beats; the veil lets go, the trip goes on")
                    self.tripsPastTheVeil += 1
                    self.host?.abandonVeil(jump: jump)
                }
            }
            guard let self, self.goingBack == trip, !self.isClosed, self.moves == move, self.steps == jump else { return }
            readerLog.notice("back: trip \(trip, privacy: .public) ran out of reads (\(budget.spent, privacy: .public) read, \(budget.waited, privacy: .public) waiting on the load); Back is free again and says so")
            self.goingBack = nil
            self.strayBack = (jump, back.href)
            // Only this trip's own veil, or the one it was about to put up.
            self.host?.abandonVeil(jump: jump)
            // He sees that it didn't go, and one more tap tries again: the pill stays, its way back kept.
            withAnimation(Motion.chrome) {
                self.backGaveUp = true
                self.showJumpBack = self.backLocator != nil
            }
        }
        // The page on screen now: a Back tapped right after a jump comes before Readium's report of it.
        // The pill stays up through the jump and turns into this one's way back when it lands, never
        // taken down under his finger mid-tap (on the Duo a Back taken down and put up again never
        // showed, and going back could not be undone).
        let undo = rememberPlace(at: page?.currentLocation, keepingTheWayBack: true)
        // Not when the trip gave up: the pill keeps pointing at his page (gatefold#170).
        var keepsUndo = true
        defer { if keepsUndo { publishBack(undo) } }
        // Sent again until his page is on screen: a web view still loading takes the jump at its file's
        // first page and drops the place inside it (CI's iPad at 8c5f294: Back came back to the chapter's
        // start). Never once he has moved on or the trip was given up.
        // A swipe under the veil (slide mode) is a step of his, not a move: that also ends the re-sends.
        var sends = 0, backLanded = false
        await veiled(step: jump) {
            guard let inFile = back.locations.progression, inFile > 0 else {
                // Not over a move of his made while the old page was pictured.
                guard self.goingBack == trip, self.moves == move, self.steps == jump, !self.isClosed else { return }
                self.backGoOut = trip
                _ = await self.page?.go(to: back)
                if self.backGoOut == trip { self.backGoOut = nil }
                return
            }
            backLanded = await JumpLanding.land(
                target: ReadingAnchor(href: back.href.string, progression: inFile, text: nil),
                go: { [weak self] in
                    sends += 1
                    self?.backGoOut = trip
                    let went = await self?.page?.go(to: back) == true
                    if self?.backGoOut == trip { self?.backGoOut = nil }
                    return went
                },
                visible: { [weak self] in await self?.page?.pageRange() },
                reported: { [weak self] in
                    self?.page?.currentLocation.map { ReadingAnchor(href: $0.href.string, progression: $0.locations.progression ?? 0, text: nil) }
                },
                stillWanted: { [weak self] in self.map { $0.goingBack == trip && $0.moves == move && $0.steps == jump && !$0.isClosed } ?? false },
                loading: { [weak self] in self?.page?.isLoadingChapter == true },
                beat: { [weak self] in await self?.backBeat() })
        }
        // Freed by its count: whatever its reports did meanwhile (Readium can report before the jump
        // returns), the place is settled here, once, from what the page shows.
        // Its mark stays until that is done: its report can come while the page is being put back.
        let freed = strayBack?.jump == jump
        defer { if freed, strayBack?.jump == jump { strayBack = nil } }
        // A touch during the hang brought no report: a tap, not a swipe of the page it lands on. And
        // whatever the layout did meanwhile, the place written here is his.
        // Nothing may suspend between the jump coming back and this reset (`JumpLanding.land` returns an
        // overtaken landing with no beat): the late jump's own report would run first, with the swallowed
        // tap still counted, and be kept as a swipe of his (run 42614139141).
        if freed {
            touchesSinceLocation = 0
            layoutOnly = false
        }
        // Overtaken by another move, a Back takes no words: the page is that move's now. One that came
        // back in time is overtaken only by a jump or turn of his (`moves`) and simply stops there. A
        // freed one, back after its reads ran out, is overtaken by any newer step or move (a swipe, a turn) and the
        // page is put back where that move left it.
        guard freed ? steps == jump && moves == move : moves == move else {
            guard freed else { return }
            // Readium has moved the page to this trip's place by now. With the newest move landed (one
            // still on its way, a jump or a turn, lands after and wins), the page goes back to where it
            // left it, and that place is kept again: a report meanwhile may have kept this trip's.
            readerLog.notice("back: trip \(trip, privacy: .public) came back after another move; page put back, its words not taken")
            // Nor its pill: the way back stays the one he had (a page he left two moves ago is no way back).
            keepsUndo = false
            if pendingBack?.jump == undo { pendingBack = nil }
            guard newestHasLanded, host?.isTurning != true, !isClosed, let newest = lastLanded else { return }
            let restore = await veiled { _ = await self.page?.go(to: newest) }
            if steps == restore, !isClosed, let here = page?.currentLocation { await locationDidChange(here, hisMove: true) }
            return
        }
        // Given up (freed by its count) or out of reads, and his page isn't what the page shows: Back didn't
        // go. The pill keeps its way back and says so, and nothing here is taken as his (gatefold#170: the
        // watchdog and the landing count the same reads, so a jump that came back short is freed too).
        let gaveUp = (freed || (!backLanded && (back.locations.progression ?? 0) > 0 && steps == jump))
        if gaveUp, !(await pageShows(back, stillWanted: { [weak self] in self.map { $0.steps == jump && !$0.isClosed } ?? false })) {
            // Read again after the wait: a move of his meanwhile has its own pill, never this trip's words.
            guard steps == jump, freed || moves == move, !isClosed else { return }
            keepsUndo = false
            if pendingBack?.jump == undo { pendingBack = nil }
            readerLog.notice("back: trip \(trip, privacy: .public) never showed his page; the pill keeps it and says so")
            withAnimation(Motion.chrome) {
                backGaveUp = true
                showJumpBack = backLocator != nil
            }
            return
        }
        await captureAnchor()
        // No move since: it is his Back, late, and its place is kept now (its report may have come first).
        if freed, steps == jump, !isClosed, let here = page?.currentLocation {
            // Late, but there: the pill no longer says it didn't go.
            backGaveUp = false
            await locationDidChange(here, hisMove: true)
        }
        // Sent more than once: the dropped try's report (the chapter's start) claimed Back's move and was
        // kept, and the landing's own report then read as layout. His page is kept here, once.
        else if !freed, backLanded, sends > 1, steps == jump, !isClosed, let here = page?.currentLocation { await locationDidChange(here, hisMove: true) }
    }
    /// The Back trip whose jump is out now (sent, not come back): only such a trip is ended by a move of his.
    @ObservationIgnored private var backGoOut: Int?
    /// Back trips whose veil let go at its limit while the trip went on (tests read it; gatefold#170).
    @ObservationIgnored private(set) var tripsPastTheVeil = 0
    /// The last Back trip gave up (its chapter never came): the pill says so until he taps it again,
    /// jumps somewhere else, or reads on until the pill goes.
    private(set) var backGaveUp = false
    /// The Back trip under way: a second tap meanwhile is not a second jump.
    @ObservationIgnored private var goingBack: Int?
    @ObservationIgnored private var backTrips = 0
    /// A Back trip freed by its count whose jump hasn't come back yet: its step and its chapter.
    @ObservationIgnored private var strayBack: (jump: Int, href: AnyURL)?
    /// A page in that trip's chapter may be the trip landing: no swipe or turn takes it as where it went.
    private func isStrayChapter(_ l: Locator) -> Bool { strayBack.map { $0.href == l.href } ?? false }
    var isGoingBack: Bool { goingBack != nil }
    /// One beat of the wait for Back's jump (a sleep, counted as `JumpLanding` counts its reads):
    /// `JumpLanding.reads` of them free Back again.
    @ObservationIgnored var backBeat: () async -> Void = { try? await Task.sleep(for: .milliseconds(200)) }
    /// Tests: a wait inside a place write, before it maps its position (a busy runner's slow mapper), so
    /// a newer move can be kept while an older one's write is still on its way.
    @ObservationIgnored var placeWriteWait: () async -> Void = {}

    /// `place` is earlier in the chapter of `page` than the page's start: his words are the first on a
    /// page, never before its start, so words there were read on a page he has since left.
    static func lies(_ place: Locator, before page: Locator) -> Bool {
        guard place.href == page.href, let at = place.locations.progression,
              let start = page.locations.progression else { return false }
        return at < start - 0.000_1
    }

    /// The page on screen, when "where he is" names an earlier place in its chapter: a `location` before
    /// the page's start is a place the page has since moved past. A report keeps `location` off such
    /// words (`locationDidChange`), but the page can move before its report comes in, and Back must not
    /// take him to the place he left (gatefold#143: Back took him to his chapter's first page). A page
    /// on screen before `location` (Readium naming a chapter still loading at its start) is the one that
    /// lags, and `location` stands.
    private func lagsBehindThePage() -> Locator? {
        // Mid-reflow or while the open settles, Readium's place is a guess and his held words stand.
        guard keeper.reflowing == nil, !openSettling,
              let location, let shown = page?.currentLocation, Self.lies(location, before: shown),
              let start = shown.locations.progression else { return nil }
        // His words, when the anchor was read on this page: they carry the words, the page's start doesn't.
        if let words = anchorLocator, words.href == shown.href, let w = words.locations.progression, abs(w - start) < 0.000_1 { return words }
        return shown
    }

    /// The place a jump leaves, held until the jump has moved the page: "Back to page" offered while
    /// the old page was still up (3.6 to 8.8 s on a cold Contents jump in build 19) read as a jump that
    /// had already happened. An earlier jump's way back goes down meanwhile; it isn't this jump's.
    private func rememberPlace(at here: Locator? = nil, keepingTheWayBack: Bool = false) -> Int {
        backJumps += 1
        let stale = here == nil ? lagsBehindThePage() : nil
        let remembered = here ?? stale ?? location
        // No page number: the counted one can still be the page before a jump within the chapter, and
        // Readium's positions aren't his pages. The pill says where it goes in words.
        pendingBack = (backJumps, remembered)
        // Where each way back starts, beside the page on screen and the place kept (gatefold#143: a Back
        // saved its chapter's start because the place it remembered was already that start). Tags only.
        let tag: (Locator?) -> String = { $0.map(Self.placeTag) ?? "none" }
        readerLog.notice("back: jump \(self.backJumps, privacy: .public) remembers \(tag(remembered), privacy: .public) (from \(here != nil ? "the page on screen" : stale != nil ? "the page on screen; where he is lagged at \(tag(self.location))" : "where he is", privacy: .public)); on screen \(tag(self.page?.currentLocation), privacy: .public); kept \(tag(self.app.library.book(self.bookID)?.locatorJSON.flatMap { try? Locator(jsonString: $0) }), privacy: .public)")
        if !keepingTheWayBack { backLocator = nil; backGaveUp = false }
        return backJumps
    }
    @ObservationIgnored private var backJumps = 0
    @ObservationIgnored private var pendingBack: (jump: Int, locator: Locator?)?

    /// The page on screen holds `place`: in its file, and (mid-file) in the page's range. Read a few
    /// times: a jump that has only just come back may not have painted yet.
    private func pageShows(_ place: Locator, reads: Int = JumpLanding.resendEvery, stillWanted: () -> Bool) async -> Bool {
        for _ in 0..<reads {
            if let inFile = place.locations.progression, inFile > 0 {
                if let range = await page?.pageRange(), range.contains(ReadingAnchor(href: place.href.string, progression: inFile, text: nil)) { return true }
            } else if page?.currentLocation?.href == place.href { return true }
            guard stillWanted() else { return false }
            await backBeat()
        }
        return false
    }

    /// Offers the way back once its jump has landed (a veiled jump returns once the new page has
    /// painted), and only for the newest jump: one overtaken by another offers nothing.
    private func publishBack(_ jump: Int?) {
        guard let jump, let pending = pendingBack, pending.jump == jump else {
            if let jump { readerLog.notice("back: jump \(jump, privacy: .public) superseded by \(self.pendingBack?.jump ?? -1, privacy: .public)") }
            return
        }
        pendingBack = nil
        backLocator = pending.locator
        holdJumpBack()
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
    /// The words of a page shown before its location is reported (a restore that left it unsettled).
    func probeShownPage(_ text: String) {
        guard LaunchOptions.isUITest, reopenPicture == nil, !isClosed else { return }
        visibleTextProbe = String(text.prefix(2400))
    }

    /// For UI tests: the words of the place his last move saved, so a test can tell a word's tail the
    /// place skipped (`ReaderJS.anchor`) from a page that skipped his place (`ReopenMatch`).
    private(set) var savedWordsProbe = ""
    /// UI tests: the file and the progression in it of the place last written by a move of his (no words).
    private(set) var savedPlaceProbe = ""
    /// UI tests: the same for the page Readium last reported, written or not.
    private(set) var shownPlaceProbe = ""
    private static func probeTag(_ l: Locator) -> String {
        (l.href.string.split(separator: "/").last.map(String.init) ?? "") + String(format: "@%.5f", l.locations.progression ?? -1)
    }

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
