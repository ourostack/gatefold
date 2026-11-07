#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif

/// Where a tap on the page turns it. Each page keeps its own outer quarter: on a spread a quarter of
/// the whole view was half of each page, so a tap meant for the controls on the left page turned
/// back (build 20 on the Duo).
public enum TapZones {
    public static let share: CGFloat = 0.25
    /// The widest a turn zone gets: a margin a thumb finds, not the text people tap to wake the
    /// controls (an iPad's landscape spread gave 344 pt, the outer half of each page's text).
    public static let widest: CGFloat = 88

    /// How far in from each side of the view a tap turns the page.
    public static func edge(viewWidth: CGFloat, spread: Bool) -> CGFloat {
        min(widest, (spread ? viewWidth / 2 : viewWidth) * share)
    }
}

/// When a touch on the progress scrubber is a jump. A touch that only rests on it, or wobbles,
/// never moves the place: build 20's scrubber jumped on a tap (its drag began at no distance at all).
public enum ScrubberIntent {
    /// Points the finger must travel sideways before the scrubber follows it.
    public static let minimumDrag: CGFloat = 12

    /// A deliberate drag: far enough, and more sideways than up or down.
    public static func isDeliberate(translation: CGSize) -> Bool {
        abs(translation.width) >= minimumDrag && abs(translation.width) > abs(translation.height)
    }
}
