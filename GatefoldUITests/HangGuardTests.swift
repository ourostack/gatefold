import XCTest

/// `HangGuard`'s sizing, without the app (gatefold#221).
final class HangGuardTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testWithoutTheStepsEndItIsTheReadsAtTheWorstReadPlusAQuarter() {
        XCTAssertEqual(HangGuard.seconds(reads: 40, stepUntil: nil, now: now), 930, accuracy: 0.001)
    }

    func testWithTimeToSpareTheStepsEndDoesNotShortenIt() {
        XCTAssertEqual(HangGuard.seconds(reads: 40, stepUntil: now.timeIntervalSince1970 + 3600, now: now), 930, accuracy: 0.001)
    }

    func testNearTheStepsEndItEndsInTimeForTheResultsToBeWritten() {
        // 600 s left: 600 - 180 = 420, under the 930 the reads would give.
        XCTAssertEqual(HangGuard.seconds(reads: 40, stepUntil: now.timeIntervalSince1970 + 600, now: now), 420, accuracy: 0.001)
    }

    func testAtOrPastTheStepsEndItKeepsItsFloor() {
        XCTAssertEqual(HangGuard.seconds(reads: 40, stepUntil: now.timeIntervalSince1970 + 60, now: now), 30, accuracy: 0.001)
        XCTAssertEqual(HangGuard.seconds(reads: 40, stepUntil: now.timeIntervalSince1970 - 100, now: now), 30, accuracy: 0.001)
    }
}
