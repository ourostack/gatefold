/// The leaf a change of posture plays over the page, if any. A change of posture re-lays out the page where it is;
/// only the book opening from its cover, or shutting back to it, turns a leaf, and only on a page of pages. Half open
/// to flat is the same screen bending: the unfold's leaf rose there and stood frozen over a white page, a grey wedge,
/// even in scroll mode, where no page turns (Ari, 2026-11-27).
public enum PostureLeaf: Equatable, Sendable {
    /// One page becomes two: the right page swings open from the spine.
    case unfold
    /// Two pages become one: the right page shuts over the left.
    case fold

    /// The leaf a change from `old` to `new` plays: nil on a device with no fold (an iPad fades, gatefold#537), on a
    /// scrolling page, and between half open and flat.
    public static func plays(from old: Posture, to new: Posture, scrolls: Bool, hasFold: Bool) -> PostureLeaf? {
        guard hasFold, !scrolls else { return nil }
        switch (old, new) {
        case (.single, .spread): return .unfold
        case (.spread, .single): return .fold
        default: return nil
        }
    }
}
