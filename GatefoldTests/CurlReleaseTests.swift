import Foundation
import Testing
@testable import Gatefold

/// A curl let go turns the page only when he meant it: a flick, or a drag a quarter of the way across. A drag
/// that stopped part way and was then let go springs back, whatever speed the drag had before it stopped
/// (Feel on the Duo: "a drag let go part way: the page moved").
struct CurlReleaseTests {
    private let width: CGFloat = 466

    @Test func aFlickTurns() {
        #expect(CurlRelease.completes(forward: true, dx: -40, width: width, velocity: -900, stillFor: 0.01))
        #expect(CurlRelease.completes(forward: false, dx: 40, width: width, velocity: 900, stillFor: 0.01))
    }

    @Test func aDragAQuarterAcrossTurns() {
        #expect(CurlRelease.completes(forward: true, dx: -width * 0.3, width: width, velocity: 0, stillFor: 0.3))
        #expect(CurlRelease.completes(forward: false, dx: width * 0.3, width: width, velocity: 0, stillFor: 0.3))
    }

    @Test func aShortSlowDragSpringsBack() {
        #expect(!CurlRelease.completes(forward: true, dx: -60, width: width, velocity: -100, stillFor: 0.01))
    }

    /// The finger stopped 0.2 s before lifting: the speed UIKit still reports is the drag's, not the release's.
    @Test func aDragThatStoppedPartWaySpringsBack() {
        #expect(!CurlRelease.completes(forward: true, dx: -60, width: width, velocity: -600, stillFor: 0.2))
        #expect(!CurlRelease.completes(forward: false, dx: 60, width: width, velocity: 600, stillFor: 0.2))
    }

    @Test func theStopIsJudgedAtEightyMilliseconds() {
        #expect(CurlRelease.completes(forward: true, dx: -40, width: width, velocity: -900, stillFor: 0.079))
        #expect(!CurlRelease.completes(forward: true, dx: -40, width: width, velocity: -900, stillFor: 0.081))
    }

    /// Stillness is the touches' own time between the last move and the lift, so a main thread held between them
    /// changes nothing.
    @Test func stillnessComesFromTheTouchTimes() {
        #expect(abs(CurlRelease.still(lastMove: 100.000, lift: 100.012) - 0.012) < 1e-9)
        #expect(abs(CurlRelease.still(lastMove: 100.0, lift: 100.2) - 0.2) < 1e-9)
        #expect(CurlRelease.still(lastMove: nil, lift: 100.2) == 0)
        #expect(CurlRelease.still(lastMove: 100.3, lift: 100.2) == 0)
    }
}
