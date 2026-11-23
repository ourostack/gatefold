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
        let t0 = Date()
        print("TERMRACE \(name) round \(n): terminate at \(t0) (page ready \((ready.value as? String) == "1"))")
        app.terminate()
        print("TERMRACE \(name) round \(n): terminate took \(String(format: "%.1f", Date().timeIntervalSince(t0))) s, state after \(app.state.rawValue)")
    }

    func test7ReaderCounting() { for n in 1...3 { readerRound("reader-counting", n) {} } }
    func test8ReaderRotating() {
        for n in 1...3 { readerRound("reader-rotating", n) { XCUIDevice.shared.orientation = .landscapeLeft } }
        XCUIDevice.shared.orientation = .portrait
    }

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
}
