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
        case recognizing(id: ID, last: CGPoint)
        case failed(waiting: Set<ID>)
    }

    private var state: State = .idle
    /// How far a finger may wander and still be a tap.
    public static var slop: CGFloat { 1 }

    public init() {}

    /// True when the touch this event ends is a tap.
    public mutating func receive(_ phase: Phase, id: ID, at point: CGPoint) -> Bool {
        switch (state, phase) {
        case (.idle, .down):
            state = .recognizing(id: id, last: point)
        case let (.recognizing(current, _), .down) where current != id:
            state = .failed(waiting: [current, id])
        case let (.recognizing(current, _), .cancel) where current == id:
            state = .idle
        case let (.recognizing(current, last), .move):
            if current != id || abs(last.x - point.x) > Self.slop || abs(last.y - point.y) > Self.slop {
                state = .failed(waiting: [current, id])
            } else {
                state = .recognizing(id: current, last: point)
            }
        case let (.recognizing(current, _), .up) where current == id:
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
    /// page went away under it. A touch already being recognized is left alone, so this may come before
    /// or after that touch's own report.
    public mutating func aloneOnTheGlass() {
        if case .failed = state { state = .idle }
    }
}
