import XCTest

/// Highlights on the fake Cloud: the InkPad's are drawn in the book, a note's card shows the note,
/// and a new highlight can be made from a text selection.
///
/// The app exposes a hidden probe, `reader.highlights`: its label reads "drawn <boxes on screen> of
/// <highlights in the book>", and its value gives window points of the first highlight box and the
/// first note on screen (`first=x,y;note=x,y`), so the test can tap them.
@MainActor
final class HighlightUITests: XCTestCase {
    private var app: XCUIApplication!
    private let env = ProcessInfo.processInfo.environment

    override func setUp() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = env["GATEFOLD_SHOTS"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    private var probe: XCUIElement { element("reader.highlights") }

    /// The probe's label once it matches `format` (an NSPredicate on `label`).
    @discardableResult
    private func waitForProbe(_ format: String, _ args: CVarArg..., timeout: TimeInterval = 30, _ what: String,
                              file: StaticString = #filePath, line: UInt = #line) -> String {
        let predicate = NSPredicate(format: format, argumentArray: args)
        let result = XCTWaiter.wait(for: [expectation(for: predicate, evaluatedWith: probe)], timeout: timeout)
        XCTAssertEqual(result, .completed, "\(what): probe says \(probe.label) [\(probe.value as? String ?? "")]", file: file, line: line)
        return probe.label
    }

    private func point(_ name: String) -> CGVector? {
        let value = probe.value as? String ?? ""
        for part in value.split(separator: ";") {
            let kv = part.split(separator: "=")
            guard kv.count == 2, kv[0] == name else { continue }
            let xy = kv[1].split(separator: ",").compactMap { Double($0) }
            if xy.count == 2 { return CGVector(dx: xy[0], dy: xy[1]) }
        }
        return nil
    }

    /// The contents sheet rises as the book opens, and a tap on its tab while it is still rising can be
    /// lost: on a loaded Duo run the highlights were placed, the tab was tapped a moment later, and
    /// the Contents list stayed for 60 s. Tap until the tab is selected.
    private func select(_ tab: XCUIElement) {
        for _ in 0..<3 {
            tab.tap()
            if tab.wait(for: \.isSelected, toEqual: true, timeout: 3) { return }
        }
        XCTFail("the \(tab.label) tab never took a tap")
    }

    private func tap(at offset: CGVector) {
        app.coordinate(withNormalizedOffset: .zero).withOffset(offset).tap()
    }

    func testTheInkPadsHighlightsAreDrawnAndANewOneCanBeMade() throws {
        app.launchArguments = [
            "-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldReset", "YES", "-GatefoldSkipWelcome", "YES",
            "-GatefoldSignedIn", "YES", "-GatefoldDownloadAll", "YES",
            "-GatefoldOpenBook", "gutenberg-pride-and-prejudice",
            "-GatefoldTheme", env["GATEFOLD_THEME"] ?? "vellum", "-GatefoldForcePosture", "single", "-GatefoldSheet", "contents",
        ]
        app.launch()
        XCTAssertTrue(element("reader.page").waitForExistence(timeout: 30))

        // The contents sheet's Highlights tab lists the InkPad's two, in reading order.
        let tab = app.buttons["Highlights"]
        XCTAssertTrue(tab.waitForExistence(timeout: 30))
        select(tab)
        let row = app.buttons.matching(identifier: "highlights.row").firstMatch
        if !row.waitForExistence(timeout: 60) { shot("highlights-01-list-missing") }
        XCTAssertTrue(row.exists, "the InkPad's highlights are listed")
        XCTAssertEqual(app.buttons.matching(identifier: "highlights.row").count, 2)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Highlighted on your InkPad'")).firstMatch.exists)
        shot("highlights-01-list")

        // Jump to the first: Chapter I opens with both drawn.
        row.tap()
        waitForProbe("label MATCHES 'drawn [1-9][0-9]* of 2'", timeout: 60, "the InkPad's highlights are drawn on the page")
        sleep(1)
        shot("highlights-02-drawn")

        // Tapping the note shows its words and where it came from.
        let note = try XCTUnwrap(point("note"), "a note is on screen: \(probe.value as? String ?? "")")
        tap(at: note)
        sleep(1)
        shot("highlights-03a-after-note-tap")
        let card = element("highlight.note")
        XCTAssertTrue(card.waitForExistence(timeout: 10), "the note's card")
        XCTAssertTrue(card.label.hasPrefix("And so it begins."))
        XCTAssertTrue(element("highlight.provenance").label.hasPrefix("Noted on your InkPad · "))
        shot("highlights-03-note-card")
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(card.waitForNonExistence(timeout: 10))

        // Press and hold a word in the page, then Highlight it.
        let page = element("reader.page")
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.78)).press(forDuration: 1.2)
        let highlight = app.menuItems["Highlight"].exists ? app.menuItems["Highlight"] : app.buttons["Highlight"]
        XCTAssertTrue(highlight.waitForExistence(timeout: 10), "the selection menu offers Highlight")
        XCTAssertTrue(app.menuItems["Note"].exists || app.buttons["Note"].exists, "and Note")
        shot("highlights-04-selection-menu")
        highlight.tap()
        waitForProbe("label ENDSWITH ' of 3'", timeout: 20, "the new highlight joins the book")
        waitForProbe("NOT (label BEGINSWITH 'drawn 0 ')", timeout: 20, "and is drawn")
        sleep(1)
        shot("highlights-05-added")

        // Its card says it was made here; Remove takes it away again. Tap the box itself: the press
        // picks the nearest word, which can start a little right of the press point. (The lowest box
        // isn't always the new one: at build 15's larger type an InkPad highlight sits lower.)
        let added = try XCTUnwrap(point("here"), "the new highlight is on screen: \(probe.value as? String ?? "")")
        tap(at: added)
        let provenance = element("highlight.provenance")
        XCTAssertTrue(provenance.waitForExistence(timeout: 10), "tapping the new highlight opens its card")
        XCTAssertEqual(provenance.label, "Highlighted here · just now")
        shot("highlights-06-own-card")
        element("highlight.remove").tap()
        waitForProbe("label ENDSWITH ' of 2'", timeout: 20, "removing it")
    }
}
