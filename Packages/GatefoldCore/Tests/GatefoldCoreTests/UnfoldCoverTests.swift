import Foundation
import Testing
@testable import GatefoldCore

/// The unfold swings from a picture of the page the reader was on. On a real Duo, opening the hinge
/// moves the app from the cover screen to the inner screen, so the picture is taken when the hinge
/// starts to move. Without a usable picture the unfold falls back to a plain, correct reflow.
@Suite("Which picture of the old page the unfold uses")
struct UnfoldCoverTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func aFreshPictureTakenAsTheHingeMovedWins() {
        let held = HeldPage(book: "frankenstein", takenAt: now.addingTimeInterval(-1.2))
        #expect(UnfoldCover.choose(held: held, liveAvailable: true, book: "frankenstein", now: now) == .held)
        #expect(UnfoldCover.choose(held: held, liveAvailable: false, book: "frankenstein", now: now) == .held)
    }

    @Test func withoutAHeldPictureTheLivePageIsUsed() {
        #expect(UnfoldCover.choose(held: nil, liveAvailable: true, book: "frankenstein", now: now) == .live)
    }

    @Test func withNeitherTheUnfoldIsAPlainReflow() {
        #expect(UnfoldCover.choose(held: nil, liveAvailable: false, book: "frankenstein", now: now) == .none)
    }

    @Test func aStalePictureIsNotUsed() {
        let held = HeldPage(book: "frankenstein", takenAt: now.addingTimeInterval(-(UnfoldCover.heldFreshFor + 1)))
        #expect(UnfoldCover.choose(held: held, liveAvailable: true, book: "frankenstein", now: now) == .live)
        #expect(UnfoldCover.choose(held: held, liveAvailable: false, book: "frankenstein", now: now) == .none)
    }

    @Test func anotherBooksPictureIsNotUsed() {
        let held = HeldPage(book: "dracula", takenAt: now)
        #expect(UnfoldCover.choose(held: held, liveAvailable: false, book: "frankenstein", now: now) == .none)
    }

    @Test func aPictureFromTheFutureIsNotTrusted() {
        let held = HeldPage(book: "frankenstein", takenAt: now.addingTimeInterval(30))
        #expect(UnfoldCover.choose(held: held, liveAvailable: true, book: "frankenstein", now: now) == .live)
    }

    @Test func theHeldPictureSitsWhereTheLeftPageWillBe() {
        // Taken on the 426 pt cover screen, shown on a wider inner screen: same height, its own width,
        // from the leading edge, never wider than the new page.
        let frame = UnfoldCover.heldFrame(picture: CGSize(width: 426, height: 900), in: CGRect(x: 0, y: 0, width: 1100, height: 900))
        #expect(frame == CGRect(x: 0, y: 0, width: 426, height: 900))
        let tall = UnfoldCover.heldFrame(picture: CGSize(width: 426, height: 1800), in: CGRect(x: 10, y: 0, width: 1100, height: 900))
        #expect(tall == CGRect(x: 10, y: 0, width: 213, height: 900))
        let wide = UnfoldCover.heldFrame(picture: CGSize(width: 2000, height: 900), in: CGRect(x: 0, y: 0, width: 1100, height: 900))
        #expect(wide.width == 1100)
    }
}
