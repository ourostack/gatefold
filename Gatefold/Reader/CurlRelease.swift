import Foundation

/// Whether a curl dragged and let go turns the page or springs back.
enum CurlRelease {
    /// A finger still this long before lifting has stopped: the speed UIKit reports at the lift is the drag's
    /// from before it stopped, so it isn't a flick (#110).
    static let stopped: CFTimeInterval = 0.08

    /// A flick (over 250 pt/s the turn's way, with the finger still moving at the lift) turns it, and so does a
    /// drag a quarter of the way across.
    static func completes(forward: Bool, dx: CGFloat, width: CGFloat, velocity: CGFloat, stillFor: CFTimeInterval) -> Bool {
        let v = stillFor > stopped ? 0 : velocity
        if forward { return v < -250 || (v < 250 && dx < -width * 0.25) }
        return v > 250 || (v > -250 && dx > width * 0.25)
    }
}
