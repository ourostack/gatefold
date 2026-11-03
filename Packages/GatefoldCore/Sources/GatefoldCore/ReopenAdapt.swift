import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A reopen picture taken in one paper, shown in another: the page is ink on paper, so each pixel is
/// mapped by how far it lies from the old paper towards the old ink, onto the new paper and ink.
/// The live page fades in over it a few seconds later, so the picture need only read as his page.
public enum PictureRecolor {
    public struct RGB: Equatable, Sendable {
        public var r: UInt8, g: UInt8, b: UInt8
        public init(r: UInt8, g: UInt8, b: UInt8) { self.r = r; self.g = g; self.b = b }
        public init(_ hex: UInt32) { self.init(r: UInt8((hex >> 16) & 0xFF), g: UInt8((hex >> 8) & 0xFF), b: UInt8(hex & 0xFF)) }
    }

    /// Rec. 601 luma, 0–255: what a pixel's distance from paper towards ink is measured in.
    public static func luma(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Int {
        (299 * Int(r) + 587 * Int(g) + 114 * Int(b)) / 1000
    }

    /// For each luma 0–255 of the old picture, the colour it takes in the new paper.
    public static func table(from old: ThemePalette, to new: ThemePalette) -> [RGB] {
        let oldPaper = RGB(old.background), oldInk = RGB(old.text)
        let newPaper = RGB(new.background), newInk = RGB(new.text)
        let p = Double(luma(oldPaper.r, oldPaper.g, oldPaper.b)), i = Double(luma(oldInk.r, oldInk.g, oldInk.b))
        func mix(_ a: UInt8, _ b: UInt8, _ t: Double) -> UInt8 { UInt8(max(0, min(255, (Double(a) + (Double(b) - Double(a)) * t).rounded()))) }
        return (0..<256).map { l in
            let t = p == i ? 0 : max(0, min(1, (Double(l) - p) / (i - p)))
            return RGB(r: mix(newPaper.r, newInk.r, t), g: mix(newPaper.g, newInk.g, t), b: mix(newPaper.b, newInk.b, t))
        }
    }
}

/// Where a page pictured in one window goes in a window of another size (the iPad turned, a Duo
/// opened or closed between sessions): its first column, at the same distance from the top, centred,
/// shrunk only if it would not fit.
public enum ReopenFit {
    /// The first column of the pictured page: all of it on a single page, the left half of a spread.
    public static func firstColumn(page: CGRect, columns: Int) -> CGRect {
        guard columns >= 2 else { return page }
        return CGRect(x: page.minX, y: page.minY, width: page.width / 2, height: page.height)
    }

    public static func place(column: CGRect, from source: CGSize, in target: CGSize) -> CGRect {
        guard column.width > 0, column.height > 0 else { return .zero }
        let side = max(0, min(column.minX, source.width - column.maxX))
        let below = max(0, source.height - column.maxY)
        let roomWide = max(1, target.width - 2 * side)
        let roomTall = max(1, target.height - column.minY - below)
        let scale = min(1, roomWide / column.width, roomTall / column.height)
        let size = CGSize(width: column.width * scale, height: column.height * scale)
        return CGRect(x: (target.width - size.width) / 2, y: min(column.minY, max(0, target.height - size.height)), width: size.width, height: size.height)
    }
}

extension PageSafeArea {
    /// The top of a slip hung from the top of the screen: below the status bar's room and below any
    /// camera housing the system reports there (a Dynamic Island hides from the safe area once the
    /// status bar does, but not from the occlusion regions).
    public static func slipTop(safeTop: CGFloat, occlusions: [CGRect], span: ClosedRange<CGFloat>) -> CGFloat {
        let covered = occlusions
            .filter { $0.minY < 80 && $0.height <= 120 && $0.maxX > span.lowerBound && $0.minX < span.upperBound }
            .map(\.maxY)
        return max(safeTop, covered.max() ?? 0) + gap
    }
}
