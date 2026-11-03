import Foundation
import Testing
@testable import Gatefold

/// A touch on the reopen picture turns by the live page's rules, and only the first is kept.
@MainActor
struct ReopenTurnTests {
    private let width: CGFloat = 400

    @Test func edgeTapsTurnThatWay() {
        #expect(ReopenTurn.forward(start: CGPoint(x: 380, y: 300), translation: .zero, width: width) == true)
        #expect(ReopenTurn.forward(start: CGPoint(x: 20, y: 300), translation: .zero, width: width) == false)
    }

    @Test func aTapInTheMiddleTurnsNothing() {
        #expect(ReopenTurn.forward(start: CGPoint(x: 200, y: 300), translation: .zero, width: width) == nil)
    }

    @Test func swipesTurnAgainstTheirDirection() {
        #expect(ReopenTurn.forward(start: CGPoint(x: 300, y: 300), translation: CGSize(width: -80, height: 6), width: width) == true)
        #expect(ReopenTurn.forward(start: CGPoint(x: 100, y: 300), translation: CGSize(width: 80, height: -6), width: width) == false)
    }

    @Test func aVerticalDragTurnsNothing() {
        #expect(ReopenTurn.forward(start: CGPoint(x: 380, y: 300), translation: CGSize(width: 10, height: 120), width: width) == nil)
    }

    @Test func theHeldCornerBreathesALittle() {
        let corner = CGPoint(x: 466, y: 631), lifted = CGPoint(x: 373, y: 536)
        let settled = ReopenTurn.breath(lifted: lifted, corner: corner, leafWidth: 466, height: 631)
        // Back towards the corner, but only a few points: still clearly lifted.
        #expect(settled.x > lifted.x && settled.x < lifted.x + 20)
        #expect(settled.y > lifted.y && settled.y < lifted.y + 20)
    }

    @Test func onlyTheFirstTurnIsKept() {
        let app = AppModel(sync: StubSync(), libraryRoot: URL.temporaryDirectory.appending(path: "reopen-turn-\(UUID().uuidString)"))
        #expect(app.queueReopenTurn(forward: true))
        #expect(!app.queueReopenTurn(forward: false))
        #expect(app.reopenQueuedTurn == true)
    }
}
