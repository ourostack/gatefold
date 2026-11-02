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

    public mutating func reflowWillBegin(_ reason: ReflowReason) {
        reflowing = reason
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
