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
    /// The widest a single page's turn zone gets: a margin a thumb finds, not the text people tap to
    /// wake the controls (a quarter of the whole iPad spread gave 344 pt, the outer half of each page's text).
    public static let widest: CGFloat = 88

    /// How far in from each side of the view a tap turns the page. A spread's page keeps its whole outer
    /// quarter, with no cap: capped at 88 pt, the iPad spread's zone was its 69 pt margin and 19 pt of text,
    /// so taps at 7% and 93% of its width woke the controls instead of turning (gatefold#304).
    public static func edge(viewWidth: CGFloat, spread: Bool) -> CGFloat {
        spread ? viewWidth / 2 * share : min(widest, viewWidth * share)
    }

    public enum Zone: String, Sendable { case back, middle, forward }

    /// What a tap at `x`, in the page's own coordinates, does. A tap beside the page (x below 0 or past its
    /// width) is in its side margin: an iPad's portrait page is inset to a book's measure, and a tap at 3% or 97%
    /// of the window lands there. It turns, as in Apple Books (gatefold#536).
    public static func zone(x: CGFloat, viewWidth: CGFloat, spread: Bool) -> Zone {
        let edge = edge(viewWidth: viewWidth, spread: spread)
        return x < edge ? .back : x > viewWidth - edge ? .forward : .middle
    }
}

/// When a sideways drag across the page turns it once the finger lifts. A brush is no turn: Apple Books ignores
/// a 20-pt brush, and build 46's iPad turned on one, because a quick finger turned at any distance (gatefold#536).
public enum PageSwipe {
    /// The least a quick swipe travels, from where the finger went down, to turn: a fingertip's width (Apple's
    /// 44-pt touch target). A shorter one is a brush, however quick.
    public static let minimumFlick: CGFloat = 44
    /// Points a second the finger must still be moving, towards the turn, for a swipe to count as quick.
    public static let flickSpeed: CGFloat = 250
    /// A slow drag turns once it has crossed this share of the page.
    public static let dragShare: CGFloat = 0.25

    /// `travel` and `velocity` are horizontal, negative to the left; a forward turn is a swipe to the left.
    public static func turns(forward: Bool, travel: CGFloat, velocity: CGFloat, width: CGFloat) -> Bool {
        let along = forward ? -travel : travel
        let speed = forward ? -velocity : velocity
        if speed > flickSpeed { return along >= minimumFlick }
        return speed > -flickSpeed && along > width * dragShare
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

/// Where the UI tests' posture switches sit: top-centre on the page, out of every turn zone. In the
/// left turn zone at mid-height they swallowed the tests' back-turn taps and right swipes (feel-ci's
/// folded Duo, the iPad spread at x 0.07).
public enum TestPostureSwitches {
    public static let button: CGFloat = 44

    public static func frame(pageFrame: CGRect, count: Int) -> CGRect {
        let width = CGFloat(count) * button
        return CGRect(x: pageFrame.midX - width / 2, y: pageFrame.minY + 4, width: width, height: button)
    }
}
