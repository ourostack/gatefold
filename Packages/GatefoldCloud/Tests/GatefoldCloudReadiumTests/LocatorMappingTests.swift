#if canImport(ReadiumShared)
import Foundation
import GatefoldCloud
import GatefoldCloudReadium
import ReadiumShared
import Testing

@Suite("Readium Locator ⇄ BookLocation")
struct LocatorMappingTests {
    let href = "OEBPS/4328224471496264690_84-h-6.htm.xhtml"

    @Test func readsTheNavigatorLocator() throws {
        let locator = Locator(href: try #require(AnyURL(string: "/" + href)), mediaType: .xhtml, title: "Chapter 1",
                              locations: .init(progression: 0.5, totalProgression: 0.12),
                              text: .init(after: "I am by birth", highlight: nil))
        let location = BookLocation(locator)
        #expect(location.href == href)
        #expect(location.progression == 0.5)
        #expect(location.totalProgression == 0.12)
        #expect(location.cfi == nil)
        #expect(location.textAfter == "I am by birth")
    }

    @Test func picksUpACFIInOtherLocations() throws {
        let locator = Locator(href: try #require(AnyURL(string: href)), mediaType: .xhtml,
                              locations: .init(progression: 0, otherLocations: ["cfi": .string("epubcfi(/6/16[item9]!/4/2/1:0)")]))
        #expect(BookLocation(locator).cfi == "epubcfi(/6/16[item9]!/4/2/1:0)")
    }

    @Test func decodesPercentEncodedHrefs() throws {
        let locator = Locator(href: try #require(AnyURL(string: "OEBPS/Chapter%20One.xhtml")), mediaType: .xhtml)
        #expect(BookLocation(locator).href == "OEBPS/Chapter One.xhtml")
    }

    @Test func buildsALocatorTheNavigatorCanGoTo() throws {
        let location = BookLocation(href: "OEBPS/Chapter One.xhtml", progression: 0.25, totalProgression: 0.4,
                                    cfi: "epubcfi(/6/16[item9]!/4/2/1:0)", textAfter: "It was on a dreary night")
        let locator = try #require(Locator(location, title: "Chapter 5"))
        #expect(locator.href.string == "OEBPS/Chapter%20One.xhtml")
        #expect(locator.mediaType == .xhtml)
        #expect(locator.locations.progression == 0.25)
        #expect(locator.locations.totalProgression == 0.4)
        #expect(locator.locations.otherLocations["cfi"] == .string("epubcfi(/6/16[item9]!/4/2/1:0)"))
        #expect(locator.text.after == "It was on a dreary night")
        #expect(BookLocation(locator) == location, "round trip")
    }
}
#endif
