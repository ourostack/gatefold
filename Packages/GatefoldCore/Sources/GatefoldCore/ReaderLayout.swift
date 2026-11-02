import Foundation
import CoreGraphics

/// The fold of a foldable display, as `GeometryProxy.reservedRegions(kind: .division, options: .includeInactive)`
/// reports it, in the reader container's coordinates. When the device is flat the region is inactive and may
/// have zero width.
public struct FoldRegion: Equatable, Sendable {
    public var frame: CGRect
    public var isActive: Bool

    public init(frame: CGRect, isActive: Bool) {
        self.frame = frame
        self.isActive = isActive
    }

    /// A fold that runs top to bottom, like a book's spine.
    var isVertical: Bool { frame.height > frame.width }
}

/// The hinge, as `onHingeChange` reports it. It drives the spine shadow, and one layout decision: a bent
/// device with a fold on this screen stands as a tabletop (the division region alone can't say so; the
/// Duo reports its fold inactive whether flat or half open).
public enum HingeState: Equatable, Sendable {
    case none
    case closed
    case partiallyOpen(angleDegrees: Double)
    case fullyOpen
}

/// How the reader presents the book.
public enum Posture: String, CaseIterable, Sendable {
    /// One page.
    case single
    /// Two facing pages with the gutter on the fold.
    case spread
    /// Page above the fold, a control deck below it.
    case tabletop
}

/// How many columns Readium should lay out.
public enum ColumnCount: String, Sendable {
    case one
    case two
}

public struct LayoutInput: Equatable, Sendable {
    public var containerSize: CGSize
    public var division: FoldRegion?
    public var hinge: HingeState
    /// Overrides the posture, for UI tests and screenshots.
    public var forced: Posture?

    public init(containerSize: CGSize, division: FoldRegion? = nil, hinge: HingeState = .none, forced: Posture? = nil) {
        self.containerSize = containerSize
        self.division = division
        self.hinge = hinge
        self.forced = forced
    }
}

public struct ReaderLayout: Equatable, Sendable {
    public var posture: Posture
    /// Where the page (the navigator) goes.
    public var pageFrame: CGRect
    /// The spine between facing pages; nothing tappable may sit here.
    public var gutter: CGRect?
    /// The tabletop control deck.
    public var deck: CGRect?
    public var columns: ColumnCount
    /// 0...1, a shadow at the spine that deepens as the device bends. Effect only.
    public var spineShadow: Double
}

public enum ReaderLayoutResolver {
    /// The narrowest gutter that still reads as a spine.
    public static let minimumGutter: CGFloat = 44
    /// Below this width a spread's pages get too narrow to read (Split View, narrow windows).
    public static let minimumSpreadWidth: CGFloat = 700
    /// Clear space either side of an active fold.
    static let foldMargin: CGFloat = 12
    /// In tabletop the page's last line stops this far above the fold, clear of the hinge's shadow.
    static let tabletopPageInset: CGFloat = 16

    public static func resolve(_ input: LayoutInput) -> ReaderLayout {
        let bounds = CGRect(origin: .zero, size: input.containerSize)
        let fold = input.division.flatMap { region -> FoldRegion? in
            // A fold must lie inside the container (it can be reported for another window or screen).
            let probe = region.frame.width == 0 || region.frame.height == 0
                ? region.frame.insetBy(dx: -0.5, dy: -0.5)
                : region.frame
            return bounds.intersects(probe) ? region : nil
        }
        let shadow = spineShadow(for: input.hinge)

        switch input.forced ?? posture(bounds: bounds, fold: fold, hinge: input.hinge) {
        case .single:
            return ReaderLayout(posture: .single, pageFrame: bounds, gutter: nil, deck: nil, columns: .one, spineShadow: 0)
        case .spread:
            let spine: CGRect
            if let fold, fold.isVertical {
                let width = max(minimumGutter, fold.isActive ? fold.frame.width + 2 * foldMargin : 0)
                spine = CGRect(x: fold.frame.midX - width / 2, y: 0, width: width, height: bounds.height)
            } else {
                spine = CGRect(x: bounds.midX - minimumGutter / 2, y: 0, width: minimumGutter, height: bounds.height)
            }
            return ReaderLayout(posture: .spread, pageFrame: bounds, gutter: spine, deck: nil, columns: .two, spineShadow: shadow)
        case .tabletop:
            let foldBand: CGRect
            if let fold, !fold.isVertical {
                foldBand = fold.frame.insetBy(dx: 0, dy: -foldMargin)
            } else {
                // No real fold (forced or simulated): split at the screen's midline.
                foldBand = CGRect(x: 0, y: bounds.midY - foldMargin, width: bounds.width, height: 2 * foldMargin)
            }
            let page = CGRect(x: 0, y: 0, width: bounds.width, height: max(0, foldBand.minY + foldMargin - tabletopPageInset))
            let deck = CGRect(x: 0, y: foldBand.maxY, width: bounds.width, height: max(0, bounds.maxY - foldBand.maxY))
            return ReaderLayout(posture: .tabletop, pageFrame: page, gutter: nil, deck: deck, columns: .one, spineShadow: 0)
        }
    }

    private static func posture(bounds: CGRect, fold: FoldRegion?, hinge: HingeState) -> Posture {
        let wide = bounds.width > bounds.height && bounds.width >= minimumSpreadWidth
        if let fold {
            // Partially open: stood on a table, the page on the top half, the controls on the bottom.
            if case .partiallyOpen = hinge { return .tabletop }
            if fold.isVertical {
                return wide ? .spread : .single
            }
            // A horizontal fold: tabletop only while the device is actually bent.
            return fold.isActive ? .tabletop : .single
        }
        // No fold: iPad and Mac. Facing pages when there is room for two readable pages.
        return wide && bounds.width >= 900 ? .spread : .single
    }

    private static func spineShadow(for hinge: HingeState) -> Double {
        guard case let .partiallyOpen(angle) = hinge else { return 0 }
        return min(1, max(0, (180 - angle) / 90))
    }
}

/// Page text never starts under the status bar or a camera: the folded Duo's cutout sits inside the
/// page's top margin, so the page itself moves down until its first line is clear.
public enum PageSafeArea {
    /// The first line's distance below the page's top edge (Readium's top inset, compact size).
    public static let textTopInset: CGFloat = 28
    /// Breathing room between the lowest thing the system covers and the first line.
    public static let gap: CGFloat = 8

    public static func clearingTop(_ layout: ReaderLayout, safeTop: CGFloat, occlusions: [CGRect]) -> ReaderLayout {
        let page = layout.pageFrame
        let band = page.minY + textTopInset + 24
        let covered = occlusions
            .filter { $0.minY < band && $0.maxX > page.minX && $0.minX < page.maxX }
            .map(\.maxY)
        let needed = max(safeTop, covered.max() ?? 0) + gap
        return shifted(layout, by: needed - (page.minY + textTopInset))
    }

    /// The page moved down by `shift` points, keeping its foot.
    public static func shifted(_ layout: ReaderLayout, by shift: CGFloat) -> ReaderLayout {
        guard shift > 0 else { return layout }
        let page = layout.pageFrame
        var out = layout
        out.pageFrame = CGRect(x: page.minX, y: page.minY + shift, width: page.width, height: max(0, page.height - shift))
        if let gutter = layout.gutter {
            out.gutter = CGRect(x: gutter.minX, y: gutter.minY + shift, width: gutter.width, height: max(0, gutter.height - shift))
        }
        return out
    }
}

/// A picture of the page taken when the hinge started to move, before the app changes screens.
public struct HeldPage: Equatable, Sendable {
    public var book: String
    public var takenAt: Date
    public init(book: String, takenAt: Date) {
        self.book = book
        self.takenAt = takenAt
    }
}

/// Which picture of the old page the unfold swings from.
public enum UnfoldCover: Equatable, Sendable {
    /// The picture taken as the hinge moved: right whichever screen the reader is on now.
    case held
    /// A snapshot of the page as it is now, on this screen.
    case live
    /// Neither: a plain reflow, the spread simply appears.
    case none

    /// A hinge takes about a second to open; older pictures are of some other moment.
    public static let heldFreshFor: TimeInterval = 5

    public static func choose(held: HeldPage?, liveAvailable: Bool, book: String, now: Date) -> UnfoldCover {
        if let held, held.book == book {
            let age = now.timeIntervalSince(held.takenAt)
            if age >= 0, age <= heldFreshFor { return .held }
        }
        return liveAvailable ? .live : .none
    }

    /// Where the held picture goes on the new page: full height, its own proportions, from the
    /// leading edge (where the left page will be), never wider than the page.
    public static func heldFrame(picture: CGSize, in page: CGRect) -> CGRect {
        guard picture.width > 0, picture.height > 0 else { return page }
        let width = min(page.width, page.height * picture.width / picture.height)
        return CGRect(x: page.minX, y: page.minY, width: width, height: page.height)
    }
}
