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
    let title: String
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
    private var readingOrderHrefs: [String] = []
    private var resourceStarts: [Double] = []
    /// The contents anchor above the first line on screen (from the web view).
    var contentsFragment: String?
    /// Where the reader was before a jump, so Back can return there.
    private(set) var backLocator: Locator?
    private(set) var backPage: Int?
    var errorMessage: String?
    /// Set once the reader has settled after a reflow (for UI tests): whether the anchor is on screen.
    private(set) var anchorCheck = "pending 0"
    /// For UI tests: what the last check compared.
    private(set) var anchorDetail = ""

    var keeper = AnchorKeeper()
    private var anchorLocator: Locator?
    private var pendingReflowReason: ReflowReason?
    weak var host: ReaderHostController?
    private(set) var hostController: ReaderHostController?
    /// This device's place when the book was opened, for the "further ahead" comparison.
    private let openedSnapshot: ProgressSnapshot?
    /// Where the book opened; nothing is recorded or pushed until the reader moves from it,
    /// so opening a book never overwrites a further-ahead place on the other device.
    private var hasMoved = false
    /// The saved place, with the first words that were on screen.
    private let initialLocator: Locator?
    /// Page turns the reader has made, so a settling jump never pulls them back.
    private var turns = 0

    init(book: LibraryBook, publication: Publication, app: AppModel) {
        self.bookID = book.id
        self.title = publication.metadata.title ?? book.title
        self.publication = publication
        self.app = app
        self.bookmarks = book.bookmarks
        self.openedSnapshot = book.localSnapshot
        let initial = book.locatorJSON.flatMap { try? Locator(jsonString: $0) }
        self.initialLocator = initial
        let prefs = app.preferences.effective(for: book.id)
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
        toc = entries
        readingOrderHrefs = publication.readingOrder.map { $0.url().removingFragment().string }
        resourceStarts = readingOrderHrefs.map { starts[$0] ?? 0 }
        contents = ContentsIndex(
            entries: entries.map { .init(title: $0.title, href: $0.link.url().removingFragment().string, fragment: $0.link.url().fragment, level: $0.level) },
            readingOrder: readingOrderHrefs
        )
        mapper = await BookPositions.mapper(for: publication)
        chapterMap = ChapterMap(chapters: entries.filter { $0.level == 0 }.map { .init(title: $0.title, start: $0.progression) }, positionCount: max(1, count))

        // The first page can take seconds to lay out on a cold web view; nothing below means anything
        // until the navigator reports where it is.
        await waitForLocation()
        if LaunchOptions.goTo == nil, let initialLocator { await settle(on: initialLocator) }
        if let goTo = LaunchOptions.goTo, let locator = await publication.locate(progression: goTo) {
            hasMoved = true
            // Readium refuses a jump while it is still loading; try until it takes.
            var tries = 0
            while await host?.go(to: locator) != true, tries < 50 {
                tries += 1
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        try? await Task.sleep(for: .milliseconds(300))
        await captureAnchor()
        await checkRemote()
    }

    private func waitForLocation() async {
        for _ in 0..<150 where host?.navigator.currentLocation == nil {
            try? await Task.sleep(for: .milliseconds(200))
        }
        if location == nil { location = host?.navigator.currentLocation }
    }

    /// Ask the other device where it is; offer a jump if it's further ahead.
    func checkRemote() async {
        // Our own place coming back is not news.
        guard let book = app.library.book(bookID), let remote = await app.library.remotePosition(for: book),
              remote.source != .gatefold else { return }
        let target = await place(of: remote)
        guard target.totalProgression > totalProgression + JumpSuggestion.threshold else { return }
        // First time this book opens here: there's no place of ours to protect, so just open where
        // the InkPad is, like picking the book up off the nightstand.
        if openedSnapshot == nil, !hasMoved {
            readerLog.notice("first open: landing on the Cloud place \(remote.pointer ?? "no pointer", privacy: .public)")
            await land(on: target.locator, progression: target.totalProgression, rememberBack: false)
            return
        }
        let made = JumpSuggestion.make(
            local: hasMoved ? app.library.book(bookID)?.localSnapshot : openedSnapshot,
            remote: ProgressSnapshot(totalProgression: target.totalProgression, updated: remote.updated, device: remote.deviceName),
            totalPages: chapterMap.positionCount > 1 ? chapterMap.positionCount : nil
        )
        guard let made else { return }
        readerLog.notice("remote ahead: \(remote.pointer ?? "no pointer", privacy: .public) → \(target.locator?.text.highlight ?? "no text", privacy: .private)")
        suggestionLocator = target.locator
        withAnimation(Motion.banner) { suggestion = made }
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
        guard let s = suggestion else { return }
        withAnimation(Motion.banner) { suggestion = nil }
        await land(on: suggestionLocator, progression: s.targetProgression, rememberBack: true)
        suggestionLocator = nil
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Goes to another device's place: the exact spot when its CFI resolved, else its percent.
    private func land(on locator: Locator?, progression: Double, rememberBack: Bool) async {
        guard let locator else {
            await go(toProgression: progression, rememberBack: rememberBack)
            return
        }
        hasMoved = true
        if rememberBack { rememberPlace() }
        await host?.go(to: locator)
        // Opening another chapter, Readium places the page by progression before the chapter has laid
        // out; once it has, the same jump finds the exact words. Retry until they're on screen.
        await settle(on: locator)
        await captureAnchor()
        // Landed on the other device's page: that's the reader's place now.
        if let here = host?.navigator.currentLocation { await locationDidChange(here) }
    }

    /// Readium places the page by its own progression, which counts layout, not text; once the
    /// chapter is on screen, find the locator's words in it and turn to their page.
    private func settle(on locator: Locator) async {
        guard let words = locator.text.highlight.map(ReaderJS.normalize), words.count >= 8 else { return }
        let probe = String(words.prefix(24))
        let turnsBefore = turns
        for _ in 0..<4 {
            try? await Task.sleep(for: .milliseconds(250))
            // The reader has turned a page meanwhile: where they are now is theirs, not ours to fix.
            guard turns == turnsBefore else { return }
            let onScreen = await host?.visibleRange()?.text.map(ReaderJS.normalize) ?? ""
            if onScreen.contains(probe) { return }
            guard let exact = await host?.progression(of: words) else { continue }
            _ = await host?.go(to: locator.copy(locations: { $0.progression = exact }, text: { $0 = Locator.Text() }))
        }
    }

    func dismissSuggestion() {
        suggestionLocator = nil
        withAnimation(Motion.banner) { suggestion = nil }
    }

    // MARK: Layout

    func updateLayout(_ new: ReaderLayout, reason: ReflowReason) {
        guard new != layout else { return }
        readerLog.notice("layout \(new.posture.rawValue, privacy: .public) \(new.pageFrame.width, privacy: .public)x\(new.pageFrame.height, privacy: .public)")
        let columnsChanged = new.columns != layout.columns
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
        location = locator
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
        guard hasMoved else { return refreshBookmarkState(await host?.visibleRange()) }
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
        refreshBookmarkState(await host?.visibleRange())
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
        turns += 1
        Task {
            guard let first = host?.navigator.currentLocation else { return }
            await locationDidChange(first)
            // Turning into the next resource, Readium can name the old one until the new one has
            // loaded, and its update arrives mid-turn when it's ignored. Look again once it has.
            try? await Task.sleep(for: .milliseconds(700))
            if let later = host?.navigator.currentLocation, later.href != first.href
                || later.locations.progression != first.locations.progression {
                await locationDidChange(later)
            }
        }
    }

    /// Takes the first words on screen as the reader's place, unless a reflow is moving the page.
    func captureAnchor() async {
        guard keeper.reflowing == nil, let (anchor, anchorLoc) = await host?.currentAnchor(), keeper.reflowing == nil else { return }
        readerLog.notice("anchor \(anchor.text ?? "nil", privacy: .private)")
        keeper.userSettled(on: anchor)
        if keeper.anchor == anchor { anchorLocator = anchorLoc }
        if anchorCheck == "pending 0", anchor.text != nil { anchorCheck = "ready 0" }
    }

    // MARK: Chrome

    func setChrome(_ visible: Bool) {
        withAnimation(Motion.chrome) { chromeVisible = visible }
    }

    // MARK: Jumps

    func go(toProgression progression: Double, rememberBack: Bool) async {
        hasMoved = true
        if rememberBack { rememberPlace() }
        if let locator = await publication.locate(progression: progression) {
            await host?.go(to: locator)
            await captureAnchor()
        }
    }

    func go(to entry: TOCEntry) async {
        hasMoved = true
        rememberPlace()
        await host?.go(to: entry.link)
        await captureAnchor()
    }

    func go(to bookmark: Bookmark) async {
        rememberPlace()
        await go(toProgression: bookmark.totalProgression, rememberBack: false)
    }

    func goBack() async {
        guard let back = backLocator else { return }
        hasMoved = true
        backLocator = nil
        await host?.go(to: back)
        await captureAnchor()
    }

    private func rememberPlace() {
        backLocator = location
        backPage = chapterMap.page(at: totalProgression)
    }

    // MARK: Bookmarks

    func toggleBookmark() async {
        guard let host, let (anchor, _) = await host.currentAnchor(), let visible = await host.visibleRange() else { return }
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
        Task { refreshBookmarkState(await host?.visibleRange()) }
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
            Self.epubPreferences(prefs, theme: theme, columns: layout.columns),
            columns: layout.columns == .two ? 2 : 1,
            reflow: reflow
        )
        host?.disablePanningIfNeeded()
    }

    static func epubPreferences(_ prefs: ReaderPreferences, theme: ReaderTheme, columns: GatefoldCore.ColumnCount) -> EPUBPreferences {
        let custom = prefs.font != .original || prefs.lineSpacing != .normal || prefs.justify
        return EPUBPreferences(
            backgroundColor: ReadiumNavigator.Color(hex: ThemePalette.hexString(theme.palette.background)),
            columnCount: columns == .two ? .two : .one,
            fontFamily: prefs.font.cssFamily.map { FontFamily(rawValue: $0) },
            fontSize: prefs.fontScale,
            hyphens: prefs.justify ? true : nil,
            lineHeight: custom ? prefs.lineSpacing.lineHeight : nil,
            pageMargins: prefs.margins.factor,
            publisherStyles: !custom,
            scroll: prefs.pageTurn == .scroll,
            textAlign: prefs.justify ? .justify : nil,
            textColor: ReadiumNavigator.Color(hex: ThemePalette.hexString(theme.palette.text)),
            theme: theme.palette.isDark ? .dark : .light
        )
    }
}
