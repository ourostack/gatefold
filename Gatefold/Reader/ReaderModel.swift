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
    /// Where the reader was before a jump, so Back can return there.
    private(set) var backLocator: Locator?
    private(set) var backPage: Int?
    var errorMessage: String?
    /// Set once the reader has settled after a reflow (for UI tests): whether the anchor is on screen.
    private(set) var anchorCheck = "pending 0"

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

    init(book: LibraryBook, publication: Publication, app: AppModel) {
        self.bookID = book.id
        self.title = publication.metadata.title ?? book.title
        self.publication = publication
        self.app = app
        self.bookmarks = book.bookmarks
        self.openedSnapshot = book.localSnapshot
        let initial = book.locatorJSON.flatMap { try? Locator(jsonString: $0) }
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
    var chapterTitle: String? { chapterMap.chapter(at: totalProgression)?.title ?? location?.title }
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
        chapterMap = ChapterMap(chapters: entries.filter { $0.level == 0 }.map { .init(title: $0.title, start: $0.progression) }, positionCount: max(1, count))

        if let goTo = LaunchOptions.goTo, let locator = await publication.locate(progression: goTo) {
            hasMoved = true
            await host?.go(to: locator)
        }
        try? await Task.sleep(for: .milliseconds(300))
        await captureAnchor()
        await checkRemote()
    }

    /// Ask the other device where it is; offer a jump if it's further ahead.
    func checkRemote() async {
        guard let book = app.library.book(bookID), let remote = await app.library.remotePosition(for: book),
              remote.totalProgression > totalProgression + JumpSuggestion.threshold else { return }
        let made = JumpSuggestion.make(
            local: hasMoved ? app.library.book(bookID)?.localSnapshot : openedSnapshot,
            remote: ProgressSnapshot(totalProgression: remote.totalProgression, updated: remote.updated, device: remote.device),
            totalPages: chapterMap.positionCount > 1 ? chapterMap.positionCount : nil
        )
        withAnimation(Motion.banner) { suggestion = made }
    }

    func acceptSuggestion() async {
        guard let s = suggestion else { return }
        withAnimation(Motion.banner) { suggestion = nil }
        await go(toProgression: s.targetProgression, rememberBack: true)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    func dismissSuggestion() {
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
        }
        // Only the reader moves the place. Readium reopening a page boundary off from the saved one is
        // not a move, so opening a book never overwrites a further-ahead place on the InkPad.
        guard hasMoved else { return refreshBookmarkState(await host?.visibleRange()) }
        if let json = try? locator.jsonString() {
            app.library.recordPlace(
                bookID: bookID,
                locatorJSON: json,
                totalProgression: locator.locations.totalProgression ?? 0,
                progression: locator.locations.progression ?? 0
            )
        }
        refreshBookmarkState(await host?.visibleRange())
        if let back = backLocator, abs((back.locations.totalProgression ?? 0) - totalProgression) < 0.0001 {
            backLocator = nil
        }
    }

    /// A touch on the page (a swipe in slide or scroll mode): the next location is the reader's own.
    func noteInteraction() { hasMoved = true }

    /// A turn landed or sprang back: take the place from where the navigator is now.
    func userTurnedPage() {
        hasMoved = true
        Task {
            guard let location = host?.navigator.currentLocation else { return }
            await locationDidChange(location)
        }
    }

    /// Takes the first words on screen as the reader's place, unless a reflow is moving the page.
    func captureAnchor() async {
        guard keeper.reflowing == nil, let (anchor, anchorLoc) = await host?.currentAnchor(), keeper.reflowing == nil else { return }
        readerLog.notice("anchor \(anchor.text ?? "nil", privacy: .public)")
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

    private func refreshBookmarkState(_ visible: VisibleRange?) {
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
