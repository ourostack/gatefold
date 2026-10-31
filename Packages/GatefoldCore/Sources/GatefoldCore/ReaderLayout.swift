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

/// The hinge, as `onHingeChange` reports it. Used for effects only, never for layout (Apple's split).
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

        switch input.forced ?? posture(bounds: bounds, fold: fold) {
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
            let page = CGRect(x: 0, y: 0, width: bounds.width, height: max(0, foldBand.minY))
            let deck = CGRect(x: 0, y: foldBand.maxY, width: bounds.width, height: max(0, bounds.maxY - foldBand.maxY))
            return ReaderLayout(posture: .tabletop, pageFrame: page, gutter: nil, deck: deck, columns: .one, spineShadow: 0)
        }
    }

    private static func posture(bounds: CGRect, fold: FoldRegion?) -> Posture {
        let wide = bounds.width > bounds.height && bounds.width >= minimumSpreadWidth
        if let fold {
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
