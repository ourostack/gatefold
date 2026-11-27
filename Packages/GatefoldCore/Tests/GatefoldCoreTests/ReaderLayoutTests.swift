#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import Testing
@testable import GatefoldCore

/// Sizes measured on the iPhone Duo (27.1) simulator and from Readium #903.
private let duoInnerWide = CGSize(width: 951, height: 545)
private let duoInnerTall = CGSize(width: 545, height: 951)
private let duoOuter = CGSize(width: 466, height: 678)

@Suite("Reader layout per posture")
struct ReaderLayoutTests {
    @Test func closedOuterScreenIsOnePage() {
        let layout = ReaderLayoutResolver.resolve(.init(containerSize: duoOuter))
        #expect(layout.posture == .single)
        #expect(layout.pageFrame == CGRect(origin: .zero, size: duoOuter))
        #expect(layout.gutter == nil)
        #expect(layout.deck == nil)
        #expect(layout.columns == .one)
    }

    @Test func openFlatWideIsASpreadWithTheGutterOnTheInactiveFold() {
        let fold = FoldRegion(frame: CGRect(x: 475.5, y: 0, width: 0, height: 545), isActive: false)
        let layout = ReaderLayoutResolver.resolve(.init(containerSize: duoInnerWide, division: fold, hinge: .fullyOpen))
        #expect(layout.posture == .spread)
        #expect(layout.columns == .two)
        let gutter = try! #require(layout.gutter)
        #expect(gutter.midX == 475.5)
        #expect(gutter.width >= ReaderLayoutResolver.minimumGutter)
        #expect(layout.spineShadow == 0)
    }

    @Test func aSpreadWidensTheGutterAroundAnActiveFoldAndShadesTheSpine() {
        let fold = FoldRegion(frame: CGRect(x: 450, y: 0, width: 51, height: 545), isActive: true)
        let layout = ReaderLayoutResolver.resolve(.init(containerSize: duoInnerWide, division: fold, hinge: .partiallyOpen(angleDegrees: 120), forced: .spread))
        #expect(layout.posture == .spread)
        let gutter = try! #require(layout.gutter)
        #expect(gutter.minX <= 450)
        #expect(gutter.maxX >= 501)
        #expect(layout.spineShadow > 0.5)
    }

    /// gatefold#646. Measured on the Duo with DeviceHub's "Partially Open" and no turn: the fold stays vertical and
    /// reads inactive, and only the hinge says the device is bent. Bent with the spine upright is the book posture:
    /// a page each side of the fold, as a paper book sits, never one column running across the hinge with the
    /// controls across the other half (the hunt at 617eeb37: about 6 lines readable).
    @Test func halfOpenWithTheSpineUprightIsASpreadWithTheGutterOnTheFold() {
        let size = CGSize(width: 951, height: 669)
        let fold = FoldRegion(frame: CGRect(x: 455.5, y: 0, width: 40, height: 669), isActive: false)
        let layout = ReaderLayoutResolver.resolve(.init(containerSize: size, division: fold, hinge: .partiallyOpen(angleDegrees: 127.8)))
        #expect(layout.posture == .spread)
        #expect(layout.columns == .two)
        #expect(layout.deck == nil)
        #expect(layout.pageFrame == CGRect(origin: .zero, size: size))
        let gutter = try! #require(layout.gutter)
        #expect(gutter.midX == fold.frame.midX)
        #expect(layout.spineShadow > 0.5)
        // Nearly flat, and flat again, the same fold is the same spread: opening it moves nothing (gatefold#647).
        #expect(ReaderLayoutResolver.resolve(.init(containerSize: size, division: fold, hinge: .partiallyOpen(angleDegrees: 172.7))).posture == .spread)
        #expect(ReaderLayoutResolver.resolve(.init(containerSize: size, division: fold, hinge: .fullyOpen)).posture == .spread)
        #expect(ReaderLayoutResolver.resolve(.init(containerSize: size, division: fold)).posture == .spread)
    }

    /// Turned on its side first, the Duo's fold runs across the screen, and bent it stands on a table: the page above
    /// the fold, the controls below (the hunt at 617eeb37: window 669 x 951, page 669 x 439.7, posture tabletop).
    @Test func halfOpenWithTheFoldAcrossIsTabletop() {
        let size = CGSize(width: 669, height: 951)
        let fold = FoldRegion(frame: CGRect(x: 0, y: 455.5, width: 669, height: 40), isActive: false)
        let layout = ReaderLayoutResolver.resolve(.init(containerSize: size, division: fold, hinge: .partiallyOpen(angleDegrees: 110)))
        #expect(layout.posture == .tabletop)
        #expect(layout.pageFrame.maxY <= fold.frame.minY)
        #expect(layout.deck.map { $0.minY >= fold.frame.maxY } == true)
    }

    /// Real unfold at bc72d70 (job 132947504798), 2f5fd1d and c60ef7e: folded shut from tabletop, the hinge read
    /// "closed" while the app was still on the wide inner screen, and the reader laid out a spread there (an unfold, with
    /// its rising leaf) for the second before the app moved to the cover. That spread's restore and the cover's ran over
    /// each other, and the cover's was judged on a page still laid out for the spread: "a posture change lost the
    /// reader's words". A shut inner screen shows nothing, so it keeps the layout it had until the app moves.
    @Test func aShutInnerScreenKeepsItsLayoutUntilTheAppMoves() {
        let inner = CGSize(width: 951, height: 669)
        let fold = FoldRegion(frame: CGRect(x: 455.5, y: 0, width: 40, height: 669), isActive: false)
        let shut = ReaderLayoutResolver.resolve(.init(containerSize: inner, division: fold, hinge: .closed, shown: .tabletop))
        #expect(shut.posture == .tabletop, "a shut screen laid out \(shut.posture)")
        #expect(shut == ReaderLayoutResolver.resolve(.init(containerSize: inner, division: fold, forced: .tabletop)))
        // Folded straight from flat, with no tabletop on the way, the spread it had stays.
        #expect(ReaderLayoutResolver.resolve(.init(containerSize: inner, division: fold, hinge: .closed, shown: .spread)).posture == .spread)
        // Arriving from the cover, a frame on the inner screen whose hinge still reads closed is a spread, as before.
        #expect(ReaderLayoutResolver.resolve(.init(containerSize: inner, division: fold, hinge: .closed, shown: .single)).posture == .spread)
        // On the cover (the fold as the Duo still reports it in the first frame there), one page, whatever was shown.
        let coverFold = FoldRegion(frame: CGRect(x: 455.5, y: 0, width: 40, height: 669), isActive: false)
        #expect(ReaderLayoutResolver.resolve(.init(containerSize: duoOuter, division: coverFold, hinge: .closed, shown: .spread)).posture == .single)
        #expect(ReaderLayoutResolver.resolve(.init(containerSize: duoOuter, division: coverFold, hinge: .closed, shown: .tabletop)).posture == .single)
        // Opened again, the hinge decides.
        #expect(ReaderLayoutResolver.resolve(.init(containerSize: inner, division: fold, hinge: .fullyOpen, shown: .tabletop)).posture == .spread)
    }

    @Test func aBentHingeWithoutAFoldOnThisScreenChangesNothing() {
        // The folded Duo's cover screen has no fold in it, whatever the hinge says.
        #expect(ReaderLayoutResolver.resolve(.init(containerSize: duoOuter, hinge: .partiallyOpen(angleDegrees: 90))).posture == .single)
    }

    @Test func tabletopPutsThePageAboveTheFoldAndTheDeckBelow() {
        let fold = FoldRegion(frame: CGRect(x: 0, y: 460, width: 545, height: 30), isActive: true)
        let layout = ReaderLayoutResolver.resolve(.init(containerSize: duoInnerTall, division: fold, hinge: .partiallyOpen(angleDegrees: 100)))
        #expect(layout.posture == .tabletop)
        #expect(layout.pageFrame.maxY <= 460)
        let deck = try! #require(layout.deck)
        #expect(deck.minY >= 490)
        #expect(deck.minY >= 490)
        #expect(deck.maxY == 951)
        #expect(layout.columns == .one)
    }

    /// The last line stops 16 pt above the hinge instead of running into its shadow.
    @Test func tabletopLeavesSixteenPointsAboveTheFold() {
        let fold = FoldRegion(frame: CGRect(x: 0, y: 460, width: 545, height: 30), isActive: true)
        let layout = ReaderLayoutResolver.resolve(.init(containerSize: duoInnerTall, division: fold, hinge: .partiallyOpen(angleDegrees: 100)))
        #expect(layout.pageFrame.maxY == 444)
        let midline = ReaderLayoutResolver.resolve(.init(containerSize: duoInnerTall, forced: .tabletop))
        #expect(midline.pageFrame.maxY == duoInnerTall.height / 2 - 16)
    }

    @Test func openFlatTallIsOneTallPageEvenThoughTheFoldIsHorizontal() {
        let fold = FoldRegion(frame: CGRect(x: 0, y: 475.5, width: 545, height: 0), isActive: false)
        let layout = ReaderLayoutResolver.resolve(.init(containerSize: duoInnerTall, division: fold, hinge: .fullyOpen))
        #expect(layout.posture == .single)
        #expect(layout.deck == nil)
    }

    @Test func iPadLandscapeWithoutAFoldIsASpreadSplitDownTheMiddle() {
        let size = CGSize(width: 1376, height: 1032)
        let layout = ReaderLayoutResolver.resolve(.init(containerSize: size))
        #expect(layout.posture == .spread)
        #expect(layout.gutter?.midX == 688)
    }

    @Test func phoneLandscapeAndNarrowSplitViewStayOnOnePage() {
        #expect(ReaderLayoutResolver.resolve(.init(containerSize: CGSize(width: 874, height: 402))).posture == .single)
        let fold = FoldRegion(frame: CGRect(x: 230, y: 0, width: 0, height: 545), isActive: false)
        #expect(ReaderLayoutResolver.resolve(.init(containerSize: CGSize(width: 470, height: 545), division: fold)).posture == .single)
    }

    @Test func aForcedPostureWinsForTestsAndScreenshots() {
        let layout = ReaderLayoutResolver.resolve(.init(containerSize: duoInnerTall, forced: .tabletop))
        #expect(layout.posture == .tabletop)
        #expect(layout.deck != nil)
        let spread = ReaderLayoutResolver.resolve(.init(containerSize: duoInnerWide, forced: .spread))
        #expect(spread.gutter?.midX == duoInnerWide.width / 2)
    }

    /// A screen that can't hold a spread is one page even when a spread is forced (gatefold#303: the UI
    /// tests' hidden posture switch, tapped by a review driver's top-centre tap, laid the Duo's 466 pt cover
    /// screen and a 1032 x 1376 portrait iPad out as two cramped columns until the book was closed).
    @Test(arguments: [
        ("Duo cover screen", duoOuter),
        ("Duo cover screen, status bar up", CGSize(width: 466, height: 616)),
        ("Duo inner screen, upright", duoInnerTall),
        ("iPad portrait", CGSize(width: 1032, height: 1376)),
        ("iPad 11-inch portrait", CGSize(width: 834, height: 1194)),
        ("phone landscape", CGSize(width: 600, height: 402)),
    ])
    func aForcedSpreadOnAOnePageScreenIsOnePage(name: String, size: CGSize) {
        let layout = ReaderLayoutResolver.resolve(.init(containerSize: size, forced: .spread))
        #expect(layout.posture == .single, "\(name)")
        #expect(layout.columns == .one, "\(name)")
        #expect(layout.gutter == nil, "\(name)")
    }

    @Test func aForcedSpreadStillWinsWhereASpreadFits() {
        for size in [duoInnerWide, CGSize(width: 951, height: 669), CGSize(width: 1376, height: 1032), CGSize(width: 1180, height: 820)] {
            let layout = ReaderLayoutResolver.resolve(.init(containerSize: size, forced: .spread))
            #expect(layout.posture == .spread, "\(size)")
            #expect(layout.columns == .two, "\(size)")
        }
    }

    @Test func aFoldOutsideTheContainerIsIgnored() {
        let fold = FoldRegion(frame: CGRect(x: 2000, y: 0, width: 0, height: 545), isActive: false)
        let layout = ReaderLayoutResolver.resolve(.init(containerSize: duoOuter, division: fold))
        #expect(layout.posture == .single)
    }
}

@Suite struct PageSafeAreaTests {
    func layout(_ frame: CGRect) -> ReaderLayout {
        ReaderLayout(posture: .single, pageFrame: frame, gutter: nil, deck: nil, columns: .one, spineShadow: 0)
    }

    @Test func theFirstLineClearsTheCamera() {
        let out = PageSafeArea.clearingTop(layout(CGRect(x: 0, y: 0, width: 600, height: 800)), safeTop: 20,
                                           occlusions: [CGRect(x: 280, y: 12, width: 40, height: 40)])
        #expect(out.pageFrame.minY + PageSafeArea.textTopInset == 52 + PageSafeArea.gap)
        #expect(out.pageFrame.maxY == 800, "the page keeps its foot")
    }

    @Test func aCameraOutsideThePageChangesNothing() {
        let l = layout(CGRect(x: 0, y: 0, width: 600, height: 800))
        #expect(PageSafeArea.clearingTop(l, safeTop: 10, occlusions: [CGRect(x: 700, y: 10, width: 40, height: 40)]) == l)
    }

    // Paging, the page moves down to clear the camera; scrolling, it stays at the screen's top so the text runs
    // there, and carries the same clearance inside it, so a chapter's first line still rests below the camera.
    @Test func aScrollingPageKeepsItsTopAndCarriesTheClearance() {
        let l = layout(CGRect(x: 0, y: 0, width: 466, height: 678))
        let paged = PageSafeArea.placing(l, shift: 38, scrolling: false)
        #expect(paged.pageFrame == CGRect(x: 0, y: 38, width: 466, height: 640))
        #expect(paged.textTopClearance == 0)
        let scrolled = PageSafeArea.placing(l, shift: 38, scrolling: true)
        #expect(scrolled.pageFrame == l.pageFrame)
        #expect(scrolled.textTopClearance == 38)
        #expect(scrolled.pageFrame.minY + PageSafeArea.textTopInset + scrolled.textTopClearance
                == paged.pageFrame.minY + PageSafeArea.textTopInset, "the first line rests where it would on a page")
        #expect(PageSafeArea.placing(l, shift: -20, scrolling: true) == l, "no clearance to carry")
    }

    @Test func theStatusBarAlsoPushes() {
        let out = PageSafeArea.clearingTop(layout(CGRect(x: 0, y: 0, width: 600, height: 800)), safeTop: 44, occlusions: [])
        #expect(out.pageFrame.minY == 44 + PageSafeArea.gap - PageSafeArea.textTopInset)
    }
}
