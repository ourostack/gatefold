import ReadiumShared
import Testing
import GatefoldCore
@testable import Gatefold

/// A reopened book holds his saved words from the first frame, so a reflow that starts before the
/// page shows any words (an iPad relaunched in landscape lays out in portrait, then rotates) brings
/// him back to them. Build 15 held nothing then, and the spread settled two spreads early.
@MainActor
struct OpeningAnchorTests {
    private func saved(_ highlight: String?) throws -> Locator {
        let href = try #require(AnyURL(string: "OEBPS/chapter-5.xhtml"))
        return Locator(href: href, mediaType: .xhtml,
                       locations: .init(progression: 0.42),
                       text: .init(highlight: highlight))
    }

    @Test func theSavedWordsAreHeldFromTheFirstFrame() throws {
        let anchor = try #require(ReaderModel.openingAnchor(from: try saved("Quill   meadow\nlantern pebble")))
        #expect(anchor.href == "OEBPS/chapter-5.xhtml")
        #expect(anchor.progression == 0.42)
        #expect(anchor.text == "Quill meadow lantern pebble")
        // A restore that finds other words on screen jumps back to these.
        var keeper = AnchorKeeper(anchor: anchor)
        keeper.reflowWillBegin(.rotation)
        let elsewhere = VisibleRange(href: "OEBPS/chapter-5.xhtml", start: 0.30, end: 0.33, text: "Harbour kettle orchard")
        #expect(keeper.reflowDidSettle(visible: elsewhere) == .jump(anchor))
    }

    @Test func aPlaceWithoutWordsHoldsNothing() throws {
        #expect(ReaderModel.openingAnchor(from: try saved(nil)) == nil)
        #expect(ReaderModel.openingAnchor(from: try saved("   ")) == nil)
        #expect(ReaderModel.openingAnchor(from: nil) == nil)
    }
}
