import XCTest

/// A hit check that doesn't fail the test on a moving element (gatefold#236, #98). Asked of an element whose
/// frame is mid-change (an offer folding into its tab, a Contents row while the list scrolls), `isHittable`
/// fails the test outright: "Failed to determine hittability … Activation point invalid and no suggested hit
/// points based on element frame" (#195's run 43017585210, #199's run 43010207854, the #228 probe 43017411127).
/// So the frame is read first, from one snapshot that throws rather than fails when there is no match, and an
/// element with no usable frame is "not hittable this look", which the caller's loop counts like any other look.
@MainActor
enum HitCheck {
    /// The element's frame, from one snapshot, or nil when nothing matches. Never fails the test.
    static func frame(of element: XCUIElement) -> CGRect? {
        (try? element.snapshot())?.frame
    }

    /// `frame` when a tap at its centre could land on it: at least 1 pt each way, its centre inside `window`
    /// (`app.frame`, read once by the caller). As NavigationPlace's offer taps have judged it since #171.
    static func usable(_ frame: CGRect, within window: CGRect) -> CGRect? {
        guard !frame.isNull, !frame.isInfinite, frame.width >= 1, frame.height >= 1,
              window.contains(CGPoint(x: frame.midX, y: frame.midY)) else { return nil }
        return frame
    }

    /// Hittable this look, for an element something can cover (a Contents row under the sheet's header): its
    /// frame usable and holding still for two reads in a row (up to 10 reads, so a list still scrolling after a
    /// swipe is waited out rather than asked), and only then `isHittable`. That last read can still fail if the
    /// frame changes in the moment between it and the read before; this narrows the race, it doesn't close it.
    static func hittable(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        let window = app.frame
        var last: CGRect?
        for _ in 0..<10 {
            guard let now = frame(of: element), usable(now, within: window) != nil else { return false }
            if now == last { return element.isHittable }
            last = now
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    /// A tap at the centre of a frame read this look. An element that has moved or folded since takes no
    /// failed tap: the touch lands where it was.
    static func tap(_ frame: CGRect, in app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
    }
}
