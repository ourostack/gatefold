import Testing
@testable import Gatefold

/// A turn under a jump's veil would move his page from wherever the jump has got to (gatefold#228):
/// a bare catch-up no longer riffles, so nothing else holds turns off while it runs.
@Suite struct TurnGateTests {
    @Test func noTurnStartsUnderAVeil() {
        #expect(!TurnGate.starts(turning: false, veiled: true, jumpStarting: false), "a turn started under a jump's veil")
    }

    @Test func noTurnStartsWhileAJumpIsStarting() {
        #expect(!TurnGate.starts(turning: false, veiled: false, jumpStarting: true), "a turn started as a jump began")
    }

    @Test func noTurnStartsDuringATurn() {
        #expect(!TurnGate.starts(turning: true, veiled: false, jumpStarting: false))
    }

    @Test func aTurnStartsOnAPageAtRest() {
        #expect(TurnGate.starts(turning: false, veiled: false, jumpStarting: false))
    }
}
