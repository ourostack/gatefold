import Foundation
import Testing
@testable import GatefoldCloud

/// Highlights ⇄ the Cloud's two point CFIs, on Frankenstein's Chapter 1.
@Suite("Highlight ranges ⇄ Cloud anchors")
struct AnnotationMappingTests {
    private func mapper() throws -> PositionMapper {
        let spine = try SpineMap(opf: Fixture.data("frankenstein/content.opf"), opfPath: "OEBPS/content.opf")
        return PositionMapper(spine: spine) { href in
            guard let url = Bundle.module.url(forResource: "Fixtures/frankenstein/" + (href as NSString).lastPathComponent, withExtension: nil) else {
                throw CocoaError(.fileNoSuchFile)
            }
            return try Data(contentsOf: url)
        }
    }

    private let date = Date(timeIntervalSince1970: 1_793_484_031)

    /// What Readium reports for a selection that crosses a line break in the XHTML.
    @Test func aSelectionBecomesTwoCFIsThatNameTheSameWords() async throws {
        let m = try mapper()
        let range = try #require(await m.range(href: "/" + Fixture.chapter1Href, highlight: "one of the most distinguished of that republic",
                                               before: "and my family is ", after: ". My ancestors", progression: 0.0))
        #expect(range.href == Fixture.chapter1Href)
        #expect(range.spineIndex == 7)
        #expect(range.displayText == "one of the most distinguished of that republic")
        #expect(range.text.contains("\n"), "the file's own line break is kept in the raw text")
        #expect(range.begin.spineItemID == "item9")
        #expect(range.begin < range.end)

        let annotation = CloudAnnotation.highlight(range, note: "Geneva!", at: date)
        #expect(annotation.kind.value == .note)
        #expect(annotation.quotation?.value.begin.hasPrefix("#epubcfi(/6/16[item9]!") == true)
        #expect(annotation.quotation?.value.text == "one of the most distinguished of that republic")
        #expect(annotation.noteText == "Geneva!")
        #expect(annotation.anchorStyle == .web)

        let back = try #require(await m.range(for: annotation))
        #expect(back == range, "the Cloud's anchors resolve to exactly the selected words")
    }

    @Test func theEndAnchorSitsJustPastTheLastCharacter() async throws {
        let m = try mapper()
        let range = try #require(await m.range(href: Fixture.chapter1Href, highlight: "Genevese", before: "I am by birth a ", after: ", and", progression: 0))
        let doc = try #require(await m.document(Fixture.chapter1Href))
        let start = try #require(doc.resolve(range.begin))
        let end = try #require(doc.resolve(range.end))
        #expect(doc.text(from: start, count: end.textOffset - start.textOffset) == "Genevese")
        #expect(range.before.hasSuffix("I am by birth a "))
        #expect(range.after.hasPrefix(", and my family"))
    }

    /// "of the" occurs all over the chapter; the words around the selection pick the right one.
    @Test func surroundingWordsPickTheRightOccurrence() async throws {
        let m = try mapper()
        let near = try #require(await m.range(href: Fixture.chapter1Href, highlight: "of the", before: "is one ", after: " most distinguished", progression: 0.9))
        #expect(near.before.hasSuffix("my family is one "))
        #expect(near.progression < 0.05, "the first paragraph's, though the page hint pointed at the end")
    }

    /// The InkPad's text quote survives an anchor from a slightly different copy of the book.
    @Test func aStaleAnchorFallsBackToTheQuotedWords() async throws {
        let m = try mapper()
        let stale = CloudAnnotation.highlight(begin: "pbr:/webkit?##epubcfi(/6/16[item9]!/4/2/4/1:3)", end: "pbr:/webkit?##epubcfi(/6/16[item9]!/4/2/4/1:9)",
                                              text: "My ancestors had been for many years counsellors", at: date)
        let range = try #require(await m.range(for: stale))
        #expect(range.displayText == "My ancestors had been for many years counsellors")
        #expect(stale.anchorStyle == .device)
    }

    @Test func aLayoutAnchorIsFoundByItsWordsAnywhereInTheBook() async throws {
        let m = try mapper()
        let page = CloudAnnotation.highlight(begin: "pbr:/page?page=36&offs=123", end: "pbr:/page?page=36&offs=200",
                                             text: "He was respected by all who knew him", at: date)
        let range = try #require(await m.range(for: page))
        #expect(range.href == Fixture.chapter1Href)
        #expect(range.displayText == "He was respected by all who knew him")
    }

    @Test func bookmarksAndStrangersAreNotPassages() async throws {
        let m = try mapper()
        #expect(await m.range(for: .bookmark(at: "#epubcfi(/6/16[item9]!/4/2/1:0)", date: date)) == nil)
        let elsewhere = CloudAnnotation.highlight(begin: "pbr:/page?page=1", end: "pbr:/page?page=1", text: "Words that are not in this book at all", at: date)
        #expect(await m.range(for: elsewhere) == nil)
    }

    @Test func aNoteMakesAHighlightANoteAndBack() {
        var a = CloudAnnotation.highlight(begin: "#epubcfi(/6/2!/4/1:0)", end: "#epubcfi(/6/2!/4/1:4)", text: "Word", at: date)
        #expect(a.kind.value == .highlight)
        a.setNote("  A thought.  ", at: date.addingTimeInterval(60))
        #expect(a.kind.value == .note)
        #expect(a.noteText == "A thought.")
        #expect(a.note?.updated == date.addingTimeInterval(60))
        a.setNote("", at: date.addingTimeInterval(120))
        #expect(a.kind.value == .highlight)
        #expect(a.noteText == nil)
    }

    @Test func looseFindingIgnoresLineBreaksButNotLetters() throws {
        let doc = try CFIDocument(xhtml: Data("<html><body><p>alpha beta\n  gamma</p><p>beta gamma</p></body></html>".utf8))
        #expect(doc.findLoosely("beta gamma", near: 0) == 6..<18)
        #expect(doc.findLoosely("beta gamma", near: 30) == 18..<28)
        #expect(doc.findLoosely("beta delta", near: 0) == nil)
    }
}
