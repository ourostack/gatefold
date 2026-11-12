import XCTest

/// Brings a row of the Contents list fully into view and taps it, judged in reads of its frame (gatefold#98).
///
/// - Never `isHittable`: asked of a row the lazy list has built outside the part of it on screen, XCTest fails the
///   test ("Activation point invalid and no suggested hit points based on element frame") instead of answering
///   false. The list builds about twice the rows it shows: in main's run 43197325657 the iPad's 660 pt list had
///   28 rows built across 1456 pt, and the row asked about was one of them.
/// - Never `swipeUp`: it is a 0.2 s fling (200 pt in that run), so the list is still coasting when the next read
///   comes. Each move is a short drag inside the list, held still before it lifts, so the list stops where the drag
///   left it.
/// - The row is named by the caller, never `element(boundBy:)`, which answers with whichever row is built at that
///   index and so moves to another row after every scroll (entry 31, then 37, in that run).
@MainActor
enum ContentsRow {
    /// Taps `row` once it is wholly inside the list below its navigation bar and its frame has held still for two
    /// reads. `later`: whether a row not built yet lies after the ones that are (the jumps go forward). Bounded by
    /// reads and drags, never seconds. Returns whether the tap was sent, and the drags it took.
    static func tap(_ row: XCUIElement, in app: XCUIApplication, later: Bool = true, reads: Int = 60, drags: Int = 20) -> (ok: Bool, drags: Int) {
        let list = app.collectionViews.firstMatch
        let bar = app.navigationBars.firstMatch
        var dragged = 0, last = CGRect.null
        for _ in 0..<reads {
            guard list.exists else { return (false, dragged) }
            let shown = shownPart(of: list.frame, under: bar.exists ? bar.frame : .null)
            let frame = row.exists ? row.frame : .null
            if !frame.isNull, !frame.isEmpty, shown.contains(frame) {
                if frame == last {
                    app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
                    return (true, dragged)
                }
                last = frame
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                continue
            }
            last = .null
            guard dragged < drags else { return (false, dragged) }
            // Up (the list moves on) for a row below what is shown or not built yet and later; down otherwise.
            let up = frame.isNull || frame.isEmpty ? later : frame.midY > shown.midY
            let from = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.65 : 0.35))
            let to = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.35 : 0.65))
            from.press(forDuration: 0.1, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.3)
            dragged += 1
        }
        return (false, dragged)
    }

    /// The part of the list on screen: its frame less the navigation bar laid over its top.
    static func shownPart(of list: CGRect, under bar: CGRect) -> CGRect {
        guard !bar.isNull, bar.intersects(list), bar.maxY > list.minY else { return list }
        return CGRect(x: list.minX, y: bar.maxY, width: list.width, height: max(0, list.maxY - bar.maxY))
    }
}
