import Foundation
import Testing
@testable import GatefoldCore

@Suite("Chapter titles come from the contents")
struct ContentsIndexTests {
    // Pride and Prejudice (Gutenberg): several chapters per file, each one an anchor in the contents.
    let index = ContentsIndex(
        entries: [
            .init(title: "Cover", href: "OEBPS/cover.xhtml", fragment: nil, level: 0),
            .init(title: "Chapter I", href: "OEBPS/part1.xhtml", fragment: "ch1", level: 0),
            .init(title: "Chapter II", href: "OEBPS/part1.xhtml", fragment: "ch2", level: 0),
            .init(title: "Chapter XIX", href: "OEBPS/part2.xhtml", fragment: "ch19", level: 0),
            .init(title: "Chapter XX", href: "OEBPS/part2.xhtml", fragment: "ch20", level: 0),
            .init(title: "Appendix", href: "OEBPS/appendix.xhtml", fragment: nil, level: 0),
            .init(title: "Notes on the text", href: "OEBPS/appendix.xhtml", fragment: "notes", level: 1),
        ],
        readingOrder: ["OEBPS/cover.xhtml", "OEBPS/part1.xhtml", "OEBPS/part2.xhtml", "OEBPS/appendix.xhtml"]
    )

    @Test func namesTheChapterWhoseAnchorIsAboveTheFirstLine() {
        #expect(index.title(href: "OEBPS/part2.xhtml", precedingFragment: "ch19") == "Chapter XIX")
        #expect(index.title(href: "OEBPS/part2.xhtml", precedingFragment: "ch20") == "Chapter XX")
    }

    @Test func listsTheAnchorsTheWebViewShouldLookFor() {
        #expect(index.fragments(in: "OEBPS/part1.xhtml") == ["ch1", "ch2"])
        #expect(index.fragments(in: "/OEBPS/part1.xhtml#ch2") == ["ch1", "ch2"], "Readium hrefs may carry a slash or fragment")
        #expect(index.fragments(in: "OEBPS/cover.xhtml").isEmpty)
    }

    @Test func comparesResourcesLikeReadiumWritesThem() {
        #expect(ContentsIndex.sameResource("/OEBPS/a%20b.xhtml#x", "OEBPS/a b.xhtml"))
        #expect(!ContentsIndex.sameResource("OEBPS/a.xhtml", "OEBPS/b.xhtml"))
    }

    @Test func aWholeFileChapterNeedsNoAnchor() {
        #expect(index.title(href: "OEBPS/cover.xhtml", precedingFragment: nil) == "Cover")
        #expect(index.title(href: "OEBPS/appendix.xhtml", precedingFragment: nil) == "Appendix")
        #expect(index.title(href: "OEBPS/appendix.xhtml", precedingFragment: "notes") == "Notes on the text")
    }

    @Test func aboveTheFileFirstAnchorTheReaderIsStillInThePreviousChapter() {
        // The tail of Chapter II spills into part2 before Chapter XIX's anchor.
        #expect(index.title(href: "OEBPS/part2.xhtml", precedingFragment: nil) == "Chapter II")
    }

    @Test func anUnknownAnchorOrFileFallsBackSensibly() {
        #expect(index.title(href: "OEBPS/part2.xhtml", precedingFragment: "nope") == "Chapter II")
        #expect(index.title(href: "OEBPS/elsewhere.xhtml", precedingFragment: nil) == nil)
        #expect(ContentsIndex(entries: [], readingOrder: []).title(href: "a.xhtml", precedingFragment: nil) == nil)
    }
}

@Suite("Placing a resource position on the book's scale")
struct ReadingScaleTests {
    let starts = [0.0, 0.1, 0.5]

    @Test func interpolatesInsideTheResource() {
        #expect(abs((ReadingScale.totalProgression(resourceIndex: 1, progression: 0.5, resourceStarts: starts) ?? -1) - 0.3) < 1e-9)
        #expect(abs((ReadingScale.totalProgression(resourceIndex: 2, progression: 0.5, resourceStarts: starts) ?? -1) - 0.75) < 1e-9)
        #expect(ReadingScale.totalProgression(resourceIndex: 0, progression: 0, resourceStarts: starts) == 0)
    }

    @Test func clampsWhatItCannotPlace() {
        #expect(ReadingScale.totalProgression(resourceIndex: 1, progression: 2, resourceStarts: starts) == 0.5)
        #expect(ReadingScale.totalProgression(resourceIndex: 9, progression: 0.5, resourceStarts: starts) == nil)
        #expect(ReadingScale.totalProgression(resourceIndex: 0, progression: 0.5, resourceStarts: []) == nil)
    }
}

@Suite("Shelf titles")
struct ShelfTitleTests {
    @Test func dropsTheSubtitle() {
        #expect(BookTitle.short("Frankenstein; or, The Modern Prometheus") == "Frankenstein")
        #expect(BookTitle.short("Moby-Dick; Or, The Whale") == "Moby-Dick")
        #expect(BookTitle.short("Dune: Part Two") == "Dune")
    }

    @Test func keepsTitlesWithoutOne() {
        #expect(BookTitle.short("Alice’s Adventures in Wonderland") == "Alice’s Adventures in Wonderland")
        #expect(BookTitle.short("  Emma ") == "Emma")
    }

    @Test func neverLeavesTooLittle() {
        #expect(BookTitle.short("Q: The Autobiography of Quincy Jones") == "Q: The Autobiography of Quincy Jones")
    }
}
