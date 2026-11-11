import Foundation
import Testing
@testable import GatefoldCore

@Suite("The \"further ahead\" suggestion")
struct JumpSuggestionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func suggestsAJumpWhenTheOtherDeviceIsAheadAndNewer() {
        let local = ProgressSnapshot(totalProgression: 0.31, updated: now.addingTimeInterval(-3600), device: "iPhone")
        let remote = ProgressSnapshot(totalProgression: 0.42, updated: now, device: "InkPad 4")
        let s = try! #require(JumpSuggestion.make(local: local, remote: remote, totalPages: 500))
        #expect(s.headline == "Your e-reader is further ahead")
        #expect(s.detail == "Page 211 of 500. Jump there?")
        #expect(s.targetProgression == 0.42)
    }

    @Test func offersHisOwnPlaceByPageWhenThePagesAreCounted() {
        let s = JumpSuggestion.ownPlace(at: 0.31, page: 155)
        #expect(s.headline == "Where you stopped reading")
        #expect(s.detail == "Page 155. Jump there?")
        #expect(s.targetProgression == 0.31)
        #expect(JumpSuggestion.ownPlace(at: 0.31, page: nil).detail == "Jump there?")
    }

    @Test func staysQuietWhenTheOtherDeviceIsBehindOrOlderOrTheSame() {
        let a = ProgressSnapshot(totalProgression: 0.50, updated: now, device: "iPhone")
        #expect(JumpSuggestion.make(local: a, remote: .init(totalProgression: 0.40, updated: now.addingTimeInterval(60), device: "InkPad"), totalPages: nil) == nil)
        #expect(JumpSuggestion.make(local: a, remote: .init(totalProgression: 0.70, updated: now.addingTimeInterval(-60), device: "InkPad"), totalPages: nil) == nil)
        #expect(JumpSuggestion.make(local: a, remote: .init(totalProgression: 0.5005, updated: now.addingTimeInterval(60), device: "InkPad"), totalPages: nil) == nil)
        #expect(JumpSuggestion.make(local: a, remote: nil, totalPages: nil) == nil)
    }

    @Test func aBookNeverOpenedHereJumpsToTheOtherDevicesPlace() {
        let remote = ProgressSnapshot(totalProgression: 0.08, updated: now, device: "PocketBook InkPad 4")
        let s = try! #require(JumpSuggestion.make(local: nil, remote: remote, totalPages: nil))
        #expect(s.headline == "Your e-reader is further ahead")
        #expect(s.detail == "8% through. Jump there?")
    }

    @Test func namesTheDeviceKindPlainly() {
        #expect(JumpSuggestion.deviceKind("PocketBook InkPad 4") == "e-reader")
        #expect(JumpSuggestion.deviceKind("PB Era") == "e-reader")
        #expect(JumpSuggestion.deviceKind("Web reader") == "web reader")
        #expect(JumpSuggestion.deviceKind("") == "other device")
    }
}

@Suite("Scrubber and chapter math")
struct ChapterMapTests {
    private let map = ChapterMap(chapters: [
        .init(title: "Loomings", start: 0.0),
        .init(title: "The Carpet-Bag", start: 0.10),
        .init(title: "The Spouter-Inn", start: 0.25),
        .init(title: "The Counterpane", start: 0.60),
    ], positionCount: 1000)

    @Test func findsTheChapterAtAProgression() {
        #expect(map.chapterIndex(at: 0.0) == 0)
        #expect(map.chapterIndex(at: 0.099) == 0)
        #expect(map.chapterIndex(at: 0.10) == 1)
        #expect(map.chapterIndex(at: 0.99) == 3)
        #expect(map.chapter(at: 0.3)?.title == "The Spouter-Inn")
    }

    @Test func countsPagesLeftInTheChapter() {
        #expect(map.pagesLeftInChapter(at: 0.25) == 350)
        #expect(map.pagesLeftInChapter(at: 0.59) == 10)
        #expect(map.pagesLeftInChapter(at: 0.995) == 5)
    }

    @Test func pageLabelIsOneBased() {
        #expect(map.page(at: 0.0) == 1)
        #expect(map.page(at: 0.5) == 501)
        #expect(map.page(at: 1.0) == 1000)
    }

    @Test func reportsChapterCrossingsForTheScrubberHaptic() {
        #expect(map.crossesChapter(from: 0.09, to: 0.11))
        #expect(!map.crossesChapter(from: 0.11, to: 0.2))
    }

    @Test func ticksAreTheChapterStartsAfterTheFirst() {
        #expect(map.ticks == [0.10, 0.25, 0.60])
    }

    @Test func unsortedChaptersAreSorted() {
        let m = ChapterMap(chapters: [.init(title: "B", start: 0.5), .init(title: "A", start: 0)], positionCount: 10)
        #expect(m.chapters.map(\.title) == ["A", "B"])
    }
}

@Suite("Bookmarks")
struct BookmarkTests {
    @Test func aBookmarkOnScreenMarksThePage() {
        var list = BookmarkList()
        let here = VisibleRange(href: "c3.xhtml", start: 0.2, end: 0.3)
        #expect(!list.isMarked(here))
        let mark = list.toggle(at: ReadingAnchor(href: "c3.xhtml", progression: 0.2, text: "Call me"), visible: here, title: "Loomings", totalProgression: 0.12)
        #expect(mark == .added)
        #expect(list.isMarked(here))
        #expect(!list.isMarked(VisibleRange(href: "c3.xhtml", start: 0.3, end: 0.4)))
    }

    @Test func togglingAgainRemovesEveryBookmarkOnThePage() {
        var list = BookmarkList()
        let here = VisibleRange(href: "c3.xhtml", start: 0.2, end: 0.3)
        _ = list.toggle(at: ReadingAnchor(href: "c3.xhtml", progression: 0.21, text: nil), visible: here, title: "", totalProgression: 0.1)
        #expect(list.toggle(at: ReadingAnchor(href: "c3.xhtml", progression: 0.2, text: nil), visible: here, title: "", totalProgression: 0.1) == .removed)
        #expect(list.items.isEmpty)
    }

    @Test func bookmarksSortInReadingOrder() {
        var list = BookmarkList()
        _ = list.toggle(at: .init(href: "b", progression: 0.5, text: nil), visible: .init(href: "b", start: 0.5, end: 0.6), title: "", totalProgression: 0.7)
        _ = list.toggle(at: .init(href: "a", progression: 0.1, text: nil), visible: .init(href: "a", start: 0.1, end: 0.2), title: "", totalProgression: 0.2)
        #expect(list.items.map(\.totalProgression) == [0.2, 0.7])
    }
}

@Suite("Reading Now shelf")
struct ReadingNowTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func showsStartedUnfinishedBooksNewestFirst() {
        let items = [
            ShelfItem(id: "a", progression: 0.0, lastOpened: nil),
            ShelfItem(id: "b", progression: 0.3, lastOpened: t0),
            ShelfItem(id: "c", progression: 1.0, lastOpened: t0.addingTimeInterval(100)),
            ShelfItem(id: "d", progression: 0.6, lastOpened: t0.addingTimeInterval(50)),
        ]
        #expect(ReadingNow.shelf(items).map(\.id) == ["d", "b"])
    }

    @Test func theNewestOfThisDeviceAndTheOtherDecides() {
        let items = [
            ShelfItem(id: "phone", progression: 0.3, lastOpened: t0),
            ShelfItem(id: "inkpad", progression: 0.2, lastOpened: t0.addingTimeInterval(-500), remoteUpdated: t0.addingTimeInterval(500)),
        ]
        #expect(ReadingNow.shelf(items).map(\.id) == ["inkpad", "phone"])
    }

    @Test func caps() {
        let items = (0..<20).map { ShelfItem(id: "\($0)", progression: 0.5, lastOpened: t0.addingTimeInterval(Double($0))) }
        #expect(ReadingNow.shelf(items, limit: 8).count == 8)
    }
}

@Suite("Chapters that share a file")
struct SharedFileChapterTests {
    // Gutenberg packs several chapters into one file, so their known starts are the same.
    let map = ChapterMap(chapters: [
        .init(title: "Chapter I", start: 0),
        .init(title: "Chapter XVIII", start: 0.3),
        .init(title: "Chapter XIX", start: 0.3),
        .init(title: "Chapter XX", start: 0.3),
        .init(title: "Chapter XXI", start: 0.4),
    ], positionCount: 300)

    @Test func aPageInTheSharedFileNamesItsFirstChapterNotTheLast() {
        #expect(map.chapter(at: 0.31)?.title == "Chapter XVIII")
        #expect(map.chapter(at: 0.41)?.title == "Chapter XXI")
    }

    @Test func pagesLeftRunToTheNextFileNotTheNextSharedChapter() {
        #expect(map.pagesLeftInChapter(at: 0.31) == 27)
    }
}

/// One definition per number: `totalProgression` is Readium's whole-book scale, the page is
/// `ChapterMap.page(at:)`, and every whole percent (the Cloud's `offs`/`read_percent`, the shelf, the
/// banner) is `ReadingPercent.whole`, PocketBook's own `ceil(100 × progress)`.
@Suite("Percents and pages")
struct ReadingPercentTests {
    @Test func aWholePercentIsPocketBooksCeiling() {
        #expect(ReadingPercent.whole(0) == 0)
        #expect(ReadingPercent.whole(0.0861) == 9)
        #expect(ReadingPercent.whole(0.001) == 1, "a started book never reads 0%")
        #expect(ReadingPercent.whole(1) == 100)
        #expect(ReadingPercent.whole(1.4) == 100)
        #expect(ReadingPercent.whole(-0.2) == 0)
        #expect(ReadingPercent.whole(.nan) == 0)
    }

    @Test func floatingPointNoiseNeverAddsAPercent() {
        // 0.07 × 100 is 7.000000000000001 in binary floating point; a plain ceil says 8.
        for whole in 0...100 {
            #expect(ReadingPercent.whole(Double(whole) / 100) == whole, "\(whole)%")
        }
    }

    @Test func aCloudPercentReadsBackAsTheSameWholePercent() {
        for whole in 0...100 {
            #expect(ReadingPercent.whole(ReadingPercent.fraction(Double(whole))) == whole)
        }
        #expect(ReadingPercent.fraction(250) == 1)
        #expect(ReadingPercent.fraction(-3) == 0)
    }

    @Test func theBannerNamesTheSamePageAndPercentAsTheReader() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let map = ChapterMap(chapters: [], positionCount: 212)
        for p in [0.0, 0.07, 0.2641, 0.5, 0.999, 1.0] {
            let remote = ProgressSnapshot(totalProgression: max(p, 0.003), updated: now, device: "web")
            let paged = try! #require(JumpSuggestion.make(local: nil, remote: remote, totalPages: 212))
            #expect(paged.detail == "Page \(map.page(at: remote.totalProgression)) of 212. Jump there?")
            let percent = try! #require(JumpSuggestion.make(local: nil, remote: remote, totalPages: nil))
            #expect(percent.detail == "\(ReadingPercent.whole(remote.totalProgression))% through. Jump there?")
        }
    }

    @Test func ourOwnPercentReadBackIsNotFurtherAhead() {
        // We push 30.1% as the Cloud's 31; reading 31% back is the same place, not a page ahead.
        let local = 0.301
        let readBack = ReadingPercent.fraction(Double(ReadingPercent.whole(local)))
        #expect(!JumpSuggestion.isAhead(remote: readBack, percentOnly: true, local: local))
        #expect(JumpSuggestion.isAhead(remote: ReadingPercent.fraction(32), percentOnly: true, local: local))
        // An exact place compares on the fine scale.
        #expect(JumpSuggestion.isAhead(remote: 0.31, percentOnly: false, local: local))
        #expect(!JumpSuggestion.isAhead(remote: 0.302, percentOnly: false, local: local))
    }

    @Test func aPercentOnlyPlaceIsOfferedOnlyWhenItsPercentIsAhead() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let local = ProgressSnapshot(totalProgression: 0.301, updated: now, device: "iPhone")
        let same = ProgressSnapshot(totalProgression: 0.31, updated: now.addingTimeInterval(60), device: "InkPad")
        #expect(JumpSuggestion.make(local: local, remote: same, totalPages: nil, remotePercentOnly: true) == nil)
        #expect(JumpSuggestion.make(local: local, remote: same, totalPages: nil) != nil, "an exact place 0.9% on is a few pages on")
    }
}
