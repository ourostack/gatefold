#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import Testing
@testable import GatefoldCore

/// Where the Back pill stands after a search: never on the match he asked for (gatefold#652). On the folded Duo the
/// first "Darcy" landed on the page's second-to-last line, and the pill, low on the page, hid all but its last letters.
@Suite struct JumpBackTests {
    /// A small screen's pill, 220 x 44 pt, at the foot and at the top.
    let foot = CGRect(x: 80, y: 520, width: 220, height: 44)
    let top = CGRect(x: 80, y: 40, width: 220, height: 44)

    @Test func withNoMatchThePillStaysAtTheFoot() {
        #expect(JumpBack.edge(match: nil, foot: foot, top: top) == .foot)
        #expect(JumpBack.edge(match: .null, foot: foot, top: top) == .foot)
    }

    @Test func aMatchHigherOnThePageLeavesThePillAtTheFoot() {
        let match = CGRect(x: 140, y: 200, width: 60, height: 22)
        #expect(JumpBack.edge(match: match, foot: foot, top: top) == .foot)
    }

    @Test func aMatchUnderTheFootPillSendsItToTheTop() {
        // The Duo's case: "Darcy's" on the line the pill stands on.
        let match = CGRect(x: 230, y: 530, width: 70, height: 22)
        #expect(JumpBack.edge(match: match, foot: foot, top: top) == .top)
    }

    @Test func aMatchJustClearOfThePillStillCountsAsUnderIt() {
        // Its descenders and the underline below it sit within a few points of the glass: too close to read as clear.
        let match = CGRect(x: 140, y: 500, width: 60, height: 18)
        #expect(JumpBack.edge(match: match, foot: foot, top: top) == .top)
        let clear = CGRect(x: 140, y: 480, width: 60, height: 18)
        #expect(JumpBack.edge(match: clear, foot: foot, top: top) == .foot)
    }

    @Test func aMatchBesideThePillLeavesItWhereItIs() {
        let match = CGRect(x: 320, y: 530, width: 40, height: 22)
        #expect(JumpBack.edge(match: match, foot: foot, top: top) == .foot)
    }

    @Test func aMatchUnderBothPlacesKeepsTheFoot() {
        // A page too short for either to be clear: the pill doesn't move for nothing.
        let match = CGRect(x: 100, y: 40, width: 180, height: 520)
        #expect(JumpBack.edge(match: match, foot: foot, top: top) == .foot)
    }
}
