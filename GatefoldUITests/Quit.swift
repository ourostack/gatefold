import XCTest

extension XCUIApplication {
    /// Ends the app and waits until it has ended (gatefold#76).
    ///
    /// Leaving for the Home Screen can let the system end the app in the background, and terminating a process
    /// that is already gone records "Failed to terminate" though nothing in the app went wrong. So this terminates
    /// only an app still running, and allows that one error if the system ends the app between the check and the
    /// call. A crash is not hidden by this: CI fails a run that leaves a Gatefold crash report (scripts/ci-crashes.sh).
    ///
    /// The error is allowed only once the app is in fact gone. A terminate that fails while the app still runs is
    /// a real failure: allowed, it ended the test there as a pass (an expected failure still stops a test that
    /// doesn't continue after failure), and the app left running made XCTest restart its runner with exit 75 at the
    /// next test (gatefold#161).
    func quit(timeout: TimeInterval = 30) {
        if state != .notRunning {
            let options = XCTExpectedFailure.Options()
            options.isStrict = false
            options.issueMatcher = { [self] in $0.compactDescription.contains("Failed to terminate") && state == .notRunning }
            XCTExpectFailure("the system may have ended the app first (gatefold#76)", options: options) {
                terminate()
            }
        }
        if !wait(for: .notRunning, timeout: timeout) {
            XCTFail("the app was still running \(Int(timeout)) s after it was ended")
        }
    }

    /// Launches the app again and fails at once, naming its state, if it does not come to the front (gatefold#76).
    ///
    /// A relaunched app that died at launch otherwise surfaced later as "does not have a process ID" or as a UI
    /// query that timed out, which hid what had happened.
    func relaunch(timeout: TimeInterval = 60) {
        launch()
        XCTAssertTrue(wait(for: .runningForeground, timeout: timeout),
                      "the app came back to the front (state \(state.rawValue))")
    }
}
