#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import Testing
@testable import GatefoldCore

@Suite("Reopen picture in another paper or window")
struct ReopenAdaptTests {
    private func luma(_ c: PictureRecolor.RGB) -> Int { PictureRecolor.luma(c.r, c.g, c.b) }

    @Test func paperBecomesTheNewPaperAndInkTheNewInk() {
        let old = ReaderTheme.vellum.palette, new = ReaderTheme.midnight.palette
        let table = PictureRecolor.table(from: old, to: new)
        let paper = PictureRecolor.RGB(old.background), ink = PictureRecolor.RGB(old.text)
        #expect(table[luma(paper)] == PictureRecolor.RGB(new.background))
        #expect(table[luma(ink)] == PictureRecolor.RGB(new.text))
    }

    @Test func antialiasedEdgesLandBetween() {
        let old = ReaderTheme.daylight.palette, new = ReaderTheme.dusk.palette
        let table = PictureRecolor.table(from: old, to: new)
        let mid = table[128]
        let paper = luma(PictureRecolor.RGB(new.background)), ink = luma(PictureRecolor.RGB(new.text))
        #expect(luma(mid) > min(paper, ink) && luma(mid) < max(paper, ink))
    }

    @Test func beyondThePaperOrInkStaysAtThem() {
        // A pixel paler than the old paper (a white margin on vellum) is paper, not brighter than it.
        let table = PictureRecolor.table(from: ReaderTheme.vellum.palette, to: ReaderTheme.dusk.palette)
        #expect(table[255] == PictureRecolor.RGB(ReaderTheme.dusk.palette.background))
        #expect(table[0] == PictureRecolor.RGB(ReaderTheme.dusk.palette.text))
    }

    @Test func aSpreadGivesItsLeftPage() {
        let page = CGRect(x: 20, y: 40, width: 900, height: 500)
        #expect(ReopenFit.firstColumn(page: page, columns: 2) == CGRect(x: 20, y: 40, width: 450, height: 500))
        #expect(ReopenFit.firstColumn(page: page, columns: 1) == page)
    }

    @Test func aPortraitPageInLandscapeKeepsItsSizeAndCentres() {
        let column = CGRect(x: 106, y: 0, width: 608, height: 1180)
        let placed = ReopenFit.place(column: column, from: CGSize(width: 820, height: 1180), in: CGSize(width: 1180, height: 820))
        // Too tall for the landscape window: shrunk to fit its height, centred across.
        #expect(abs(placed.height - 820) < 0.5)
        #expect(abs(placed.midX - 590) < 0.5)
        #expect(placed.minY == 0)
    }

    @Test func aPageThatFitsIsNotScaled() {
        let column = CGRect(x: 16, y: 60, width: 434, height: 560)
        let placed = ReopenFit.place(column: column, from: CGSize(width: 466, height: 678), in: CGSize(width: 545, height: 951))
        #expect(placed.size == column.size)
        #expect(placed.minY == 60)
        #expect(abs(placed.midX - 272.5) < 0.5)
    }

    @Test func aSlipHangsBelowTheIsland() {
        let island = CGRect(x: 160, y: 11, width: 120, height: 37)
        #expect(PageSafeArea.slipTop(safeTop: 12, occlusions: [island], span: 16...424) == 48 + PageSafeArea.gap)
        // A camera off to one side of the slip leaves it at the safe area.
        #expect(PageSafeArea.slipTop(safeTop: 12, occlusions: [island], span: 300...440) == 12 + PageSafeArea.gap)
        // The folded Duo's tall status column is the status bar's, not a camera's.
        #expect(PageSafeArea.slipTop(safeTop: 12, occlusions: [CGRect(x: 400, y: 0, width: 66, height: 300)], span: 16...450) == 12 + PageSafeArea.gap)
    }
}
