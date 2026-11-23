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
}
