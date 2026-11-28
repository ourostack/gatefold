import XCTest

/// A book asked for before it is on the device (`-GatefoldOpenBook`, as Shortcuts and the tests ask) opens as it
/// lands, even when it lands last and the shelf's on-device count never reports it. On CI the count's change handler
/// fired for seven landings and never for Emma's, the eighth, so she never opened (gatefold#432).
/// `-GatefoldMissCountOpen` makes the count miss every landing, so only the library's own word can open the book.
@MainActor
final class AskedBookOpensUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    func testTheAskedBookOpensWhenItLandsLastAndTheCountMissesIt() {
        app.launchArguments = ["-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldSkipWelcome", "YES",
                               "-GatefoldSignedIn", "YES", "-GatefoldNoLatency", "YES", "-GatefoldReset", "YES",
                               "-GatefoldDownloadAll", "YES", "-GatefoldOpenBook", "gutenberg-emma", "-GatefoldMissCountOpen", "YES"]
        app.launch()
        let opened = ReaderReads.opened(app, "emma", say: { print("ASKED \($0)") })
        XCTAssertNotNil(opened, "Emma, asked for at launch and downloaded last, opened")
    }
}
