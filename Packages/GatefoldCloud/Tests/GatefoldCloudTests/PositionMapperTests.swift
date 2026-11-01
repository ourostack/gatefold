import Foundation
import Testing
@testable import GatefoldCloud

/// Frankenstein (Project Gutenberg #84), the book used in the web-reader round trip.
private func mapper() throws -> PositionMapper {
    let spine = try SpineMap(opf: Fixture.data("frankenstein/content.opf"), opfPath: "OEBPS/content.opf")
    // Only two chapters are fixtures; the rest of the book is simply missing, as an unreadable resource would be.
    return PositionMapper(spine: spine) { href in
        guard let url = Bundle.module.url(forResource: "Fixtures/frankenstein/" + (href as NSString).lastPathComponent, withExtension: nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }
}

@Suite("Locator-shaped locations ⇄ Cloud positions")
struct PositionMapperTests {
    /// What PocketBook's web reader wrote after turning to Chapter 1.
    let webReaderPointer = "#epubcfi(/6/16[item9]!/4/2[pgepubid00007]/2/1:0)"

    @Test func placesThePocketBookWebReaderPositionInTheChapter() async throws {
        let remote = try #require(WireDecoder.position(.object([
            "pointer": .string(webReaderPointer), "pointer_pb": .string(webReaderPointer),
            "percent": .number(9), "updated": .string("2026-10-31T22:28:35Z"),
        ])))
        let location = try #require(await mapper().location(for: remote))
        #expect(location.href == Fixture.chapter1Href)
        #expect(try #require(location.progression) < 0.001)
        #expect(location.totalProgression == 0.09)
        #expect(location.cfi == "epubcfi(/6/16[item9]!/4/2[pgepubid00007]/2/1:0)")
        #expect(location.textAfter?.hasPrefix("Chapter 1") == true)
    }

    @Test func turnsAReadiumProgressionIntoAnExactCFI() async throws {
        let m = try mapper()
        let location = BookLocation(href: "/" + Fixture.chapter1Href, progression: 0.5, totalProgression: 0.12)
        let position = try #require(await m.position(for: location, at: utc("2026-10-31T22:00:00Z")))
        let cfi = try #require(position.parsedCFI)
        #expect(cfi.spineIndex == 7)
        #expect(cfi.spineItemID == "item9")
        #expect(position.progression == 0.5)
        #expect(position.totalProgression == 0.12)
        #expect(position.updated == utc("2026-10-31T22:00:00Z"))

        let back = try #require(await m.location(for: position))
        #expect(back.href == Fixture.chapter1Href)
        #expect(abs(try #require(back.progression) - 0.5) < 0.01, "the CFI lands where the reader was")
    }

    /// Readium's progression is a page boundary, not a character; the first words on screen are exact.
    @Test func anchorsTheCFIOnTheFirstWordsOnScreen() async throws {
        let m = try mapper()
        // The page starts mid-chapter: progression says "near the top", the words say exactly where.
        let location = BookLocation(href: Fixture.chapter1Href, progression: 0.0, totalProgression: 0.09,
                                    textHighlight: "I am by birth a Genevese, and my family")
        let position = try #require(await m.position(for: location, at: utc("2026-10-31T22:00:00Z")))
        let back = try #require(await m.location(for: position))
        #expect(back.textAfter?.hasPrefix("I am by birth a Genevese") == true)
    }

    /// Readium can still report the last resource just after a turn into the next one, while the
    /// words on screen already come from the new chapter. The words win.
    @Test func followsTheWordsIntoTheNextResource() async throws {
        let m = try mapper()
        let location = BookLocation(href: "OEBPS/4328224471496264690_84-h-5.htm.xhtml", progression: 0.97, totalProgression: 0.08,
                                    textHighlight: "Chapter 1")
        let position = try #require(await m.position(for: location, at: utc("2026-10-31T22:00:00Z")))
        #expect(position.parsedCFI?.spineItemID == "item9")
        let back = try #require(await m.location(for: position))
        #expect(back.href == Fixture.chapter1Href)
        #expect(back.textAfter?.hasPrefix("Chapter 1") == true)
    }

    @Test func fallsBackToProgressionWhenTheWordsAreNotInTheResource() async throws {
        let m = try mapper()
        let location = BookLocation(href: Fixture.chapter1Href, progression: 0.5, totalProgression: 0.12,
                                    textHighlight: "words that never appear in Frankenstein at all")
        let position = try #require(await m.position(for: location, at: utc("2026-10-31T22:00:00Z")))
        let back = try #require(await m.location(for: position))
        #expect(abs(try #require(back.progression) - 0.5) < 0.01)
    }

    @Test func keepsACFIReadiumAlreadyHas() async throws {
        let location = BookLocation(href: Fixture.chapter1Href, progression: 0.3, totalProgression: 0.1, cfi: "epubcfi(/6/16[item9]!/4/2[pgepubid00007]/2/1:0)")
        let position = try #require(await mapper().position(for: location, at: utc("2026-10-31T22:00:00Z")))
        #expect(position.cfi == "epubcfi(/6/16[item9]!/4/2[pgepubid00007]/2/1:0)")
    }

    @Test func ignoresACFIForAnotherResource() async throws {
        // A stale CFI from a different chapter must not override where Readium says the reader is.
        let location = BookLocation(href: Fixture.chapter1Href, progression: 0, totalProgression: 0.1, cfi: "epubcfi(/6/14[item8]!/4/2/1:0)")
        let position = try #require(await mapper().position(for: location, at: utc("2026-10-31T22:00:00Z")))
        #expect(position.parsedCFI?.spineIndex == 7)
    }

    @Test func fallsBackToPercentForUnknownPlaces() async throws {
        let m = try mapper()
        let nowhere = BookLocation(href: "OEBPS/missing.xhtml", progression: 0.2, totalProgression: 0.4)
        let position = try #require(await m.position(for: nowhere, at: utc("2026-10-31T22:00:00Z")))
        #expect(position.cfi == nil)
        #expect(position.totalProgression == 0.4)

        let percentOnly = ReadingPosition(cfi: nil, totalProgression: 0.4, updated: utc("2026-10-31T22:00:00Z"))
        #expect(await m.location(for: percentOnly) == nil, "the reader seeks by totalProgression instead")
    }
}
