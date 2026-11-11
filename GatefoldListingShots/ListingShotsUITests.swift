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
        let kinds: [String: XCUIElement.ElementType] = ["staticText": .staticText, "other": .other, "button": .button]
        let kind = kinds[ready["type"] ?? ""] ?? .any
        let element = app.descendants(matching: kind).matching(identifier: ready["id"] ?? "").firstMatch
        guard element.waitForExistence(timeout: 60) else {
            XCTFail("\(id): \(ready["id"] ?? "?") never appeared"); return
        }
        var predicate: NSPredicate?
        if let label = ready["label"] { predicate = NSPredicate(format: "label == %@", label) }
        if let part = ready["label_contains"] { predicate = NSPredicate(format: "label CONTAINS %@", part) }
        // A rotation can lay the page out once more before it settles, so its count need not be 0.
        if let start = ready["label_begins"] { predicate = NSPredicate(format: "label BEGINSWITH %@", start) }
        if let predicate {
            let waited = XCTWaiter.wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: 60)
            guard waited == .completed else { XCTFail("\(id): \(ready["id"] ?? "?") never read as ready"); return }
        }

        guard nothingNamesTheEReader(app, id) else { return }

        let folder = URL(fileURLWithPath: dir)
        let handoff = "\(id).\(attempt)"
        let done = folder.appendingPathComponent("\(handoff).done"), fail = folder.appendingPathComponent("\(handoff).fail")
        do {
            try Data(id.utf8).write(to: folder.appendingPathComponent("\(handoff).ready"))
        } catch {
            XCTFail("\(id): could not write to the shots folder: \(error)"); return
        }
        // The host shoots until the screen holds still; a scene that never settles fails there, with its reason.
        // Longer than the host's worst case: 80 s of frames plus a last screenshot and status bar call, 15 s each.
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: done.path) {
                _ = nothingNamesTheEReader(app, id)  // and nothing turned up while the host shot
                return
            }
            if let why = try? String(contentsOf: fail, encoding: .utf8) { XCTFail("\(id): \(why)"); return }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTFail("\(id): the host took no picture within 120 s")
    }

    /// The sync slip, the catch-up offer, its tab and a highlight's source all name the reader's e-reader ("InkPad"),
    /// which a listing never shows. One query for all four, not one each.
    private func nothingNamesTheEReader(_ app: XCUIApplication, _ id: String) -> Bool {
        let names = ["slip", "banner", "banner.tab", "highlight.provenance"]
        let shown = app.descendants(matching: .any).matching(NSPredicate(format: "identifier IN %@", names)).firstMatch
        guard shown.exists else { return true }
        XCTFail("\(id): \(shown.identifier) is on screen, and it names the e-reader")
        return false
    }
}
