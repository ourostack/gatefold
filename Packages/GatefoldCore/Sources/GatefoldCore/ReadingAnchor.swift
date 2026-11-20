/// The reader's place: the first fully visible text of the page the reader last acted on.
/// It moves only when the reader acts (turns, jumps, scrubs), never when the layout reflows,
/// which is what lets it survive a fold, a rotation or a font change (design brief D3).
public struct ReadingAnchor: Equatable, Hashable, Codable, Sendable {
    public var href: String
    /// Progression within the resource, 0...1.
    public var progression: Double
    /// The first visible text, when the web view reports it. More exact than progression.
    public var text: String?

    public init(href: String, progression: Double, text: String?) {
        self.href = href
        self.progression = progression
        self.text = text
    }
}

/// What is on screen right now, as the navigator reports it.
public struct VisibleRange: Equatable, Sendable {
    public var href: String
    public var start: Double
    public var end: Double
    /// The visible text, when known.
    public var text: String?

    public init(href: String, start: Double, end: Double, text: String? = nil) {
        self.href = href
        self.start = start
        self.end = end
        self.text = text
    }

    /// The reflow check, by words only: his anchor's opening words in the text on screen. Never by progression,
    /// which is Readium's last report and the page's end clamped to it, not the page's range: a check that fell
    /// back to it would call an unread page his (gatefold#534).
    public func verdict(for anchor: ReadingAnchor) -> AnchorVerdict {
        guard anchor.href == href else { return .lost }
        guard let needle = anchor.text?.openingWords, !needle.isEmpty else { return .wordless }
        guard let text else { return .unread }
        return text.contains(needle) ? .visible : .lost
    }

    /// Where his anchor's opening words start in the text on screen, in characters (nil when they aren't in it):
    /// a number the log can carry, where the words can't go.
    public func offset(of anchor: ReadingAnchor) -> Int? {
        guard anchor.href == href, let needle = anchor.text?.openingWords, !needle.isEmpty, let text,
              let r = text.range(of: needle) else { return nil }
        return text.distance(from: text.startIndex, to: r.lowerBound)
    }

    public func contains(_ anchor: ReadingAnchor) -> Bool {
        guard anchor.href == href else { return false }
        if let needle = anchor.text?.openingWords, !needle.isEmpty, let text {
            // The opening words only: the anchor's line can be the last on the page.
            return text.contains(needle)
        }
        // Half-open, so a page that starts exactly where the anchor is counts and the next one doesn't.
        return anchor.progression >= start - 0.0001 && (anchor.progression < end || end >= 1)
    }
}

/// A reflow's own check of his place (`ReaderModel.reflowDidFinish`): are his anchor's words on screen?
public enum AnchorVerdict: String, Sendable {
    /// His words are in the text on screen.
    case visible = "anchor-visible"
    /// The text on screen was read and his words aren't in it (or the page is another file).
    case lost = "anchor-lost"
    /// The page's text wasn't read: nothing is proven either way.
    case unread = "anchor-unread"
    /// His place has no words to look for (the open's bare place, gatefold#250): nothing is proven either way, and
    /// the place is no one's loss to fix; it is told apart from a page that wasn't read.
    case wordless = "anchor-wordless"
}

public enum ReflowReason: String, Sendable {
    case posture
    case rotation
    case resize
    case typography
}

public enum RestoreAction: Equatable, Sendable {
    case none
    case jump(ReadingAnchor)
}

/// Keeps the anchor steady while the layout changes underneath it.
public struct AnchorKeeper: Sendable {
    public private(set) var anchor: ReadingAnchor?
    public private(set) var reflowing: ReflowReason?

    public init(anchor: ReadingAnchor? = nil) {
        self.anchor = anchor
    }

    /// The reader turned, jumped or scrubbed and the navigator settled. Ignored while a reflow is in
    /// flight, because then the navigator's location is Readium's drifted guess, not the reader's place.
    public mutating func userSettled(on location: ReadingAnchor) {
        guard reflowing == nil else { return }
        anchor = location
    }

    /// The reader's move count when the open reflow began (`reflowWillBegin(_:move:)`).
    public private(set) var reflowMove = 0

    /// `move`: the reader's move count now (his turns, jumps and landings). A restore of this reflow may move
    /// the page only while it is unchanged (`restoreMayMove`).
    public mutating func reflowWillBegin(_ reason: ReflowReason, move: Int = 0) {
        reflowing = reason
        reflowMove = move
    }

    /// False once he has moved since the reflow began: the page is his again, and a restore still running
    /// (the 12 s watchdog's retry on a page it showed him) must not bring the old place back.
    public func restoreMayMove(move: Int) -> Bool {
        reflowing != nil && move == reflowMove
    }

    /// His turn had let go, and not landed, when this reflow began: the page it turned to is his, by its first words
    /// read in the layout he turned in. The restore puts them back (gatefold#534).
    public mutating func turnUnderReflow(_ page: ReadingAnchor) {
        guard reflowing != nil else { return }
        anchor = page
    }

    /// That turn landed under this reflow: its move is the turn the restore puts back, made before the reflow began,
    /// not a move since. The restore goes on.
    public mutating func turnUnderReflowLanded() {
        guard reflowing != nil else { return }
        reflowMove += 1
    }

    /// That turn, landed, turned out to have no words read: its landing is a move since, which the restore gives
    /// way to, as any other.
    public mutating func turnUnderReflowUnread() {
        guard reflowing != nil else { return }
        reflowMove -= 1
    }

    /// The restore gave way to his move: the reflow ends without it, and his own place is taken again.
    public mutating func restoreGaveWay() {
        reflowing = nil
    }

    /// The navigator finished laying out. Returns the jump that brings the anchor back on screen.
    /// The reflow stays open until `restoreDidComplete`: the restore can still move the page (a
    /// spread keeping the sentence on its left page), and the pages it passes are not the reader's.
    public mutating func reflowDidSettle(visible: VisibleRange) -> RestoreAction {
        guard let anchor, !visible.contains(anchor) else { return .none }
        return .jump(anchor)
    }

    /// The restoring jump landed; the reader's own actions move the anchor again.
    public mutating func restoreDidComplete() {
        reflowing = nil
    }
}

extension String {
    /// The first four words, enough to be distinctive and short enough to fit on one line.
    var openingWords: String {
        split(whereSeparator: \.isWhitespace).prefix(4).joined(separator: " ")
    }

    var trimmingWhitespace: String {
        var s = Substring(self)
        while let f = s.first, f.isWhitespace { s.removeFirst() }
        while let l = s.last, l.isWhitespace { s.removeLast() }
        return String(s)
    }
}
