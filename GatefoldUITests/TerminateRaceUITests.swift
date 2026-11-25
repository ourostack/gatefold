import XCTest

/// Probe for gatefold#363 (not for main): terminates the app in front while its web processes are in one known
/// state (the app's `-GatefoldProbeWebProcesses`), and prints how each terminate went.
@MainActor
final class TerminateRaceUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUp() { continueAfterFailure = true; app = XCUIApplication() }

    /// Ends an app left running by an earlier round the way that works: Home first, then terminate.
    private func ensureGone() {
        guard app.state != .notRunning else { return }
        XCUIDevice.shared.press(.home)
        sleep(3)
        let t0 = Date()
        app.terminate()
        print("TERMRACE cleanup: home then terminate took \(String(format: "%.1f", Date().timeIntervalSince(t0))) s, state \(app.state.rawValue)")
    }

    private func round(_ mode: String?, wait: UInt32, home: Bool = false, _ n: Int) {
        ensureGone()
        app.launchArguments = ["-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldReset", "YES",
                               "-GatefoldSkipWelcome", "YES", "-GatefoldSignedIn", "YES"]
        if let mode { app.launchArguments += ["-GatefoldProbeWebProcesses", mode] }
        app.launch()
        sleep(wait)
        if home { XCUIDevice.shared.press(.home); sleep(2) }
        let t0 = Date()
        print("TERMRACE \(mode ?? "quiet")\(home ? "+home" : "") round \(n): terminate at \(t0)")
        app.terminate()
        let took = Date().timeIntervalSince(t0)
        print("TERMRACE \(mode ?? "quiet")\(home ? "+home" : "") round \(n): terminate took \(String(format: "%.1f", took)) s, state after \(app.state.rawValue)")
    }

    func test1Quiet() { round(nil, wait: 6, 1); round(nil, wait: 6, 2) }
    func test2Held() { round("held", wait: 12, 1); round("held", wait: 12, 2) }
    func test3Releasing() { round("releasing", wait: 19, 1); round("releasing", wait: 19, 2) }
    func test4ChurnAfterHome() { round("churn", wait: 6, home: true, 1); round("churn", wait: 6, home: true, 2) }
    func test5Launching() { round("launching", wait: 6, 1); round("launching", wait: 6, 2) }
    func test6Churn() { round("churn", wait: 6, 1); round("churn", wait: 6, 2) }

    /// What XCTest believes about the app: its state and the first line of its debug description (which carries the pid).
    private func xctestView() -> String {
        let first = app.debugDescription.split(separator: "\n").first.map(String.init) ?? "none"
        return "XCTest state \(app.state.rawValue); \(first)"
    }

    /// Opens Pride and Prejudice as the failing shards do, waits for its first page, and then terminates
    /// right after `then`, while the reader's own web work (page counting, a reflow) runs.
    private func readerRound(_ name: String, _ n: Int, then: () -> Void) {
        ensureGone()
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = [
            "-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldReset", "YES", "-GatefoldSkipWelcome", "YES",
            "-GatefoldSignedIn", "YES", "-GatefoldDownloadAll", "YES", "-GatefoldNoLatency", "YES",
            "-GatefoldOpenBook", "gutenberg-pride-and-prejudice",
        ]
        app.launch()
        let ready = app.descendants(matching: .any)["reader.pageReady"].firstMatch
        var reads = 0
        while reads < 600, (ready.value as? String) != "1" { reads += 1; RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        then()
        print("TERMRACE \(name) round \(n): just before terminate, XCTest state \(app.state.rawValue)")
        let t0 = Date()
        print("TERMRACE \(name) round \(n): terminate at \(t0) (page ready \((ready.value as? String) == "1"))")
        app.terminate()
        print("TERMRACE \(name) round \(n): terminate took \(String(format: "%.1f", Date().timeIntervalSince(t0))) s, state after \(app.state.rawValue)")
        if name == "rotate-terminate" { print("TERMRACE \(name) round \(n): after terminate, \(xctestView())") }
    }

    func test7ReaderCounting() { for n in 1...3 { readerRound("reader-counting", n) {} } }
    func test8ReaderRotating() {
        for n in 1...3 { readerRound("reader-rotating", n) { XCUIDevice.shared.orientation = .landscapeLeft } }
        XCUIDevice.shared.orientation = .portrait
    }

    /// Known probe bug (run 45254316044): the "Chapter XXX" row never appeared within 20 s of the Contents tap, so no
    /// round reached its terminate; not chased (it is not a #363 failure).
    /// A book open, a far jump through Contents (as testAJumpFromAPageStillLoadingStartsAtOnce does), then the
    /// terminate as soon as Back is up, while the far chapter loads and the pages are counted.
    func test9ReaderFarJump() {
        for n in 1...3 {
            readerRound("reader-farjump", n) {
                let t0 = Date()
                app.descendants(matching: .any)["reader.page"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                _ = app.buttons["reader.contents"].waitForExistence(timeout: 10)
                app.buttons["reader.contents"].tap()
                let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Chapter XXX")).firstMatch
                _ = row.waitForExistence(timeout: 20)
                let t1 = Date()
                row.tap()
                let back = app.descendants(matching: .any)["reader.back"].firstMatch
                let up = back.waitForExistence(timeout: 120)
                print("TERMRACE reader-farjump round \(n): contents up in \(String(format: "%.1f", t1.timeIntervalSince(t0))) s, Back \(up ? "up" : "never up") \(String(format: "%.1f", Date().timeIntervalSince(t1))) s after the tap")
            }
        }
    }

    /// Probe 4 (gatefold#363): rotate the open reader, then terminate, ten times in one shard. Each round is its own
    /// test because a failed terminate ends the test whatever continueAfterFailure says (probe 3's test8 stopped at
    /// round 1). Rounds 1 to 5 read XCTest's view of the app (state and pid) between the rotation and the terminate;
    /// rounds 6 to 10 read it before the rotation and after the terminate only, since the debug description takes a
    /// snapshot and could close the window being probed.
    private func rotateTerminate(_ n: Int) {
        readerRound("rotate-terminate", n) {
            if n > 5 { print("TERMRACE rotate-terminate round \(n): before rotation, \(xctestView())") }
            XCUIDevice.shared.orientation = n % 2 == 1 ? .landscapeLeft : .landscapeRight
            print("TERMRACE rotate-terminate round \(n): rotated at \(Date())")
            if n <= 5 { print("TERMRACE rotate-terminate round \(n): after rotation, \(xctestView())") }
        }
        XCUIDevice.shared.orientation = .portrait
    }
    func test10Rotate01() { rotateTerminate(1) }
    func test10Rotate02() { rotateTerminate(2) }
    func test10Rotate03() { rotateTerminate(3) }
    func test10Rotate04() { rotateTerminate(4) }
    func test10Rotate05() { rotateTerminate(5) }
    func test10Rotate06() { rotateTerminate(6) }
    func test10Rotate07() { rotateTerminate(7) }
    func test10Rotate08() { rotateTerminate(8) }
    func test10Rotate09() { rotateTerminate(9) }
    func test10Rotate10() { rotateTerminate(10) }
}
