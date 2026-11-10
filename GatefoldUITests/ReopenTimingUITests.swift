import XCTest

/// How long the reopen picture stays before the live page replaces it, for comparing builds: open a
/// book, read on a few pages, leave, iOS ends Gatefold, reopen; five rounds.
@MainActor
final class ReopenTimingUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = true
        app = XCUIApplication()
    }

    private let common = [
        "-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldSkipWelcome", "YES",
        "-GatefoldSignedIn", "YES", "-GatefoldAllowReopen", "YES",
    ]

    private var visibleText: String { (app.descendants(matching: .any)["reader.visibleText"].value as? String) ?? "" }

    private func settle(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while visibleText.isEmpty, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        RunLoop.current.run(until: Date().addingTimeInterval(3))
    }

    func testReopenPictureTime() {
        let book = ProcessInfo.processInfo.environment["GATEFOLD_TIMING_BOOK"] ?? "gutenberg-pride-and-prejudice"
        app.launchArguments = common + ["-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES",
                                        "-GatefoldOpenBook", book, "-GatefoldGoTo", "0.31"]
        app.launch()
        settle(90)
        var times: [String] = []
        for _ in 1...5 {
            for _ in 0..<3 {
                app.descendants(matching: .any)["reader.page"].coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
                RunLoop.current.run(until: Date().addingTimeInterval(1.2))
            }
            RunLoop.current.run(until: Date().addingTimeInterval(2))
            XCUIDevice.shared.press(.home)
            if !app.wait(for: .runningBackground, timeout: 3) {
                XCUIApplication(bundleIdentifier: "com.apple.springboard").activate()
            }
            sleep(4)
            app.quit()
            app.launchArguments = common
            let launched = Date()
            app.relaunch()
            let picture = app.descendants(matching: .any)["reader.reopenPicture"].firstMatch
            guard picture.waitForExistence(timeout: 5) else { times.append("no picture"); settle(40); continue }
            let gone = Date().addingTimeInterval(60)
            while picture.exists, Date() < gone { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            times.append(String(format: "%.1f", Date().timeIntervalSince(launched)))
            settle(40)
        }
        let note = XCTAttachment(string: "picture lifted after (s from launch): " + times.joined(separator: ", "))
        note.name = "reopen picture times"
        note.lifetime = .keepAlways
        add(note)
    }
}
