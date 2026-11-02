import CoreGraphics
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

    /// Measured on the Duo with DeviceHub's "Partially Open": the fold stays vertical and reads inactive,
    /// and only the hinge says the device is bent. Bent is tabletop: the page above, the controls below.
    @Test func partiallyOpenIsTabletopWithThePageOnTopAndTheDeckBelow() {
        let size = CGSize(width: 951, height: 669)
        let fold = FoldRegion(frame: CGRect(x: 455.5, y: 0, width: 40, height: 669), isActive: false)
        let layout = ReaderLayoutResolver.resolve(.init(containerSize: size, division: fold, hinge: .partiallyOpen(angleDegrees: 127.8)))
        #expect(layout.posture == .tabletop)
        #expect(layout.columns == .one)
        #expect(layout.gutter == nil)
        #expect(layout.pageFrame.minY == 0)
        #expect(layout.pageFrame.width == 951)
        #expect(abs(layout.pageFrame.maxY - size.height / 2) <= ReaderLayoutResolver.tabletopPageInset)
        let deck = try! #require(layout.deck)
        #expect(deck.minY >= layout.pageFrame.maxY)
        #expect(deck.maxY == size.height)
        // Flat again, the same fold is a spread.
        #expect(ReaderLayoutResolver.resolve(.init(containerSize: size, division: fold, hinge: .fullyOpen)).posture == .spread)
        #expect(ReaderLayoutResolver.resolve(.init(containerSize: size, division: fold)).posture == .spread)
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

    @Test func theStatusBarAlsoPushes() {
        let out = PageSafeArea.clearingTop(layout(CGRect(x: 0, y: 0, width: 600, height: 800)), safeTop: 44, occlusions: [])
        #expect(out.pageFrame.minY == 44 + PageSafeArea.gap - PageSafeArea.textTopInset)
    }
}
