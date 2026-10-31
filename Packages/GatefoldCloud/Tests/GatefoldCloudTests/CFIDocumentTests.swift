import Foundation
import Testing
@testable import GatefoldCloud

enum Fixture {
    static func data(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
        return try Data(contentsOf: url)
    }
    static let chapter1 = "frankenstein/4328224471496264690_84-h-6.htm.xhtml"
    static let chapter1Href = "OEBPS/4328224471496264690_84-h-6.htm.xhtml"
}

@Suite("OPF spine map")
struct SpineMapTests {
    @Test func readsSpineStepAndHrefsFromTheOPF() throws {
        let spine = try SpineMap(opf: Fixture.data("frankenstein/content.opf"), opfPath: "OEBPS/content.opf")
        #expect(spine.spineStep == 6)
        #expect(spine.items.count == 32)
        #expect(spine.items[7] == .init(idref: "item9", href: Fixture.chapter1Href))
        #expect(spine.index(ofHref: Fixture.chapter1Href) == 7)
        #expect(spine.index(ofHref: "/" + Fixture.chapter1Href) == 7, "Readium hrefs may carry a leading slash")
    }

    @Test func spineStepFollowsTheSpineElementPosition() throws {
        let opf = """
        <?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf"><metadata/><manifest>
        <item id="a" href="text/a%20b.xhtml" media-type="application/xhtml+xml"/></manifest>
        <guide/><spine><itemref idref="a"/></spine></package>
        """
        let spine = try SpineMap(opf: Data(opf.utf8), opfPath: "content.opf")
        #expect(spine.spineStep == 8)
        #expect(spine.items == [.init(idref: "a", href: "text/a b.xhtml")])
    }

    @Test func resolvesACFIToItsSpineHref() throws {
        let spine = try SpineMap(opf: Fixture.data("frankenstein/content.opf"), opfPath: "OEBPS/content.opf")
        let cfi = try #require(EPUBCFI("#epubcfi(/6/16[item9]!/4/2[pgepubid00007]/2/1:0)"))
        #expect(spine.href(for: cfi) == Fixture.chapter1Href)
        // The idref assertion wins when the index is stale.
        let stale = try #require(EPUBCFI("epubcfi(/6/2[item9]!/4/2)"))
        #expect(spine.href(for: stale) == Fixture.chapter1Href)
    }
}

@Suite("XHTML CFI resolution")
struct CFIDocumentTests {
    func chapter() throws -> CFIDocument { try CFIDocument(xhtml: Fixture.data(Fixture.chapter1)) }

    @Test func resolvesTheWebReadersChapterStart() throws {
        let doc = try chapter()
        let cfi = try #require(EPUBCFI("#epubcfi(/6/16[item9]!/4/2[pgepubid00007]/2/1:0)"))
        let point = try #require(doc.resolve(cfi))
        #expect(doc.text(from: point, count: 9) == "Chapter 1")
        #expect(point.textOffset == 2, "two newlines precede the heading inside the chapter div")
    }

    @Test func resolvesAMidParagraphOffset() throws {
        let doc = try chapter()
        // /4/2/4/1:1 is the first paragraph's text node, one UTF-16 unit in (after its newline).
        let cfi = try #require(EPUBCFI("epubcfi(/6/16!/4/2/4/1:1)"))
        let point = try #require(doc.resolve(cfi))
        #expect(doc.text(from: point, count: 20) == "I am by birth a Gene")
    }

    @Test func generatesTheSameCFIEpubJSWould() throws {
        let doc = try chapter()
        let cfi = try #require(EPUBCFI("epubcfi(/6/16!/4/2/4/1:1)"))
        let point = try #require(doc.resolve(cfi))
        let path = try #require(doc.cfiPath(at: point.textOffset))
        #expect(path.steps == [.init(4), .init(2, assertion: "pgepubid00007"), .init(4), .init(1)])
        #expect(path.offset == 1)
    }

    @Test func roundTripsEveryTextOffsetThroughACFI() throws {
        let doc = try chapter()
        for offset in stride(from: 0, to: doc.textLength, by: 997) {
            let path = try #require(doc.cfiPath(at: offset))
            let cfi = EPUBCFI.point(spineIndex: 7, spineItemID: "item9", documentSteps: path.steps, offset: path.offset)
            #expect(doc.resolve(cfi)?.textOffset == offset, "\(cfi)")
        }
    }

    @Test func mapsBetweenCFIAndProgression() throws {
        let doc = try chapter()
        let start = try #require(EPUBCFI("epubcfi(/6/16!/4/2/2/1:0)"))
        #expect(try #require(doc.progression(of: start)) < 0.001)
        let mid = try #require(doc.cfiPath(atProgression: 0.5))
        let midCFI = EPUBCFI.point(spineIndex: 7, spineItemID: nil, documentSteps: mid.steps, offset: mid.offset)
        let back = try #require(doc.progression(of: midCFI))
        #expect(abs(back - 0.5) < 0.01)
    }

    @Test func pointsAtAnElementResolveToItsFirstText() throws {
        let doc = try chapter()
        let cfi = try #require(EPUBCFI("epubcfi(/6/16!/4/2/4)"))
        let point = try #require(doc.resolve(cfi))
        #expect(doc.text(from: point, count: 4).trimmingCharacters(in: .whitespacesAndNewlines) == "I a")
    }

    @Test func rejectsPathsThatDoNotExist() throws {
        let doc = try chapter()
        let missingStep = try #require(EPUBCFI("epubcfi(/6/16!/4/2/9998/1:0)"))
        let pastEnd = try #require(EPUBCFI("epubcfi(/6/16!/4/2/4/1:999999)"))
        #expect(doc.resolve(missingStep) == nil)
        #expect(doc.resolve(pastEnd) == nil)
    }

    @Test func toleratesHTMLNamedEntities() throws {
        let xhtml = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>t</title></head><body><p>a&nbsp;b&mdash;c</p></body></html>"
        let doc = try CFIDocument(xhtml: Data(xhtml.utf8))
        let cfi = try #require(EPUBCFI("epubcfi(/6/2!/4/2/1:0)"))
        let point = try #require(doc.resolve(cfi))
        #expect(doc.text(from: point, count: 5) == "a\u{00A0}b\u{2014}c")
    }

    @Test func findsQuotedTextNearestAHint() throws {
        let doc = try chapter()
        let first = try #require(doc.find("my father", nearTextOffset: 0))
        let later = try #require(doc.find("my father", nearTextOffset: doc.textLength))
        #expect(first.textOffset < later.textOffset)
        #expect(doc.text(from: later, count: 9) == "my father")
    }
}
