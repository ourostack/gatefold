import Testing
@testable import GatefoldCloud

@Suite("EPUB CFI parsing")
struct EPUBCFITests {
    @Test func parsesWebReaderPointWithAssertions() throws {
        let cfi = try #require(EPUBCFI("epubcfi(/6/16[item9]!/4/2[pgepubid00007]/2/1:0)"))
        #expect(cfi.packageSteps == [.init(6), .init(16, assertion: "item9")])
        #expect(cfi.documentSteps == [.init(4), .init(2, assertion: "pgepubid00007"), .init(2), .init(1)])
        #expect(cfi.offset == 0)
        #expect(cfi.spineIndex == 7)
        #expect(cfi.spineItemID == "item9")
        #expect(cfi.partialCFI == "/4/2[pgepubid00007]/2/1:0")
    }

    @Test func roundTripsItsSourceStringExactly() throws {
        for raw in [
            "epubcfi(/6/16[item9]!/4/2[pgepubid00007]/2/1:0)",
            "epubcfi(/6/40!/4/2[ch12]/18[p]/10[x]/6/3:47)",
            "epubcfi(/6/4!/4/2/1:0)",
            "epubcfi(/6/4[chap^[1^]]!/4/10)",
        ] {
            #expect(EPUBCFI(raw)?.description == raw)
        }
    }

    @Test func acceptsEveryPocketBookPrefixForm() throws {
        let expected = "epubcfi(/6/40!/4/2[ch12]/18[p]/10[x]/6/3:47)"
        for raw in [
            "#epubcfi(/6/40!/4/2[ch12]/18[p]/10[x]/6/3:47)",
            "pbr:/external##epubcfi(/6/40!/4/2[ch12]/18[p]/10[x]/6/3:47)",
            "pbr:/webkit?##epubcfi(/6/40!/4/2[ch12]/18[p]/10[x]/6/3:47)",
            "epubcfi(/6/40!/4/2[ch12]/18[p]/10[x]/6/3:47)",
            "  #epubcfi(/6/40!/4/2[ch12]/18[p]/10[x]/6/3:47)\n",
        ] {
            #expect(EPUBCFI(raw)?.description == expected, "\(raw)")
        }
    }

    @Test func rejectsMalformedInput() {
        for raw in ["", "epubcfi()", "epubcfi(/6/4!", "epubcfi(/a/4!/2)", "pbr:/word?page=11&offs=518", "#pdfloc(abc,3)", "epubcfi(/6/4!/4/2[unterminated)"] {
            #expect(EPUBCFI(raw) == nil, "\(raw)")
        }
    }

    @Test func parsesRangeIntoTwoPoints() throws {
        let range = try #require(EPUBCFI.range("epubcfi(/6/4[c1]!/4/2,/1:0,/1:20)"))
        #expect(range.start.description == "epubcfi(/6/4[c1]!/4/2/1:0)")
        #expect(range.end.description == "epubcfi(/6/4[c1]!/4/2/1:20)")
        #expect(EPUBCFI.range("epubcfi(/6/4!/4/2/1:0)") == nil)
    }

    @Test func ordersLikeEpubJS() throws {
        let a = try #require(EPUBCFI("epubcfi(/6/8[item5]!/4/2[x]/16/1:322)"))
        let b = try #require(EPUBCFI("epubcfi(/6/10[item6]!/4/2[y]/2/1:0)"))
        let c = try #require(EPUBCFI("epubcfi(/6/10[item6]!/4/2[y]/14/1:1500)"))
        let d = try #require(EPUBCFI("epubcfi(/6/10!/4/2/14/1:1501)"))
        let e = try #require(EPUBCFI("epubcfi(/6/10!/4/2/14)"))
        #expect(a < b)
        #expect(b < c)
        #expect(c < d)
        #expect(e < c, "an element step sorts before a deeper text point inside it")
        #expect([d, a, c, b].sorted() == [a, b, c, d])
    }

    @Test func buildsAPointFromSpinePositionAndDocumentPath() {
        let cfi = EPUBCFI.point(
            spineStep: 6, spineIndex: 7, spineItemID: "item9",
            documentSteps: [.init(4), .init(2, assertion: "pgepubid00007"), .init(2), .init(1)],
            offset: 0
        )
        #expect(cfi.description == "epubcfi(/6/16[item9]!/4/2[pgepubid00007]/2/1:0)")
    }
}

@Suite("PocketBook anchors")
struct PocketBookAnchorTests {
    @Test func classifiesEveryKnownForm() {
        #expect(PocketBookAnchor("#epubcfi(/6/4!/4/2/1:0)").cfi?.description == "epubcfi(/6/4!/4/2/1:0)")
        #expect(PocketBookAnchor("#epubcfi(/6/4!/4/2/1:0)").style == .web)
        #expect(PocketBookAnchor("pbr:/external##epubcfi(/6/4!/4/2/1:0)").style == .external)
        #expect(PocketBookAnchor("pbr:/webkit?##epubcfi(/6/4!/4/2/1:0)").style == .device)
        #expect(PocketBookAnchor("pbr:/word?page=11&offs=518") == .word(page: 11, offset: 518))
        #expect(PocketBookAnchor("pbr:/page?page=36&offs=123") == .page(page: 36, offset: 123))
        #expect(PocketBookAnchor("pbr:/page?page=35##pdfloc(56f8619536655be4a1541a40c5702d32,35)") == .pdf(fastHash: "56f8619536655be4a1541a40c5702d32", pageIndex: 35))
        #expect(PocketBookAnchor("#pdfloc(abc,0)") == .pdf(fastHash: "abc", pageIndex: 0))
        #expect(PocketBookAnchor("nonsense") == .unknown("nonsense"))
    }

    @Test func writesTheFormsEachClientExpects() throws {
        let cfi = try #require(EPUBCFI("epubcfi(/6/16[item9]!/4/2[pgepubid00007]/2/1:0)"))
        #expect(PocketBookAnchor.string(for: cfi, style: .web) == "#epubcfi(/6/16[item9]!/4/2[pgepubid00007]/2/1:0)")
        #expect(PocketBookAnchor.string(for: cfi, style: .external) == "pbr:/external##epubcfi(/6/16[item9]!/4/2[pgepubid00007]/2/1:0)")
        #expect(PocketBookAnchor.string(for: cfi, style: .device) == "pbr:/webkit?##epubcfi(/6/16[item9]!/4/2[pgepubid00007]/2/1:0)")
    }
}
