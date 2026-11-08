import XCTest

/// #94: after the first page shows, how long the web view of the page in view keeps loading (Readium's
/// spinner stays up until its `load` event), with the page counters on and with none, counted in probe
/// reads of `reader.pageLoading` from the moment the page shows. The open is RotationRepro's (Pride and
/// Prejudice at 0.31, portrait, fresh install). The app logs which images or stylesheets are still out
/// (`loadwatch:`, file names only).
@MainActor
final class PageLoadUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = true
        app = XCUIApplication()
    }

    private let base = [
        "-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldSkipWelcome", "YES",
        "-GatefoldSignedIn", "YES", "-GatefoldAllowReopen", "YES", "-GatefoldNoLatency", "YES",
    ]

    private static let readLimit = 400

    /// Reads from the page showing until its web view has finished loading (the limit when it never does).
    private func readsUntilLoaded(_ extra: [String]) -> (shown: Bool, reads: Int) {
        XCUIDevice.shared.orientation = .portrait
        sleep(1)
        app.launchArguments = base + extra + ["-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES",
                                              "-GatefoldOpenBook", "gutenberg-pride-and-prejudice", "-GatefoldGoTo", "0.31"]
        app.launch()
        let probe = app.descendants(matching: .any)["reader.pageLoading"]
        let up = Date().addingTimeInterval(120)
        var value = ""
        while Date() < up {
            value = (probe.value as? String) ?? ""
            if !value.isEmpty { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        guard !value.isEmpty else { app.terminate(); return (false, Self.readLimit) }
        var reads = 0
        while reads < Self.readLimit, value != "0" {
            reads += 1
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            value = (probe.value as? String) ?? ""
        }
        app.terminate()
        return (true, reads)
    }

    func testThePageInViewFinishesLoadingWithAndWithoutCounters() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "the iPad path where #94 was seen")
        let on = readsUntilLoaded([])
        let off = readsUntilLoaded(["-GatefoldCounters", "0"])
        let onAgain = readsUntilLoaded([])
        print("LOADWATCH reads from the page showing to its web view loaded: counters on \(on.reads), off \(off.reads), on again \(onAgain.reads) (limit \(Self.readLimit))")
        XCTAssertTrue(on.shown && off.shown && onAgain.shown, "a page showed each time")
    }
}
