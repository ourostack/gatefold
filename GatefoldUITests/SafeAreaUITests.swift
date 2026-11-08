import XCTest

/// Every screen keeps to the safe area on all four edges, however the system reports it. On Ari's
/// folded Duo (build 13) the cover screen reported its status column as a side inset the simulator
/// never did, and the shelf ran off the left edge. These tests add system insets the way iOS does
/// (`-GatefoldSystemInsets top,leading,bottom,trailing`, through `additionalSafeAreaInsets`) and
/// check nothing lands in them.
@MainActor
final class SafeAreaUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(insets: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldReset", "YES", "-GatefoldSkipWelcome", "YES",
            "-GatefoldSignedIn", "YES", "-GatefoldNoLatency", "YES", "-GatefoldSystemInsets", insets,
        ] + extra
        app.launch()
        return app
    }

    private func edges(_ insets: String) -> (top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat) {
        let v = insets.split(separator: ",").map { CGFloat(Double($0)!) }
        return (v[0], v[1], v[2], v[3])
    }

    /// The shelf's header, its first cover and the grid sit inside the injected insets, with the
    /// gutter still showing on the leading side (not flush against the edge, as on the device).
    private func checkShelf(insets: String, file: StaticString = #filePath, line: UInt = #line) {
        let app = launch(insets: insets)
        let e = edges(insets)
        let window = app.windows.firstMatch.frame
        let title = app.staticTexts["Library"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 30), "the shelf came up", file: file, line: line)
        XCTAssertTrue(app.staticTexts["Moby-Dick"].firstMatch.waitForExistence(timeout: 30), file: file, line: line)
        sleep(2)
        let left = window.minX + e.leading
        let right = window.maxX - e.trailing
        XCTAssertGreaterThanOrEqual(title.frame.minX, left + 12, "Library keeps a gutter inside the leading inset (\(title.frame))", file: file, line: line)
        // The shelf's gutter is 20, 32 or 44 pt by width (ShelfMetrics); an iPad keeps 44.
        XCTAssertLessThanOrEqual(title.frame.minX, left + 48, "Library starts at the gutter, not pushed inward (\(title.frame))", file: file, line: line)
        XCTAssertGreaterThanOrEqual(title.frame.minY, window.minY + e.top, file: file, line: line)
        for id in ["library.import", "library.account"] {
            let button = app.descendants(matching: .any)[id].firstMatch
            XCTAssertTrue(button.exists, id, file: file, line: line)
            XCTAssertLessThanOrEqual(button.frame.maxX, right, "\(id) clears the trailing inset (\(button.frame), right \(right))", file: file, line: line)
            XCTAssertGreaterThanOrEqual(button.frame.minX, left, file: file, line: line)
        }
        for name in ["Reading Now", "All Books"] {
            let heading = app.staticTexts[name].firstMatch
            XCTAssertTrue(heading.exists, name, file: file, line: line)
            XCTAssertGreaterThanOrEqual(heading.frame.minX, left + 12, "\(name) keeps the gutter (\(heading.frame))", file: file, line: line)
        }
        let grid = app.descendants(matching: .any)["library.grid"].firstMatch
        XCTAssertGreaterThanOrEqual(grid.frame.minX, left - 0.5, "the grid starts inside the safe area (\(grid.frame))", file: file, line: line)
        XCTAssertLessThanOrEqual(grid.frame.maxX, right + 0.5, "the grid ends inside the safe area (\(grid.frame))", file: file, line: line)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "shelf-insets-\(insets)"
        shot.lifetime = .keepAlways
        add(shot)
        app.quit()
    }

    /// A status column at the trailing edge, as the folded Duo's cover screen reports it.
    func testShelfKeepsClearOfATrailingStatusColumn() { checkShelf(insets: "0,0,0,81") }

    /// A camera or column at the leading edge.
    func testShelfKeepsClearOfALeadingInset() { checkShelf(insets: "0,60,0,0") }

    /// The shelf keeps clear of a side inset once, never twice: an injected 81 pt status column on a
    /// screen that already reports its own (the Duo simulator's cover screen, 84 pt) leaves the larger
    /// of the two, as a device would, and the shelf's width is the screen less exactly that. Build 14
    /// reserved 84 + 81 = 165 pt, an empty band no device has.
    func testShelfAppliesASideInsetOnce() {
        func measure(_ insets: String?) -> (leading: Int, trailing: Int, width: Int, window: Int) {
            let app = XCUIApplication()
            app.launchArguments = ["-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldReset", "YES", "-GatefoldSkipWelcome", "YES",
                                   "-GatefoldSignedIn", "YES", "-GatefoldNoLatency", "YES"] + (insets.map { ["-GatefoldSystemInsets", $0] } ?? [])
            app.launch()
            XCTAssertTrue(app.staticTexts["Moby-Dick"].firstMatch.waitForExistence(timeout: 30))
            sleep(2)
            let probe = app.descendants(matching: .any)["library.safeInsets"]
            XCTAssertTrue(probe.waitForExistence(timeout: 10))
            // The probe reads "leading <pt> trailing <pt> width <pt>" once the shelf has measured itself.
            _ = XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "label BEGINSWITH 'leading'"), evaluatedWith: probe)], timeout: 10)
            var v = probe.label.split(separator: " ").compactMap { Int($0) }
            if v.count != 3 {
                XCTFail("the shelf's insets probe read \"\(probe.label)\"")
                v = [0, 0, 0]
            }
            let window = Int(app.windows.firstMatch.frame.width.rounded())
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "shelf-inset-\(insets ?? "none")"
            shot.lifetime = .keepAlways
            add(shot)
            app.quit()
            return (v[0], v[1], v[2], window)
        }
        let own = measure(nil)
        let injected = measure("0,0,0,81")
        XCTAssertEqual(injected.trailing, max(own.trailing, 81), "the larger of the screen's own \(own.trailing) and 81, once (got \(injected.trailing))")
        XCTAssertEqual(injected.width, injected.window - injected.leading - injected.trailing, "the shelf spans the screen less the insets, once")
        XCTAssertEqual(own.width, own.window - own.leading - own.trailing)
    }

    /// Insets on every edge at once.
    func testShelfKeepsInsideInsetsOnAllEdges() { checkShelf(insets: "40,30,30,30") }

    /// Sign In keeps its fields and button inside a side inset too.
    func testSignInKeepsClearOfATrailingInset() {
        let app = XCUIApplication()
        app.launchArguments = ["-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldReset", "YES", "-GatefoldSystemInsets", "0,0,0,81"]
        app.launch()
        let window = app.windows.firstMatch.frame
        let start = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Sign In'")).firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 30))
        sleep(1)
        let right = window.maxX - 81
        for element in app.buttons.allElementsBoundByIndex where element.isHittable {
            XCTAssertLessThanOrEqual(element.frame.maxX, right + 0.5, "\(element.label) clears the trailing inset (\(element.frame))")
        }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "welcome-insets"
        shot.lifetime = .keepAlways
        add(shot)

        // On to the form: the fields and the button keep inside the inset too.
        app.buttons["welcome.signIn"].tap()
        let email = app.textFields.firstMatch
        XCTAssertTrue(email.waitForExistence(timeout: 15))
        sleep(1)
        // The system keyboard (its "continue" key) is iOS's, laid out across the whole screen; only
        // Gatefold's own fields and buttons are checked.
        let keyboard = app.keyboards.firstMatch.exists ? app.keyboards.firstMatch.frame : .null
        for element in app.textFields.allElementsBoundByIndex + app.secureTextFields.allElementsBoundByIndex + app.buttons.allElementsBoundByIndex
            where element.isHittable && !keyboard.intersects(element.frame) {
            XCTAssertLessThanOrEqual(element.frame.maxX, right + 0.5, "\(element.label) clears the trailing inset (\(element.frame))")
            XCTAssertGreaterThanOrEqual(element.frame.minX, window.minX - 0.5, "\(element.label) starts on screen (\(element.frame))")
        }
        let form = XCTAttachment(screenshot: app.screenshot())
        form.name = "sign-in-insets"
        form.lifetime = .keepAlways
        add(form)
    }
}
