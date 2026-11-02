import CoreGraphics
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

    @Test func anOfferNamesThePassage() {
        let slip = SyncSlip.ahead(device: "PocketBook InkPad", pagesAhead: 23, percentAhead: nil, chapter: "Chapter 7",
                                  passage: "She thought her the model of all that was good and kind, and more besides")
        #expect(slip.title == "Your InkPad is 23 pages ahead")
        #expect(slip.detail == "In Chapter 7")
        #expect(slip.passage == "She thought her the model of all that was good…")
    }

    @Test func oneAheadAndPercentOnly() {
        #expect(SyncSlip.ahead(device: "", pagesAhead: 1, percentAhead: nil, chapter: nil, passage: nil).title == "Your other device is 1 page ahead")
        let percent = SyncSlip.ahead(device: "PocketBook web reader", pagesAhead: nil, percentAhead: 12, chapter: nil, passage: nil)
        #expect(percent.title == "Your web reader is 12% ahead")
        #expect(percent.detail == nil)
    }
}

@Suite("The shelf's greeting")
struct GreetingTests {
    @Test func namesTheBookWaiting() {
        #expect(ArrivalGreeting.text(bookCount: 11, waitingTitle: "Moby-Dick; or, The Whale", waitingPercent: 42)
            == "11 books from your PocketBook. Moby-Dick is waiting at 42%.")
        #expect(ArrivalGreeting.text(bookCount: 1, waitingTitle: nil, waitingPercent: nil) == "1 book from your PocketBook, ready when you are.")
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
        #expect(FinishLine.text(started: start, finished: start.addingTimeInterval(1800), sessions: 1, calendar: cal) == "Finished · in one sitting")
        #expect(FinishLine.text(started: start, finished: start.addingTimeInterval(3600), sessions: 3, calendar: cal) == "Finished · in a day, 3 sessions")
        #expect(FinishLine.text(started: nil, finished: start, sessions: 0, calendar: cal) == "Finished")
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
        #expect(ReaderPreferences.initialFontScale(forContentSizeRank: 3, regularWidth: true) == 1.15)
        #expect(ReaderPreferences.initialFontScale(forContentSizeRank: 3, regularWidth: false) == 1.0)
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
}
