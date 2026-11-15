#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif

/// Scroll mode's chapter turn. A sideways swipe once changed chapter, and the swipe back landed at that
/// chapter's start or end instead of his place (Ari, build 39 on the Duo). Now a chapter turns only when he
/// drags on past its end (the next opens at its start) or back past its start (the one before opens at its
/// end, where he left it).
public enum ScrollPull {
    /// Where a drag began in the chapter.
    public enum Edge: Equatable, Sendable {
        case start, end
        /// A chapter shorter than the screen is at both.
        case both
    }

    /// Points the finger must travel up or down past an edge before the chapter turns: a deliberate pull,
    /// not the end of a flick that happened to reach it.
    public static let distance: CGFloat = 60
    /// Slack, in points, for an offset that rests a fraction short of an edge.
    static let slack: CGFloat = 2

    /// The edge a scroll view rests at, or nil mid-chapter. `offset` is its content offset, `viewport` its height.
    public static func edge(offset: CGFloat, viewport: CGFloat, content: CGFloat, insetTop: CGFloat,
                            insetBottom: CGFloat) -> Edge? {
        let atStart = offset <= -insetTop + slack
        let atEnd = offset + viewport - insetBottom >= content - slack
        switch (atStart, atEnd) {
        case (true, true): return .both
        case (true, false): return .start
        case (false, true): return .end
        case (false, false): return nil
        }
    }

    /// Whether a drag that began at `edge` and travelled `dragged` turns the chapter: true forward, false back,
    /// nil not at all. Mostly vertical only: a sideways swipe never turns.
    public static func turn(from edge: Edge, dragged: CGPoint) -> Bool? {
        guard abs(dragged.y) >= distance, abs(dragged.y) > abs(dragged.x) * 1.5 else { return nil }
        // The finger moving up reads on through the text.
        let forward = dragged.y < 0
        switch edge {
        case .end: return forward ? true : nil
        case .start: return forward ? nil : false
        case .both: return forward
        }
    }
}
