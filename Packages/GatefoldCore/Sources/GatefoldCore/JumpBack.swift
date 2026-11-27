#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif

/// The way back after a jump that is not a turn (Contents, a link in the book, a Cloud landing, a
/// highlight, a bookmark, a search result, the scrubber).
public enum JumpBack {
    /// Turns after a jump before the Back pill leaves the page: by then the jump is where he reads.
    public static let turnsToKeep = 3

    /// Where the Back pill stands with the controls down.
    public enum Edge: Sendable, Equatable { case foot, top }

    /// Where the pill would cover the page at each edge, in window points.
    public struct Places: Equatable, Sendable {
        public var foot: CGRect
        public var top: CGRect
        public init(foot: CGRect, top: CGRect) { self.foot = foot; self.top = top }
    }

    /// How near the glass a match may come and still read as clear of it: its descenders and its underline.
    public static let matchClearance: CGFloat = 6

    /// The pill's place for a search jump: low on the page, as for every jump, unless the match he asked for lies
    /// under it there and clear of the top (gatefold#652: on the folded Duo the first "Darcy" landed on the page's
    /// second-to-last line, under the pill). Frames are in one space (window points).
    public static func edge(match: CGRect?, foot: CGRect, top: CGRect) -> Edge {
        guard let match, !match.isNull, !match.isEmpty else { return .foot }
        func covers(_ pill: CGRect) -> Bool {
            pill.insetBy(dx: -matchClearance, dy: -matchClearance).intersects(match)
        }
        return covers(foot) && !covers(top) ? .top : .foot
    }
}
