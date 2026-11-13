#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif

/// Tells a tap from a drag or a two-finger touch, from the page's pointer reports.
///
/// Readium's own tap observer waited, once a touch had failed to be a tap, for every finger it had seen
/// to report lifting. A swipe that turned into another chapter went down on a web view that was gone
/// before it could report the finger up, so that observer waited for ever, and every tap after it did
/// nothing: no turn, no controls, nothing logged (gatefold#321). Here a fresh touch, with no other
/// finger on the glass, forgets every finger still waiting.
public struct TapTracker<ID: Hashable> {
    public enum Phase { case down, move, up, cancel }

    private enum State: Equatable {
        case idle
        /// `alone`: a finger came down on its own since this one did, so this one's lift may never be heard.
        case recognizing(id: ID, last: CGPoint, alone: Bool)
        case failed(waiting: Set<ID>)
    }

    private var state: State = .idle
    /// How far a finger may wander and still be a tap.
    public static var slop: CGFloat { 1 }

    public init() {}

    /// True when the touch this event ends is a tap. `plain`: no key held with it (a touch with Shift or Command
    /// held is no tap, as with Readium's).
    public mutating func receive(_ phase: Phase, id: ID, at point: CGPoint, plain: Bool = true) -> Bool {
        switch (state, phase) {
        case (.idle, .down):
            state = plain ? .recognizing(id: id, last: point, alone: false) : .failed(waiting: [id])
        case let (.recognizing(current, _, true), .down) where current != id:
            // The finger before it went down and was never heard again: this one starts afresh.
            state = plain ? .recognizing(id: id, last: point, alone: false) : .failed(waiting: [id])
        case let (.recognizing(current, _, _), .down) where current != id:
            state = .failed(waiting: [current, id])
        case let (.recognizing(current, _, _), .cancel) where current == id:
            state = .idle
        case let (.recognizing(current, last, alone), .move):
            if current != id {
                // A finger already gone moving is a late report; one still down makes two fingers.
                if !alone { state = .failed(waiting: [current, id]) }
            } else if abs(last.x - point.x) > Self.slop || abs(last.y - point.y) > Self.slop {
                // A finger already thought gone that drags is a late report: nothing waits on it.
                state = alone ? .idle : .failed(waiting: [current])
            } else {
                state = .recognizing(id: current, last: point, alone: alone)
            }
        case let (.recognizing(current, _, _), .up) where current == id:
            state = .idle
            return true
        case var (.failed(waiting), .down):
            waiting.insert(id)
            state = .failed(waiting: waiting)
        case var (.failed(waiting), .up), var (.failed(waiting), .cancel):
            waiting.remove(id)
            state = waiting.isEmpty ? .idle : .failed(waiting: waiting)
        default:
            break
        }
        return false
    }

    /// A finger came down with no other on the glass: any finger still waiting to lift is one whose
    /// page went away under it. The glass says so before the page reports the new finger down (UIKit
    /// runs gesture recognizers as it sends the touch; the page's reports come later, through a task),
    /// so a touch still being recognized is an old one: kept, should its lift still come, but a
    /// different finger's down next starts afresh instead of failing.
    public mutating func aloneOnTheGlass() {
        switch state {
        case .failed: state = .idle
        case let .recognizing(id, last, _): state = .recognizing(id: id, last: last, alone: true)
        case .idle: break
        }
    }
}
