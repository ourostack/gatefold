import ReadiumShared
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Whether a curl dragged and let go turns the page or springs back.
enum CurlRelease {
    /// A finger still this long before lifting has stopped: the speed UIKit reports at the lift is the drag's
    /// from before it stopped, so it isn't a flick (#110).
    static let stopped: CFTimeInterval = 0.08

    /// A flick (over 250 pt/s the turn's way, with the finger still moving at the lift) turns it, and so does a
    /// drag a quarter of the way across.
    /// How long the finger was still before lifting, from the touches' own timestamps.
    static func still(lastMove: TimeInterval?, lift: TimeInterval) -> TimeInterval {
        guard let lastMove else { return 0 }
        return max(0, lift - lastMove)
    }

    static func completes(forward: Bool, dx: CGFloat, width: CGFloat, velocity: CGFloat, stillFor: CFTimeInterval) -> Bool {
        let v = stillFor > stopped ? 0 : velocity
        if forward { return v < -250 || (v < 250 && dx < -width * 0.25) }
        return v > 250 || (v > -250 && dx > width * 0.25)
    }

    /// Puts the page back under a curl that sprang back: to where the turn started, not a page back the other
    /// way, which across a chapter's start lands at the start of the chapter before (#110). `step` (forward when
    /// true) is only for a turn whose start wasn't known.
    @MainActor static func springBack(to start: Locator?, mirrored: Bool,
                                      go: (Locator) async -> Bool, step: (Bool) async -> Bool) async {
        if let start, await go(start) { return }
        _ = await step(mirrored)
    }
}

/// The curl's pan, which keeps the touches' own times: how long the finger was still before it lifted,
/// whatever held the main thread meanwhile.
final class CurlPan: UIPanGestureRecognizer {
    private var movedAt: TimeInterval?
    private(set) var stillBeforeLift: TimeInterval = 0

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let t = touches.first { movedAt = t.timestamp; stillBeforeLift = 0 }
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if let t = touches.first { movedAt = event.coalescedTouches(for: t)?.last?.timestamp ?? t.timestamp }
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if let t = touches.first { stillBeforeLift = CurlRelease.still(lastMove: movedAt, lift: t.timestamp) }
        super.touchesEnded(touches, with: event)
    }

    override func reset() {
        super.reset()
        movedAt = nil
    }
}
