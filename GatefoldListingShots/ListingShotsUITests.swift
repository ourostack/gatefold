import XCTest

/// The App Store screenshots' scenes (screenshots/spec.json), on release only (.github/workflows/screenshots.yml).
/// Not part of the Gatefold scheme, so no CI shard runs it.
///
/// For each scene on this device (or only GATEFOLD_SHOTS_SCENE) it launches the app into the scene's state, waits for the scene's ready element,
/// then hands over to the host: it writes `<scene>.ready` in the shots folder, and the host
/// (scripts/screenshots/capture.py watch) stages the status bar, shoots until three frames in a row match and writes
/// `<scene>.done` (or `.fail`). The host takes the picture, not this test, so the Duo's cover display and the iPad's
/// status bar come out the same every time.
@MainActor
final class ListingShotsUITests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment

    func testListingScenes() throws {
        continueAfterFailure = true
        let dir = try XCTUnwrap(env["GATEFOLD_SHOTS_DIR"], "GATEFOLD_SHOTS_DIR names the host folder the shots go to")
        let device = try XCTUnwrap(env["GATEFOLD_SHOTS_DEVICE"], "GATEFOLD_SHOTS_DEVICE is ipad, iphone or duo")
        let specPath = try XCTUnwrap(env["GATEFOLD_SHOTS_SPEC"], "GATEFOLD_SHOTS_SPEC is screenshots/spec.json's path")
        let spec = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: specPath))) as? [String: Any])
        let launch = spec["launch"] as? [String] ?? []
        // The workflow runs one scene per test run (GATEFOLD_SHOTS_SCENE), so a UI query that times out costs that
        // scene one try, not every scene after it.
        let only = env["GATEFOLD_SHOTS_SCENE"]
        let attempt = env["GATEFOLD_SHOTS_TRY"] ?? "1"
        let scenes = (spec["scenes"] as? [[String: Any]] ?? []).filter {
            ($0["devices"] as? [String] ?? []).contains(device) && (only == nil || $0["id"] as? String == only)
        }
        XCTAssertFalse(scenes.isEmpty, "no scene \(only ?? "") in the spec runs on \(device)")

        for scene in scenes {
            let id = scene["id"] as? String ?? "?"
            XCTContext.runActivity(named: "scene \(id)") { _ in
                shoot(scene: scene, id: id, launch: launch, dir: dir, attempt: attempt)
            }
        }
    }

    private func shoot(scene: [String: Any], id: String, launch: [String], dir: String, attempt: String) {
        let landscape = scene["orientation"] as? String == "landscape"
        XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
        let app = XCUIApplication()
        app.launchArguments = launch + (scene["args"] as? [String] ?? [])
        app.launch()
        XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
        defer { app.terminate() }

        let ready = scene["ready"] as? [String: String] ?? [:]
        // A query by element type and identifier, never the whole tree: the reader's web views make a whole-tree
        // snapshot slow enough to time out on a busy runner (gatefold#28).
        let kinds: [String: XCUIElement.ElementType] = ["staticText": .staticText, "other": .other, "button": .button, "any": .any]
        let kind = kinds[ready["type"] ?? ""] ?? .any
        let element = app.descendants(matching: kind).matching(identifier: ready["id"] ?? "").firstMatch
        let launched = Date()
        guard element.waitForExistence(timeout: 90) else {
            XCTFail("\(id): \(ready["id"] ?? "?") never appeared"); return
        }
        var predicate: NSPredicate?
        if let label = ready["label"] { predicate = NSPredicate(format: "label == %@", label) }
        if let part = ready["label_contains"] { predicate = NSPredicate(format: "label CONTAINS %@", part) }
        // A rotation can lay the page out once more before it settles, so its count need not be 0.
        if let start = ready["label_begins"] { predicate = NSPredicate(format: "label BEGINSWITH %@", start) }
        if let predicate {
            let waited = XCTWaiter.wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: 90)
            // Say what it read instead (a status like "settling 1" or "ready 1", never page text), so a red tells a
            // slow device from a check that settled elsewhere (gatefold#297).
            guard waited == .completed else {
                XCTFail("\(id): \(ready["id"] ?? "?") never read as ready; it reads \"\(element.label)\""); return
            }
        }
        // The workflow keeps these lines (tests.log), to measure the waits below and the host's (gatefold#150).
        print(String(format: "ListingShots timing: %@ ready %.1f s after launch", id, Date().timeIntervalSince(launched)))
        // The shelf reads ready seconds after launch, while -GatefoldDownloadAll is still fetching every book: each
        // one downloading pulses its icon, and the host's status bar and screenshots stalled behind that load on all
        // of shelf's tries in three runs (gatefold#150). Hand over only once no book on screen is still downloading.
        // Scenes that open a book are past it (the reader is up), so only the library's scenes ask.
        let opensABook = (scene["args"] as? [String] ?? []).contains("-GatefoldOpenBook")
        let downloading = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'book.' AND value CONTAINS 'downloading'")).firstMatch
        if !opensABook, downloading.exists {
            let fetched = XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "exists == false"),
                                                           evaluatedWith: downloading)], timeout: 90)
            guard fetched == .completed else { XCTFail("\(id): a book was still downloading after 90 s"); return }
        }
        print(String(format: "ListingShots timing: %@ downloads done %.1f s after launch", id, Date().timeIntervalSince(launched)))
        fflush(stdout)  // written now, so a runner that dies still leaves it in the log

        guard noTrademarkOnScreen(app, id) else { return }

        let folder = URL(fileURLWithPath: dir)
        let handoff = "\(id).\(attempt)"
        let done = folder.appendingPathComponent("\(handoff).done"), fail = folder.appendingPathComponent("\(handoff).fail")
        do {
            try Data(id.utf8).write(to: folder.appendingPathComponent("\(handoff).ready"))
        } catch {
            XCTFail("\(id): could not write to the shots folder: \(error)"); return
        }
        // The host shoots until the screen holds still; a scene that never settles fails there, with its reason.
        // Longer than the host's worst case (capture.py WATCH_WORST, 220 s): a slow status bar, 80 s of frames, a last
        // screenshot, and the unanswered screenshots it asks again (gatefold#150), each bounded.
        let handed = Date()
        let deadline = handed.addingTimeInterval(240)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: done.path) {
                print(String(format: "ListingShots timing: %@ host answered in %.1f s", id, Date().timeIntervalSince(handed)))
                fflush(stdout)
                _ = noTrademarkOnScreen(app, id)  // and nothing turned up while the host shot
                return
            }
            if let why = try? String(contentsOf: fail, encoding: .utf8) { XCTFail("\(id): \(why)"); return }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTFail("\(id): the host took no picture within 240 s")
    }

    /// Wherever the app speaks of the reader's device (the sync line and slip, the catch-up offer and its tab, a
    /// highlight's source), it says "your e-reader" (gatefold#253); a listing never shows a trademark. One query for all.
    private func noTrademarkOnScreen(_ app: XCUIApplication, _ id: String) -> Bool {
        let names = ["library.syncHealth", "library.syncTrouble", "slip", "banner", "banner.tab",
                     "highlight.provenance"]
        let marks = NSPredicate(format: "identifier IN %@ AND (label CONTAINS[c] 'inkpad' OR label CONTAINS[c] 'pocketbook')", names)
        let shown = app.descendants(matching: .any).matching(marks).firstMatch
        guard shown.exists else { return true }
        XCTFail("\(id): \(shown.identifier) names a trademark on screen")
        return false
    }
}
