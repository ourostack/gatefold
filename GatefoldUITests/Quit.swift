import XCTest

extension XCUIApplication {
    /// Ends the app and waits until it has ended, before anything launches it again (gatefold#76).
    ///
    /// Leaving for the Home Screen can let the system end the app in the background, and terminating a process
    /// that is already gone records "Failed to terminate". Launching before the old process has gone can leave
    /// XCUITest holding no process ("does not have a process ID") or querying a dead one until it times out.
    /// So this terminates only an app still running, then waits on the app's state, not on a clock.
    func quit(timeout: TimeInterval = 30) {
        if state != .notRunning { terminate() }
        if !wait(for: .notRunning, timeout: timeout) {
            XCTFail("the app was still running \(Int(timeout)) s after it was ended")
        }
    }
}
