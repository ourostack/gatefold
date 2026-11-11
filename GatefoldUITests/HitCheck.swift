import XCTest

/// A hit check that never fails the test itself (gatefold#236, #98). Asked of an element whose frame is
/// mid-change (an offer folding into its tab, a Contents row while the list scrolls), `isHittable` fails the
/// test outright: "Failed to determine hittability … Activation point invalid and no suggested hit points
/// based on element frame" (#195's run 43017585210, #199's run 43010207854, the #228 probe 43017411127).
/// So the frame is read first, and an element with no usable frame is "not hittable this look", which the
/// caller's loop counts like any other look.
enum HitCheck {
    /// The element's frame this look when a tap could land on it: it exists, is at least 1 pt each way, and
    /// its centre is inside the app's window. Nil otherwise. As NavigationPlace's offer taps have read it
    /// since #171.
    static func frame(_ element: XCUIElement, in app: XCUIApplication) -> CGRect? {
        guard element.exists else { return nil }
        let f = element.frame
        guard !f.isNull, !f.isInfinite, f.width >= 1, f.height >= 1,
              app.frame.contains(CGPoint(x: f.midX, y: f.midY)) else { return nil }
        return f
    }

    /// Hittable this look: `isHittable` is asked only of an element whose frame is usable, so it also says
    /// whether something covers it (a row under the list's header). Still two reads of the app: a frame that
    /// goes bad between them can still fail. Where nothing can cover the element, tap `frame`'s point instead.
    static func hittable(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        frame(element, in: app) != nil && element.isHittable
    }

    /// A tap at the centre of a frame read this look. An element that has moved or folded since takes no
    /// failed tap: the touch lands where it was.
    static func tap(_ frame: CGRect, in app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
    }
}
