import XCTest

/// Scratch proof (never merged): one book chosen in Files opens; two chosen land on the shelf. The host passes
/// TEST_RUNNER_FOLDER, a folder in "On My iPhone" holding emma.epub and dracula.epub. Public-domain books only.
@MainActor
final class OneBookProofUITests: XCTestCase {
    private var app: XCUIApplication!
    private let env = ProcessInfo.processInfo.environment

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    private func tapFirst(_ candidates: [XCUIElement], _ what: String) {
        for _ in 0..<20 {
            if let hit = candidates.first(where: { $0.exists && $0.isHittable }) { hit.tap(); return }
            sleep(1)
        }
        let tree = XCTAttachment(string: app.debugDescription); tree.name = "stuck-\(what)"; tree.lifetime = .keepAlways; add(tree)
        shot("stuck-\(what)")
        XCTFail("couldn't find \(what)")
    }
    private func menuItem(_ words: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", words)).firstMatch
    }

    /// Opens Choose from Files and goes into the folder.
    private func pickFromFolder() throws {
        let folderName = URL(fileURLWithPath: try XCTUnwrap(env["FOLDER"])).lastPathComponent
        el("library.import").tap()
        XCTAssertTrue(menuItem("Choose from Files").waitForExistence(timeout: 10))
        menuItem("Choose from Files").tap()
        sleep(3)
        // The picker opens where it was last left; only go looking for the folder when it isn't there already.
        if book("emma").waitForExistence(timeout: 3) { return }
        tapFirst([app.buttons["Browse"], app.tabBars.buttons["Browse"]], "Browse")
        tapFirst([app.cells["On My iPhone"], app.staticTexts["On My iPhone"], app.buttons["On My iPhone"]], "On My iPhone")
        let folderCell = app.cells["\(folderName), Folder"]
        if folderCell.waitForExistence(timeout: 5) {
            folderCell.tap(); sleep(2)
            if folderCell.exists && folderCell.isHittable { folderCell.doubleTap(); sleep(2) }
        }
    }
    private func book(_ name: String) -> XCUIElement {
        app.cells.matching(NSPredicate(format: "identifier BEGINSWITH[c] %@ OR label BEGINSWITH[c] %@", name, name)).firstMatch
    }

    func testOneBookChosenOpensAndTwoLandOnTheShelf() throws {
        app = XCUIApplication()
        app.launchArguments = ["-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldSkipWelcome", "YES",
                               "-GatefoldReset", "YES", "-GatefoldNoLatency", "YES", "-GatefoldNoWarm", "YES"]
        app.launch()
        XCTAssertTrue(el("library.import").waitForExistence(timeout: 120))

        // One book: picked, and the reader comes up with no second tap.
        try pickFromFolder()
        tapFirst([book("emma")], "emma")
        sleep(1)
        shot("20-one-picked")
        tapFirst([app.buttons["Open"]], "Open")
        let picked = Date()
        XCTAssertTrue(el("reader.page").waitForExistence(timeout: 60), "one book chosen in Files didn't open")
        print("ONE-BOOK pick-to-reader seconds: \(String(format: "%.2f", Date().timeIntervalSince(picked)))")
        sleep(2)
        shot("21-one-opened")

        // Opened in Gatefold from elsewhere while Emma is open: the host hands over Dracula (`simctl openurl`, so the app
        // stays running) once Emma is up, and Dracula takes Emma's place.
        sleep(20)
        shot("21b-open-in-while-reading")
        XCTAssertTrue(el("reader.page").waitForExistence(timeout: 30), "no book open after Open in")
        app.tap()
        tapFirst([el("reader.close")], "Close Book")
        XCTAssertTrue(el("library.import").waitForExistence(timeout: 30))

        // Two books: they land on the shelf, and nothing opens.
        try pickFromFolder()
        // A tap selects a file; Open takes what's selected.
        tapFirst([book("emma")], "emma")
        tapFirst([book("frankenstein")], "frankenstein")
        sleep(1)
        shot("22-two-chosen")
        tapFirst([app.buttons["Open"]], "Open")
        sleep(2)
        shot("23-two-on-shelf")
        sleep(3)
        XCTAssertFalse(el("reader.page").exists, "two books chosen opened one")
    }
}
