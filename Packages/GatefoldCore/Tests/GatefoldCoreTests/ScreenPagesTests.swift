import Foundation
import Testing
@testable import GatefoldCore

/// Page numbers are the pages he sees, as in Apple Books: every turn moves on, a spread shows two
/// numbers in a row, and the same layout always numbers the same page the same way. Build 16 took
/// them from Readium's positions (about 1,024 characters each), so one number covered three or four
/// turns on the folded Duo and two spreads on the iPad.
struct ScreenPagesTests {
    private let order = ["ch1.xhtml", "ch2.xhtml", "ch3.xhtml"]
    /// Columns each chapter lays out to (a chapter's last column can be short).
    private let columns = ["ch1.xhtml": 5, "ch2.xhtml": 3, "ch3.xhtml": 8]

    private func layout(columns perScreen: Int, width: Double = 466, fontScale: Double = 1.3) -> ScreenPageLayout {
        ScreenPageLayout(width: width, height: 631.67, columnsPerScreen: perScreen, fontScale: fontScale,
                         lineHeight: 1.5, margins: 0.06, font: "original", justify: true)
    }

    private func counted(_ layout: ScreenPageLayout) -> ScreenPageMap {
        var map = ScreenPageMap(book: "alice", layout: layout, readingOrder: order)
        for (href, n) in columns { map.record(href: href, columns: n) }
        return map
    }

    /// Every screen of the book in reading order, as (href, first column shown), the way turns walk it.
    private func screens(_ map: ScreenPageMap) -> [(String, Int)] {
        let step = map.layout.columnsPerScreen
        return order.flatMap { href in stride(from: 0, to: map.pages(of: href)!, by: step).map { (href, $0) } }
    }

    @Test func everyTurnOnASinglePageMovesOnOnePage() throws {
        let map = counted(layout(columns: 1))
        let shown = try screens(map).map { try #require(map.numbers(href: $0.0, column: $0.1)) }
        #expect(shown.first == [1])
        for (a, b) in zip(shown, shown.dropFirst()) { #expect(b[0] == a[0] + 1, "\(a) then \(b)") }
        #expect(shown.last == [16])
        #expect(map.total == 16)
    }

    @Test func everyTurnOnASpreadMovesOnTwoAndItsNumbersAreConsecutive() throws {
        let map = counted(layout(columns: 2, width: 1376))
        let shown = try screens(map).map { try #require(map.numbers(href: $0.0, column: $0.1)) }
        #expect(shown.first == [1, 2])
        for spread in shown { #expect(spread.count == 2 && spread[1] == spread[0] + 1, "\(spread)") }
        for (a, b) in zip(shown, shown.dropFirst()) { #expect(b[0] == a[0] + 2, "\(a) then \(b)") }
        // A chapter of 5 columns ends on a spread whose right page is blank; it still counts, so the
        // next chapter opens on a left page with the next odd number.
        #expect(map.numbers(href: "ch2.xhtml", column: 0) == [7, 8])
        #expect(map.isBlank(href: "ch1.xhtml", column: 5))
        #expect(!map.isBlank(href: "ch1.xhtml", column: 4))
    }

    @Test func nothingIsShownUntilEveryEarlierChapterIsCounted() {
        var map = ScreenPageMap(book: "alice", layout: layout(columns: 1), readingOrder: order)
        map.record(href: "ch3.xhtml", columns: 8)
        #expect(map.numbers(href: "ch3.xhtml", column: 2) == nil, "ch1 and ch2 not counted yet")
        map.record(href: "ch1.xhtml", columns: 5)
        #expect(map.numbers(href: "ch1.xhtml", column: 2) == [3], "the first chapter needs nothing before it")
        #expect(map.numbers(href: "ch3.xhtml", column: 2) == nil)
        #expect(!map.isComplete)
        map.record(href: "ch2.xhtml", columns: 3)
        #expect(map.numbers(href: "ch3.xhtml", column: 2) == [11])
        #expect(map.isComplete)
    }

    @Test func aColumnPastTheChapterOrAnUnknownChapterShowsNothing() {
        let map = counted(layout(columns: 1))
        #expect(map.numbers(href: "ch2.xhtml", column: 3) == nil)
        #expect(map.numbers(href: "appendix.xhtml", column: 0) == nil)
        #expect(map.numbers(href: "ch2.xhtml", column: -1) == nil)
    }

    @Test func aReopenAtTheSameLayoutShowsTheSameNumbers() throws {
        let map = counted(layout(columns: 2, width: 1376))
        let saved = try JSONEncoder().encode(map)
        let reopened = try JSONDecoder().decode(ScreenPageMap.self, from: saved)
        #expect(reopened == map)
        #expect(reopened.numbers(href: "ch3.xhtml", column: 4) == map.numbers(href: "ch3.xhtml", column: 4))
        #expect(reopened.numbers(href: "ch3.xhtml", column: 4) == [15, 16])
        #expect(reopened.fits(layout(columns: 2, width: 1376)))
    }

    @Test func anotherLayoutOrTypeSizeNeedsItsOwnCount() {
        let map = counted(layout(columns: 1))
        #expect(map.fits(layout(columns: 1)))
        #expect(!map.fits(layout(columns: 2, width: 466)), "a spread")
        #expect(!map.fits(layout(columns: 1, width: 500)), "another width")
        #expect(!map.fits(layout(columns: 1, fontScale: 1.4)), "a larger type size")
        // Sub-point noise in a measured frame is the same layout.
        #expect(map.fits(ScreenPageLayout(width: 466.04, height: 631.6666, columnsPerScreen: 1, fontScale: 1.3,
                                          lineHeight: 1.5, margins: 0.06, font: "original", justify: true)))
        #expect(layout(columns: 1).key != layout(columns: 1, fontScale: 1.4).key)
    }

    @Test func aRecountOfAChapterReplacesItsCount() {
        var map = counted(layout(columns: 1))
        map.record(href: "ch1.xhtml", columns: 6)
        #expect(map.numbers(href: "ch2.xhtml", column: 0) == [7])
        // A count of nothing (a web view not laid out yet) is not a count.
        map.record(href: "ch2.xhtml", columns: 0)
        #expect(map.pages(of: "ch2.xhtml") == 3)
    }

    /// The live page's geometry, read from the web view: the chapter's width in columns and the
    /// column at the left edge of the screen.
    @Test func theWebViewsGeometryNamesColumns() {
        // A folded Duo page 466 pt wide, scrolled to its fourth column of seven.
        let single = ScreenPageGeometry(scrollWidth: 3262, scrollLeft: 1398, viewportWidth: 466, columnsPerScreen: 1)
        #expect(single.columns == 7 && single.column == 3)
        // An iPad spread: two columns a screen, the chapter 5 columns wide padded to 6.
        let spread = ScreenPageGeometry(scrollWidth: 4128, scrollLeft: 2752, viewportWidth: 1376, columnsPerScreen: 2)
        #expect(spread.columns == 6 && spread.column == 4)
        // Sub-pixel scroll offsets round to the column.
        let near = ScreenPageGeometry(scrollWidth: 3262, scrollLeft: 1397.6, viewportWidth: 466, columnsPerScreen: 1)
        #expect(near.column == 3)
    }

    /// A place elsewhere in the book (a contents entry, a bookmark, the scrubber) gets the number of
    /// the page it falls on, so every label agrees with the page numbers.
    @Test func aPlaceInAChapterHasThePageItFallsOn() {
        let single = counted(layout(columns: 1))
        #expect(single.number(href: "ch2.xhtml", progression: 0) == 6)
        #expect(single.number(href: "ch2.xhtml", progression: 0.5) == 7)
        #expect(single.number(href: "ch2.xhtml", progression: 1) == 8, "the end is the last page, not past it")
        let spread = counted(layout(columns: 2, width: 1376))
        #expect(spread.number(href: "ch3.xhtml", progression: 0.3) == 13)
        var partial = ScreenPageMap(book: "alice", layout: layout(columns: 1), readingOrder: order)
        partial.record(href: "ch2.xhtml", columns: 3)
        #expect(partial.number(href: "ch2.xhtml", progression: 0.5) == nil)
    }

    @Test func pagesLeftInTheChapterCountScreenPages() {
        let single = counted(layout(columns: 1))
        #expect(single.pagesLeft(href: "ch1.xhtml", column: 2) == 2)
        #expect(single.pagesLeft(href: "ch1.xhtml", column: 4) == 0)
        let spread = counted(layout(columns: 2, width: 1376))
        // Spread at ch3 columns 4-5 of 8: columns 6 and 7 are left.
        #expect(spread.pagesLeft(href: "ch3.xhtml", column: 4) == 2)
        #expect(spread.pagesLeft(href: "ch1.xhtml", column: 4) == 0, "only the blank page is left")
        #expect(counted(layout(columns: 1)).pagesLeft(href: "nowhere.xhtml", column: 0) == nil)
    }

    /// After an unfold Gatefold slips a blank verso before the chapter (or starts a column at his
    /// sentence) so his words open the left page. Those columns aren't the chapter's: the chapter's
    /// count comes only from a clean layout, and the verso page has no number.
    @Test func theUnfoldsBlankVersoHasNoNumberAndTheRestStayConsecutive() throws {
        let map = counted(layout(columns: 2, width: 1376))
        // ch3 (8 columns) with the verso in: 9 columns, the spread at columns 0-1 is verso + page 1.
        let open = ScreenPageGeometry(scrollWidth: 6880, scrollLeft: 0, viewportWidth: 1376, columnsPerScreen: 2, verso: true)
        #expect(!open.isClean)
        #expect(map.screen(href: "ch3.xhtml", geometry: open) == [nil, 11])
        let next = ScreenPageGeometry(scrollWidth: 6880, scrollLeft: 1376, viewportWidth: 1376, columnsPerScreen: 2, verso: true)
        #expect(map.screen(href: "ch3.xhtml", geometry: next) == [12, 13])
        // The live chapter is counted only when it is clean.
        var fresh = ScreenPageMap(book: "alice", layout: layout(columns: 2, width: 1376), readingOrder: order)
        fresh.record(href: "ch1.xhtml", geometry: open)
        #expect(fresh.pages(of: "ch1.xhtml") == nil)
        fresh.record(href: "ch1.xhtml", geometry: ScreenPageGeometry(scrollWidth: 3440, scrollLeft: 0, viewportWidth: 1376, columnsPerScreen: 2))
        #expect(fresh.pages(of: "ch1.xhtml") == 6)
    }

    @Test func aCleanScreenMatchesItsColumnsAndATrailingBlankHasNoNumber() {
        let map = counted(layout(columns: 2, width: 1376))
        let end = ScreenPageGeometry(scrollWidth: 4128, scrollLeft: 2752, viewportWidth: 1376, columnsPerScreen: 2)
        #expect(map.screen(href: "ch1.xhtml", geometry: end) == [5, nil])
        let single = counted(layout(columns: 1))
        let mid = ScreenPageGeometry(scrollWidth: 1398, scrollLeft: 466, viewportWidth: 466, columnsPerScreen: 1)
        #expect(single.screen(href: "ch2.xhtml", geometry: mid) == [7])
        var partial = ScreenPageMap(book: "alice", layout: layout(columns: 1), readingOrder: order)
        partial.record(href: "ch2.xhtml", columns: 3)
        #expect(partial.screen(href: "ch2.xhtml", geometry: mid) == nil)
    }

    /// Counts are kept per book and layout, so a reopen numbers his page at once, the same as before.
    @Test func countsAreKeptPerBookAndLayout() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "screen-pages-\(UUID().uuidString)")
        let store = ScreenPageStore(directory: dir)
        let single = layout(columns: 1)
        store.save(counted(single))
        let reopened = store.load(book: "alice", layout: single, readingOrder: order)
        #expect(reopened == counted(single))
        #expect(reopened.numbers(href: "ch3.xhtml", column: 4) == [13])
        #expect(store.load(book: "alice", layout: layout(columns: 1, fontScale: 1.4), readingOrder: order).columns.isEmpty)
        #expect(store.load(book: "bob", layout: single, readingOrder: order).columns.isEmpty)
        #expect(store.load(book: "alice", layout: single, readingOrder: ["ch1.xhtml"]).columns.isEmpty, "another edition")
    }

}
