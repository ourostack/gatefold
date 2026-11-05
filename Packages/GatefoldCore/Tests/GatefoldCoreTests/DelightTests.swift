#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import Testing
@testable import GatefoldCore

private typealias E = ContentsIndex.Entry

@Suite("Contents read like a book's, not like metadata")
struct ContentsCleanerTests {
    @Test func frankensteinStartsAtLetterOne() {
        let entries: [E] = [
            .init(title: "Frankenstein;", href: "h-0.xhtml", fragment: "a", level: 0),
            .init(title: "or, the Modern Prometheus", href: "h-0.xhtml", fragment: "b", level: 0),
            .init(title: "CONTENTS", href: "h-1.xhtml", fragment: "c", level: 0),
            .init(title: "Letter 1", href: "h-2.xhtml", fragment: "d", level: 0),
            .init(title: "Chapter 1", href: "h-6.xhtml", fragment: "e", level: 0),
            .init(title: "THE FULL PROJECT GUTENBERG™ LICENSE", href: "h-30.xhtml", fragment: "f", level: 0),
        ]
        let kept = ContentsCleaner.clean(entries, bookTitle: "Frankenstein; or, The modern Prometheus")
        #expect(kept.map(\.title) == ["Letter 1", "Chapter 1"])
        #expect(kept.map(\.index) == [3, 4])
    }

    @Test func spacedOutTitlesAndTitlePagesGo() {
        let entries: [E] = [
            .init(title: "D R A C U L A", href: "h-0.xhtml", fragment: nil, level: 0),
            .init(title: "Contents", href: "h-1.xhtml", fragment: nil, level: 0),
            .init(title: "D R A C U L A", href: "h-3.xhtml", fragment: "x", level: 0),
            .init(title: "CHAPTER I JONATHAN HARKER’S JOURNAL", href: "h-3.xhtml", fragment: "y", level: 0),
            .init(title: "NOTE", href: "h-30.xhtml", fragment: nil, level: 0),
        ]
        let kept = ContentsCleaner.clean(entries, bookTitle: "Dracula")
        #expect(kept.map(\.title) == ["Chapter I Jonathan Harker’s Journal", "Note"])
    }

    @Test func frontMatterBeforeTheFirstChapterGoes() {
        let entries: [E] = [
            .init(title: "Alice’s Adventures in Wonderland", href: "h-0.xhtml", fragment: "a", level: 0),
            .init(title: "THE MILLENNIUM FULCRUM EDITION 3.0", href: "h-0.xhtml", fragment: "b", level: 0),
            .init(title: "Contents", href: "h-0.xhtml", fragment: "c", level: 0),
            .init(title: "CHAPTER I. Down the Rabbit-Hole", href: "h-1.xhtml", fragment: "d", level: 0),
        ]
        #expect(ContentsCleaner.clean(entries, bookTitle: "Alice's Adventures in Wonderland").map(\.title) == ["Chapter I. Down the Rabbit-Hole"])
    }

    @Test func illustrationCaptionsInFrontOfChapterHeadingsGo() {
        let entries: [E] = [
            .init(title: "PRIDE. and PREJUDICE", href: "h-0.html", fragment: "a", level: 0),
            .init(title: "Chapter I.", href: "h-0.html", fragment: "b", level: 0),
            .init(title: "I hope Mr. Bingley will like it. CHAPTER II.", href: "h-1.html", fragment: "c", level: 0),
            .init(title: "“On the Stairs.” CHAPTERXXVII.", href: "h-6.html", fragment: "d", level: 0),
            .init(title: "{474}", href: "h-15.html", fragment: "e", level: 0),
        ]
        #expect(ContentsCleaner.clean(entries, bookTitle: "Pride and Prejudice").map(\.title) == ["Chapter I", "Chapter II", "Chapter XXVII"])
    }

    @Test func romanNumeralChaptersCount() {
        let entries: [E] = [
            .init(title: "The Great Gatsby by F. Scott Fitzgerald", href: "h-0.xhtml", fragment: "a", level: 0),
            .init(title: "Table of Contents", href: "h-0.xhtml", fragment: "b", level: 0),
            .init(title: "I", href: "h-0.xhtml", fragment: "c", level: 0),
            .init(title: "II", href: "h-0.xhtml", fragment: "d", level: 0),
        ]
        #expect(ContentsCleaner.clean(entries, bookTitle: "The Great Gatsby").map(\.title) == ["I", "II"])
    }

    @Test func titledChaptersWithoutNumbersAreLeftAlone() {
        let entries: [E] = [
            .init(title: "The Boy Who Lived", href: "a.xhtml", fragment: nil, level: 0),
            .init(title: "The Vanishing Glass", href: "b.xhtml", fragment: nil, level: 0),
        ]
        #expect(ContentsCleaner.clean(entries, bookTitle: "A Book").map(\.title) == ["The Boy Who Lived", "The Vanishing Glass"])
    }

    @Test func aPrologueIsTheStart() {
        let entries: [E] = [
            .init(title: "Copyright", href: "a.xhtml", fragment: nil, level: 0),
            .init(title: "Prologue", href: "b.xhtml", fragment: nil, level: 0),
            .init(title: "Chapter 1", href: "c.xhtml", fragment: nil, level: 0),
        ]
        #expect(ContentsCleaner.clean(entries, bookTitle: "A Book").map(\.title) == ["Prologue", "Chapter 1"])
    }
}

@Suite("Where the story ends")
struct BookEndTests {
    @Test func theLicenceIsNotTheStory() {
        let entries: [E] = [
            .init(title: "Chapter 24", href: "h-29.xhtml", fragment: "a", level: 0),
            .init(title: "THE FULL PROJECT GUTENBERG™ LICENSE", href: "h-30.xhtml", fragment: "pg-footer-heading", level: 0),
        ]
        #expect(BookEnd.backMatter(in: entries) == entries[1])
        #expect(BookEnd.backMatter(in: [entries[0]]) == nil)
    }

    @Test func aBookWithoutALicenceEndsNearItsLastPage() {
        #expect(!BookEnd.isNearEnd(0.99))
        #expect(BookEnd.isNearEnd(0.996))
    }
}

@Suite("Display titles")
struct DisplayTitleTests {
    @Test func subtitlesAndShoutingGo() {
        #expect(BookTitle.display("Frankenstein; or, The modern Prometheus") == "Frankenstein")
        #expect(BookTitle.display("MOBY-DICK; or, THE WHALE.") == "Moby-Dick")
        #expect(BookTitle.display("Moby Dick; Or, The Whale") == "Moby Dick")
        #expect(BookTitle.display("Pride and Prejudice") == "Pride and Prejudice")
        #expect(BookTitle.display("the great gatsby") == "The Great Gatsby")
    }

    @Test func headingsSoftenButKeepNumerals() {
        #expect(Headings.tidy("CHAPTER XIX.") == "Chapter XIX")
        #expect(Headings.tidy("Letter 1") == "Letter 1")
    }
}

@Suite("The sync slip")
struct SyncSlipTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func agesReadLikeSpeech() {
        #expect(RelativeAge.text(from: now.addingTimeInterval(-20), to: now) == "just now")
        #expect(RelativeAge.text(from: now.addingTimeInterval(-5 * 60), to: now) == "5 min ago")
        #expect(RelativeAge.text(from: now.addingTimeInterval(-2 * 3600 - 100), to: now) == "2 h ago")
        #expect(RelativeAge.text(from: now.addingTimeInterval(-30 * 3600), to: now) == "yesterday")
        #expect(RelativeAge.text(from: now.addingTimeInterval(-4 * 86400), to: now) == "4 days ago")
        #expect(RelativeAge.text(from: now.addingTimeInterval(60), to: now) == "just now", "a clock a little ahead is still now")
    }

    @Test func aLandingSaysWhereItCameFrom() {
        let slip = SyncSlip.landed(device: "PocketBook InkPad", updated: now.addingTimeInterval(-7200), now: now)
        #expect(slip.title == "From your InkPad · 2 h ago")
        #expect(slip.passage == nil)
    }

    // Our own place, found again after a reinstall: never credited to the InkPad.
    @Test func ourOwnPlaceIsNotTheInkPads() {
        let slip = SyncSlip.resumed(updated: now.addingTimeInterval(-3600), now: now)
        #expect(slip.title == "Right where you left off · 1 h ago")
        #expect(!slip.title.contains("InkPad"))
    }

    @Test func anOfferNamesThePassage() {
        let slip = SyncSlip.ahead(device: "PocketBook InkPad", pagesAhead: 23, percentAhead: nil, updated: now.addingTimeInterval(-30 * 3600), now: now,
                                  passage: "She thought her the model of all that was good and kind, and more besides")
        #expect(slip.title == "Your InkPad read on without you")
        #expect(slip.detail == "23 pages ahead · yesterday")
        #expect(slip.passage == "She thought her the model of all that was good…")
    }

    @Test func oneAheadApproximateAndPercentOnly() {
        #expect(SyncSlip.ahead(device: "", pagesAhead: 1, percentAhead: nil, updated: nil, now: now, passage: nil).detail == "1 page ahead")
        #expect(SyncSlip.ahead(device: "InkPad", pagesAhead: 14, approximate: true, percentAhead: 3, updated: nil, now: now, passage: nil).detail == "About 14 pages ahead")
        let percent = SyncSlip.ahead(device: "PocketBook web reader", pagesAhead: nil, percentAhead: 12, updated: now.addingTimeInterval(-300), now: now, passage: nil)
        #expect(percent.title == "Your web reader read on without you")
        #expect(percent.detail == "12% further on · 5 min ago")
    }

    @Test func theFoldedTabSaysWhoAndHowFar() {
        #expect(SyncSlip.tab(device: "PocketBook InkPad", pagesAhead: 23) == "InkPad +23")
        #expect(SyncSlip.tab(device: "Web reader", pagesAhead: nil) == "Web reader")
    }
}

@Suite("The shelf's greeting")
struct GreetingTests {
    @Test func namesTheBookWaiting() {
        #expect(ArrivalGreeting.text(bookCount: 11, waitingTitle: "Moby-Dick; or, The Whale", waitingPercent: 42)
            == "Welcome back. Moby-Dick’s been holding your place at 42%.")
        #expect(ArrivalGreeting.text(bookCount: 1, waitingTitle: nil, waitingPercent: nil) == "Welcome back. 1 book came over from your InkPad, ready when you are.")
        #expect(ArrivalGreeting.text(bookCount: 0, waitingTitle: nil, waitingPercent: nil) == nil)
    }
}

@Suite("The end leaf's line")
struct FinishLineTests {
    let cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()

    @Test func daysAndSessions() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(10 * 86400 + 3600)
        #expect(FinishLine.text(started: start, finished: end, sessions: 9, calendar: cal) == "Finished · 11 days, 9 sessions")
        #expect(FinishLine.text(started: start, finished: start.addingTimeInterval(1800), sessions: 1, calendar: cal) == "Devoured in one sitting")
        #expect(FinishLine.text(started: start, finished: start.addingTimeInterval(3600), sessions: 3, calendar: cal) == "Finished · in a day, 3 sessions")
        #expect(FinishLine.text(started: nil, finished: start, sessions: 0, calendar: cal) == "Closed on the very last page")
    }

    @Test func theTwoDeviceStory() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(11 * 86400 + 3600)
        #expect(ReadStory.text(otherDevice: "InkPad", otherSince: start, started: start.addingTimeInterval(86400), finished: end,
                               sessions: 4, here: "phone", calendar: cal) == "Started on your InkPad, finished here on your phone\nRead over 12 days")
        #expect(ReadStory.text(otherDevice: "InkPad", otherSince: end.addingTimeInterval(-3600), started: nil, finished: end,
                               sessions: 1, here: "iPad", calendar: cal) == "Started on your InkPad, finished here on your iPad\nRead in a single day")
        #expect(ReadStory.text(otherDevice: "InkPad", otherSince: start, started: start, finished: start.addingTimeInterval(86400),
                               sessions: 2, here: "phone", calendar: cal) == "Started on your InkPad, finished here on your phone\nRead over 2 days")
    }

    @Test func beganHereOrUnknown() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(10 * 86400 + 3600)
        // Begun here: the days-and-sessions line.
        #expect(ReadStory.text(otherDevice: nil, otherSince: nil, started: start, finished: end, sessions: 9, here: "phone", calendar: cal)
            == "Finished · 11 days, 9 sessions")
        // The InkPad's first sign came after the first open here: it began here.
        #expect(ReadStory.text(otherDevice: "InkPad", otherSince: end, started: start, finished: end, sessions: 9, here: "phone", calendar: cal)
            == "Finished · 11 days, 9 sessions")
        #expect(ReadStory.text(otherDevice: nil, otherSince: nil, started: nil, finished: end, sessions: 0, here: "phone", calendar: cal)
            == "Closed on the very last page")
    }

    // The Finished shelf and the end leaf tell one story: when the InkPad began the book, the span
    // counts from there, never "a single day" for a book begun on the InkPad days before, and both say
    // the same "over 6 days" so nobody has to do sums between them.
    @Test func theShelfCountsFromWhereTheReadBegan() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let today = start.addingTimeInterval(5 * 86400 + 3600)
        #expect(ReadStory.text(otherDevice: "InkPad", otherSince: start, started: today, finished: today,
                               sessions: 1, here: "phone", calendar: cal) == "Started on your InkPad, finished here on your phone\nRead over 6 days")
        #expect(ReadStory.shelfLine(otherDevice: "InkPad", otherSince: start, started: today, finished: today,
                                    sessions: 1, here: "phone", calendar: cal) == "Read over 6 days, InkPad to phone")
    }

    @Test func theShelfLineForABookBegunHere() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(ReadStory.shelfLine(otherDevice: nil, otherSince: nil, started: start, finished: start.addingTimeInterval(3600),
                                    sessions: 1, here: "phone", calendar: cal) == "Read in a single day")
        #expect(ReadStory.shelfLine(otherDevice: nil, otherSince: nil, started: start, finished: start.addingTimeInterval(11 * 86400),
                                    sessions: 9, here: "iPad", calendar: cal) == "Read over 12 days, in 9 sittings")
        // The InkPad's first sign came after the first open here: it began here.
        #expect(ReadStory.shelfLine(otherDevice: "InkPad", otherSince: start.addingTimeInterval(86400), started: start,
                                    finished: start.addingTimeInterval(3600 * 30), sessions: 2, here: "phone", calendar: cal)
            == "Read over 2 days, in 2 sittings")
        #expect(ReadStory.shelfLine(otherDevice: nil, otherSince: nil, started: nil, finished: start,
                                    sessions: 1, here: "phone", calendar: cal) == nil)
    }
}

@Suite("The shelf's sync line")
struct SyncHealthTests {
    @Test func words() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(SyncHealth.checking.text(now: now) == "Checking your InkPad…")
        #expect(SyncHealth.upToDate(now.addingTimeInterval(-10)).text(now: now) == "In step with your InkPad · just now")
        #expect(SyncHealth.upToDate(now.addingTimeInterval(-300)).text(now: now) == "In step with your InkPad · 5 min ago")
        #expect(SyncHealth.offline(lastSynced: nil).text(now: now) == "Offline for now. Read on; your place will catch up later.")
        #expect(SyncHealth.offline(lastSynced: now.addingTimeInterval(-7200)).text(now: now).hasPrefix("Offline for now · last synced 2 h ago"))
    }
}

@Suite("Shelf sizes")
struct ShelfMetricsTests {
    @Test func scalesWithTheScreen() {
        let phone = ShelfMetrics.forWidth(466)
        let pad = ShelfMetrics.forWidth(820)
        #expect(phone.large == 150 && phone.grid == 100)
        #expect(pad.large > phone.large * 1.25, "iPad covers are a good deal larger")
        // An 11-inch iPad's grid fits five covers across, not seven little ones.
        let columns = Int((820 - 2 * pad.gutter + pad.spacing) / (pad.grid + pad.spacing))
        #expect(columns == 5)
    }
}

@Suite("Controls stay clear of the camera")
struct ChromeClearanceTests {
    // The folded Duo's cover screen: camera and status column at the top right.
    let size = CGSize(width: 350, height: 510)
    let camera = CGRect(x: 288, y: 0, width: 62, height: 110)

    @Test func theTopBarStopsShortOfTheCamera() {
        let c = ChromeClearance.resolve(container: size, occlusions: [camera])
        #expect(c.trailing == CGFloat(70))
        #expect(c.leading == 0)
        #expect(c.bookmarkLeading, "the bookmark moves beside Close")
    }

    @Test func theRibbonHangsLeftOfTheCamera() {
        let c = ChromeClearance.resolve(container: size, occlusions: [camera])
        let x = c.ribbonX(pageMaxX: 350, ribbonWidth: 20)
        #expect(x + 20 <= 288 - 8)
        #expect(ChromeClearance.resolve(container: size, occlusions: []).ribbonX(pageMaxX: 350, ribbonWidth: 20) == CGFloat(296))
    }

    @Test func theLibraryHeaderDropsBelowTheCamera() {
        #expect(ChromeClearance.headerDrop(occlusions: [camera], band: 60, width: 350) == CGFloat(118))
        #expect(ChromeClearance.headerDrop(occlusions: [], band: 60, width: 350) == 0)
        // Above the view (the status bar) or well below the header: no drop.
        #expect(ChromeClearance.headerDrop(occlusions: [CGRect(x: 0, y: -40, width: 350, height: 40)], band: 60, width: 350) == 0)
        #expect(ChromeClearance.headerDrop(occlusions: [CGRect(x: 300, y: 300, width: 40, height: 40)], band: 60, width: 350) == 0)
        // The real cover screen: the status column lies in the trailing safe area, beside a 382-pt shelf.
        let column = CGRect(x: 382, y: 0, width: 84, height: 174)
        #expect(ChromeClearance.headerDrop(occlusions: [column], band: 60, width: 382) == 0)
    }

    /// A fresh iPad Pro 13-inch upright reports a band across the whole top of its window. It is no
    /// corner: clearing it sideways took 1040 pt from a 1032-pt window and put Close, Your Page and the
    /// panel past the right edge (build 19). The bar steps down below it instead.
    @Test func aBandAcrossTheTopMovesTheBarDownNotAside() {
        let window = CGSize(width: 1032, height: 1376)
        let c = ChromeClearance.resolve(container: window, occlusions: [CGRect(x: 0, y: 0, width: 1032, height: 32)])
        #expect(c.leading == 0)
        #expect(c.trailing == 0)
        #expect(c.top == CGFloat(40))
        #expect(!c.bookmarkLeading)
    }

    /// On its side the same iPad reports a strip down the window's left edge, top to bottom. The header
    /// isn't under it any more than the page is: build 19 dropped the shelf's header 1040 pt, off screen.
    @Test func aStripDownTheSideNeverDropsTheHeader() {
        #expect(ChromeClearance.headerDrop(occlusions: [CGRect(x: 0, y: 0, width: 32, height: 1032)], band: 60, width: 1376) == 0)
        // A camera taller than two bands is still a camera, not a strip.
        #expect(ChromeClearance.headerDrop(occlusions: [CGRect(x: 288, y: 0, width: 62, height: 150)], band: 60, width: 700) == 158)
    }

    @Test func aRegionLowOnTheScreenOrOnTheLeftIsHandled() {
        let low = CGRect(x: 300, y: 400, width: 40, height: 40)
        #expect(ChromeClearance.resolve(container: size, occlusions: [low]).trailing == 0)
        let left = CGRect(x: 0, y: 0, width: 70, height: 60)
        let c = ChromeClearance.resolve(container: size, occlusions: [left])
        #expect(c.leading == CGFloat(78))
        #expect(!c.bookmarkLeading)
    }
}

@Suite("A book's measure")
struct MeasureTests {
    @Test func iPadPortraitGetsBookMargins() {
        // 820 pt wide at 17 pt × 1.15: a full-width column would set ~100 characters.
        let inset = Measure.sideInset(width: 820, fontScale: 1.15)
        let column = 820 - 2 * inset
        let chars = Measure.charactersPerLine(column: column, fontScale: 1.15)
        #expect((60...75).contains(chars))
    }

    @Test func aPhoneKeepsItsWidth() {
        #expect(Measure.sideInset(width: 350, fontScale: 1) == 0)
        #expect(Measure.sideInset(width: 430, fontScale: 1) == 0)
    }

    @Test func biggerTypeWidensTheColumn() {
        #expect(Measure.sideInset(width: 820, fontScale: 1.6) < Measure.sideInset(width: 820, fontScale: 1.0))
    }

    @Test func regularWidthStartsAStepLarger() {
        #expect(ReaderPreferences.legacyInitialFontScale(forContentSizeRank: 3, regularWidth: true) == 1.15)
        #expect(ReaderPreferences.legacyInitialFontScale(forContentSizeRank: 3, regularWidth: false) == 1.0)
        // Build 15: Apple Books' default density, type set larger again.
        #expect(ReaderPreferences.initialFontScale(forContentSizeRank: 3, regularWidth: true) > ReaderPreferences.initialFontScale(forContentSizeRank: 3, regularWidth: false))
    }
}

@Suite("Every text-on-colour pair reads (WCAG AA)")
struct ContrastTests {
    @Test func themeText() {
        for theme in ReaderTheme.allCases {
            #expect(theme.palette.contrastRatio >= 4.5, "\(theme) text")
        }
    }

    @Test func labelsOnAccentButtons() {
        for theme in ReaderTheme.allCases {
            let p = theme.palette
            #expect(ThemePalette.contrast(p.onAccent, p.accent) >= 4.5, "\(theme) label on accent")
        }
    }

    @Test func labelsOnTheRibbon() {
        for scheme in [Brand.light, Brand.dark] {
            #expect(ThemePalette.contrast(scheme.onRibbon, scheme.ribbon) >= 4.5)
            #expect(ThemePalette.contrast(scheme.ribbon, scheme.paper) >= 4.5, "ribbon-tinted text on paper")
            #expect(ThemePalette.contrast(scheme.ink, scheme.paper) >= 4.5)
        }
    }

    /// Running heads and page numbers: quiet grey, still AA on every page (calm redesign, 2026-11-03).
    @Test func runningHeadsAndPageNumbers() {
        for theme in ReaderTheme.allCases {
            let p = theme.palette
            #expect(p.head != p.text, "\(theme) has its own head grey")
            #expect(ThemePalette.contrast(p.head, p.background) >= 4.5, "\(theme) head \(ThemePalette.contrast(p.head, p.background)):1")
        }
    }

    /// The calm palette: white by day, black by night, Inkwell blue as the one accent.
    @Test func calmBrand() {
        #expect(Brand.light.paper == 0xFFFFFF && Brand.dark.paper == 0x000000)
        #expect(Brand.light.ribbon == 0x2F5D8A && Brand.dark.ribbon == 0x7FA6D6)
        #expect(ThemePalette.contrast(Brand.light.ribbon, Brand.light.paper) >= 6.8)
        #expect(ThemePalette.contrast(Brand.dark.ribbon, Brand.dark.paper) >= 8.2)
        #expect(ThemePalette.contrast(Brand.light.ink, Brand.light.paper) >= 16)
        #expect(ThemePalette.contrast(Brand.dark.ink, Brand.dark.paper) >= 19)
        // Increased contrast variants of the accent and the secondary grey.
        #expect(ThemePalette.contrast(0x244A70, 0xFFFFFF) >= 9)
        #expect(ThemePalette.contrast(0xA3C2E8, 0x000000) >= 11)
        #expect(ThemePalette.contrast(0x6E6E73, 0xFFFFFF) >= 4.5 && ThemePalette.contrast(0x98989D, 0x000000) >= 4.5)
        #expect(ThemePalette.contrast(0x515154, 0xFFFFFF) >= 7 && ThemePalette.contrast(0xAEAEB2, 0x000000) >= 7)
    }

    /// No theme keeps the old cream or rust; Vellum shows as Linen, its saved name unchanged.
    @Test func noCreamNoRust() {
        let old: Set<UInt32> = [0xF6F1E7, 0xF5EDDC, 0x9A3B26, 0x8C3A1E, 0xE08A6A]
        for theme in ReaderTheme.allCases {
            #expect(!old.contains(theme.palette.background) && !old.contains(theme.palette.accent), "\(theme)")
        }
        #expect(ReaderTheme.vellum.displayName == "Linen")
        #expect(ReaderTheme(rawValue: "vellum") == .vellum)
    }

    /// Captions, the slip's detail and the end leaf's line are the theme's text at 80 % over its page.
    @Test func softenedCaptions() {
        func blend(_ fg: UInt32, _ bg: UInt32, _ a: Double) -> UInt32 {
            let f = ThemePalette.components(fg), b = ThemePalette.components(bg)
            func c(_ x: Double, _ y: Double) -> UInt32 { UInt32(((x * a + y * (1 - a)) * 255).rounded()) }
            return c(f.r, b.r) << 16 | c(f.g, b.g) << 8 | c(f.b, b.b)
        }
        for theme in ReaderTheme.allCases {
            let p = theme.palette
            #expect(ThemePalette.contrast(blend(p.text, p.background, 0.8), p.background) >= 4.5, "\(theme) caption")
        }
    }
}

@Suite struct FrontMatterTests {
    @Test func aPlaceBeforeChapterOneIsUnread() {
        #expect(FrontMatter.isUnread(0.03, storyStart: 0.051))
        #expect(FrontMatter.isUnread(0.0515, storyStart: 0.051))
    }

    @Test func aPlaceInTheStoryIsRead() {
        #expect(!FrontMatter.isUnread(0.06, storyStart: 0.051))
        #expect(!FrontMatter.isUnread(0.2, storyStart: 0))
    }

    @Test func withoutContentsOnlyTheVeryStartIsUnread() {
        #expect(FrontMatter.isUnread(0.001, storyStart: 0))
        #expect(!FrontMatter.isUnread(0.01, storyStart: 0))
    }
}

@Suite struct PassageTextTests {
    let html = """
    <html><head><title>Ch</title><style>p{}</style></head><body><h2>Chapter 7</h2>
    <p>It was a fine day. She thought her the model of all that was good &amp; kind.</p><p>Then rain.</p></body></html>
    """

    @Test func readsTheBodyAsText() {
        #expect(PassageText.plainText(ofHTML: html) == "Chapter 7 It was a fine day. She thought her the model of all that was good & kind. Then rain.")
    }

    @Test func startsAtTheNextSentence() {
        #expect(PassageText.sentence(inHTML: html, at: 0.15)?.hasPrefix("She thought her the model") == true)
        #expect(PassageText.sentence(inHTML: html, at: 0)?.hasPrefix("Chapter 7 It was") == true)
    }
}
