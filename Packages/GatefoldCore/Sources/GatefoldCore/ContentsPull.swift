#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif

/// Contents goes when he pulls its list down past the top, as Apple Books' does. The sheet's own pull moves it only
/// when a drag starts with the list already at its top; the list opens on his chapter, part way down, so a pull that
/// began there scrolled the list to its top and stretched it, and Contents stayed up (build 47, iPad and folded Duo).
public enum ContentsPull {
    /// Points the list must be stretched past its top as his finger lifts for Contents to close: about 80 points of
    /// finger travel past the top on a phone, a deliberate pull rather than a finger that drifted on.
    public static let distance: CGFloat = 40

    /// How far the list is stretched past its top, in points; 0 when it isn't. `offset` is its content offset,
    /// `insetTop` its top content inset.
    public static func stretch(offset: CGFloat, insetTop: CGFloat) -> CGFloat {
        max(0, -insetTop - offset)
    }

    /// Whether lifting his finger from the list closes Contents. Only the moment a drag ends counts: a flick that
    /// coasts into the top stretches the list too, while no finger is on it, and that never closes it.
    public static func closes(fingerLifted: Bool, offset: CGFloat, insetTop: CGFloat) -> Bool {
        fingerLifted && stretch(offset: offset, insetTop: insetTop) >= distance
    }
}
