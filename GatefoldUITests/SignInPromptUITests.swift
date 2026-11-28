import XCTest

/// Ari, build 53: the Cloud wanted him to sign in again while he read, only the shelf said so, and his place never
/// reached the InkPad. The reader says it too: one tap to sign in, his email filled in, and the slip is gone once he has.
@MainActor
final class SignInPromptUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// Opens a book in its story and turns a page: the Cloud turns the place away (fetched or sent) and wants him to sign
    /// in again. The turn waits for the page to show (`reader.pageReady`): a tap before then raises the controls instead,
    /// and the ask is then the whole notice, not the tab (CI's iPad, #660: its page took 10.4 s, past a fixed 3 s sleep).
    /// `lineFrames`: the page also says where each of its lines stands (`reader.lineFrames`).
    private func readUntilTheCloudAsks(lineFrames: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldReset", "YES", "-GatefoldSkipWelcome", "YES", "-GatefoldSignedIn", "YES",
            "-GatefoldFakeScenario", "expiresWhileReading", "-GatefoldDownloadAll", "YES", "-GatefoldNoLatency", "YES",
            "-GatefoldOpenBook", "gutenberg-alice-in-wonderland", "-GatefoldGoTo", "0.31", "-GatefoldTheme", "daylight",
            "-GatefoldPageTurn", "slide",
        ] + (lineFrames ? ["-GatefoldLineFramesProbe", "YES"] : [])
        app.launch()
        let page = app.descendants(matching: .any)["reader.page"]
        XCTAssertTrue(page.waitForExistence(timeout: 60))
        let ready = app.descendants(matching: .any)["reader.pageReady"]
        let shown = readsUntil(reads: 1200) { ready.exists && (ready.value as? String) == "1" }
        XCTAssertTrue(shown.ok, "the page showed (\(shown.reads) reads)")
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        return app
    }

    func testTheReaderAsksToSignInAgainAndOneTapOpensSignIn() {
        let app = readUntilTheCloudAsks()
        // While he reads, the ask is the tab in the page's top margin; its one tap opens sign-in.
        let tab = app.descendants(matching: .any)["reader.signInTab"]
        XCTAssertTrue(tab.waitForExistence(timeout: 30), "the reader asks him to sign in again")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "reader-sign-in-tab"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertTrue(tab.isHittable, "the tab answers a tap")
        tab.tap()
        let email = app.textFields["signIn.email"]
        XCTAssertTrue(email.waitForExistence(timeout: 15) || app.secureTextFields.firstMatch.waitForExistence(timeout: 5), "sign-in opened")
        let sheet = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        sheet.name = "reader-sign-in-sheet"
        sheet.lifetime = .keepAlways
        add(sheet)
    }

    func testLaterPutsTheSlipAwayForThisOpen() {
        let app = readUntilTheCloudAsks()
        let tab = app.descendants(matching: .any)["reader.signInTab"]
        XCTAssertTrue(tab.waitForExistence(timeout: 30))
        // With the controls up the whole notice shows, with Later.
        let slip = app.descendants(matching: .any)["reader.signInSlip"]
        let page = app.descendants(matching: .any)["reader.page"]
        for _ in 0..<3 where !slip.exists {
            page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            _ = slip.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(slip.exists, "the controls show the whole notice")
        app.buttons["reader.signInLater"].tap()
        XCTAssertTrue(slip.waitForNonExistence(timeout: 10), "Later puts it away")
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["reader.contents"].waitForNonExistence(timeout: 10), "the controls went down")
        XCTAssertFalse(tab.exists, "Later puts the tab away too, for this open")
    }

    /// The ask never stands on a line of the page, on the page it came up on or on the next (gatefold#654: it floated
    /// over the top of the page and hid the first line of every page he read). Where each line stands comes from
    /// `reader.lineFrames` (window points, the probe never reads the words); the ask is whichever of its forms shows.
    /// Judged in reads, never seconds; `HangGuard` only catches a hang.
    func testTheAskNeverStandsOnALine() {
        let app = readUntilTheCloudAsks(lineFrames: true)
        let tab = app.descendants(matching: .any)["reader.signInTab"]
        let slip = app.descendants(matching: .any)["reader.signInSlip"]
        XCTAssertTrue(readsUntil(reads: 150) { tab.exists || slip.exists }.ok, "the reader asks him to sign in again")
        for step in ["the page it came up on", "the next page"] {
            if step == "the next page" {
                let before = (app.descendants(matching: .any)["reader.lineFrames"].value as? String) ?? ""
                app.descendants(matching: .any)["reader.page"].coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
                _ = readsUntil(reads: 50) { ((app.descendants(matching: .any)["reader.lineFrames"].value as? String) ?? "") != before }
            }
            let lines = settledLines(app, step)
            // Any count: at 31% the next page ends Alice's chapter IV in 4 lines.
            XCTAssertFalse(lines.isEmpty, "\(step): the probe found the page's lines")
            let later = app.descendants(matching: .any)["reader.signInTab.later"]
            let ask = tab.exists ? tab.frame.union(later.exists ? later.frame : tab.frame) : slip.frame
            XCTAssertFalse(ask.isEmpty, "\(step): the ask is on screen")
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "sign-in-ask-\(step.replacingOccurrences(of: " ", with: "-"))"
            shot.lifetime = .keepAlways
            add(shot)
            let covered = lines.filter { $0.intersects(ask.insetBy(dx: 0, dy: 1)) }
            XCTAssertTrue(covered.isEmpty, "\(step): the ask (\(ask)) stands on \(covered.count) line(s): \(covered.prefix(3))")
        }
        // While he reads, the ask's own cross puts it away for this open.
        let later = app.descendants(matching: .any)["reader.signInTab.later"]
        XCTAssertTrue(later.exists && later.isHittable, "the ask can be put away where it stands")
        guard later.exists else { return }
        later.tap()
        XCTAssertTrue(readsUntil(reads: 50) { !tab.exists && !slip.exists }.ok, "the ask went away")
    }

    private var hung = false
    private func readsUntil(reads: Int, _ done: () -> Bool) -> (ok: Bool, reads: Int) {
        if hung { return (false, 0) }
        let guardEnds = Date().addingTimeInterval(HangGuard.seconds(reads: reads))
        for read in 1...reads {
            if done() { return (true, read) }
            if Date() > guardEnds { hung = true; return (false, read) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return (false, reads)
    }

    /// The line frames once the probe's last pass has read the same three times running.
    private func settledLines(_ app: XCUIApplication, _ step: String) -> [CGRect] {
        let probe = app.descendants(matching: .any)["reader.lineFrames"]
        var last = "", same = 0
        let settled = readsUntil(reads: 100) {
            let now = (probe.value as? String) ?? ""
            same = now == last && now.hasPrefix("pass 3: ") ? same + 1 : 0
            last = now
            return same >= 3
        }
        XCTAssertTrue(settled.ok, "\(step): the line frames settled within \(settled.reads) reads (\(last.prefix(80)))")
        return last.dropFirst("pass 3: ".count).split(separator: ";").compactMap { item in
            let n = item.split(separator: ",").compactMap { Double($0) }
            return n.count == 4 ? CGRect(x: n[0], y: n[1], width: n[2], height: n[3]) : nil
        }
    }
}
