import OuroHXTesting
import XCTest

/// Scratch driver for the 2026-11-27 jank hunt. Never committed. Reads a script from JANK_SCRIPT
/// (steps split by "|"), runs it, and logs each step with the wall clock so a host recording can be lined up.
@MainActor
class JankHuntBase: XCTestCase {
    private var app = XCUIApplication()
    private let env = ProcessInfo.processInfo.environment
    /// The host folder the runner fills (TEST_RUNNER_ env did not reach the runner on CI, so a fixed host path).
    private var out: URL { URL(fileURLWithPath: env["JANK_OUT"] ?? (try? String(contentsOfFile: "/Users/Shared/jank/out.txt", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? NSTemporaryDirectory()) }
    private var hinge: OuroDuoHinge?

    nonisolated(unsafe) static var lastDrag: (id: String, before: String, to: Double)?
    /// Where a scrubber's value puts the reader, from 0 to 1: "31 percent" before the pages are counted, "Page 225 of 743" after.
    static func position(_ value: String) -> Double? {
        let n = value.split(whereSeparator: { !$0.isNumber }).compactMap { Double($0) }
        if value.contains("percent"), n.count == 1 { return n[0] / 100 }
        if value.hasPrefix("Page"), n.count == 2, n[1] > 0 { return n[0] / n[1] }
        return nil
    }

    private func log(_ s: String) {
        let line = String(format: "JANK %.3f %@\n", Date().timeIntervalSince1970, s)
        print(line, terminator: "")
        XCTContext.runActivity(named: line.trimmingCharacters(in: .newlines)) { _ in }
        let url = out.appendingPathComponent("steps.log")
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? Data(line.utf8).write(to: url) }
    }

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        try? s.pngRepresentation.write(to: out.appendingPathComponent("\(name).png"))
    }

    private func frameOf(_ id: String) -> String {
        let e = el(id)
        guard e.exists else { return "\(id)=absent" }
        return "\(id)=\(e.frame) v=\((e.value as? String ?? "").prefix(80))"
    }

    func run(_ script: String, hingeDir: String) throws {
        continueAfterFailure = true
        if env["OURO_DUO_POSTURE_DIR"] == nil, !hingeDir.isEmpty { setenv("OURO_DUO_POSTURE_DIR", hingeDir, 1) }
        log("script \(script.count) chars")
        for raw in script.split(separator: "|") {
            let step = raw.trimmingCharacters(in: .whitespaces)
            let parts = step.split(separator: " ").map(String.init)
            guard let op = parts.first else { continue }
            let rest = Array(parts.dropFirst())
            log("begin \(step)")
            switch op {
            case "launch":
                app = XCUIApplication()
                app.launchArguments = ["-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldSkipWelcome", "YES",
                                       "-GatefoldSignedIn", "YES", "-GatefoldReset", "YES"] + rest
                app.launch()
            case "launchbare":
                app = XCUIApplication()
                app.launchArguments = ["-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldReset", "YES"] + rest
                app.launch()
            case "field":
                let f = app.searchFields.firstMatch.exists ? app.searchFields.firstMatch : app.textFields.firstMatch
                if f.waitForExistence(timeout: 5) { f.tap() } else { log("no field") }
            case "tapprobe":
                let v = (el("reader.highlights").value as? String) ?? ""
                log("probe \(el("reader.highlights").label) [\(v)]")
                for part in v.split(separator: ";") {
                    let kv = part.split(separator: "=")
                    guard kv.count == 2, kv[0] == Substring(rest.first ?? "first") else { continue }
                    let xy = kv[1].split(separator: ",").compactMap { Double($0) }
                    if xy.count == 2 { app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: xy[0], dy: xy[1])).tap() }
                }
            case "tapfirst":
                // tapfirst <id-prefix>: taps the first hittable element whose identifier begins with the prefix.
                let q = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", rest[0]))
                let n = min(q.count, 12)
                var done = false
                for i in 0..<n where !done { let e = q.element(boundBy: i); if e.isHittable { log("tapfirst \(e.identifier)"); e.tap(); done = true } }
                if !done { log("tapfirst none \(rest[0])") }
            case "relaunch":
                app = XCUIApplication()
                app.launchArguments = ["-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldSkipWelcome", "YES",
                                       "-GatefoldSignedIn", "YES"] + rest
                app.launch()
            case "waitfor":
                let ok = el(rest[0]).waitForExistence(timeout: Double(rest.count > 1 ? rest[1] : "60") ?? 60)
                log("waitfor \(rest[0]) \(ok)")
            case "ready":
                let until = Date().addingTimeInterval(Double(rest.first ?? "60") ?? 60)
                while Date() < until, (el("reader.pageReady").value as? String) != "1" { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
                log("ready \((el("reader.pageReady").value as? String) ?? "-")")
            case "tap":
                let e = el(rest[0])
                if e.waitForExistence(timeout: 10) { e.tap() } else { log("missing \(rest[0])") }
            case "tapif":
                let e = el(rest[0])
                if e.exists && e.isHittable { e.tap() } else { log("absent \(rest[0])") }
            case "label":
                let q = rest.joined(separator: " ")
                let e = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", q)).firstMatch
                if e.waitForExistence(timeout: 10) { e.tap() } else { log("missing label \(q)") }
            case "tapxy":
                app.coordinate(withNormalizedOffset: CGVector(dx: Double(rest[0])!, dy: Double(rest[1])!)).tap()
            case "drag":
                let a = app.coordinate(withNormalizedOffset: CGVector(dx: Double(rest[0])!, dy: Double(rest[1])!))
                let b = app.coordinate(withNormalizedOffset: CGVector(dx: Double(rest[2])!, dy: Double(rest[3])!))
                a.press(forDuration: 0.05, thenDragTo: b, withVelocity: XCUIGestureVelocity(Double(rest.count > 4 ? rest[4] : "800")!), thenHoldForDuration: 0.05)
            case "dragel":
                // dragel <id> <from> <to> [velocity] [dy]: drags along the element's own frame, at its middle (or dy points
                // off it), from and to fractions of its width; dragcheck then fails the journey if it didn't land at <to>.
                let e = el(rest[0])
                guard e.waitForExistence(timeout: 10) else { XCTFail("dragel: no \(rest[0])"); break }
                let before = (e.value as? String) ?? ""
                let f = e.frame
                let origin = app.coordinate(withNormalizedOffset: .zero)
                let y = f.midY + (rest.count > 4 ? Double(rest[4])! : 0)
                let a = origin.withOffset(CGVector(dx: f.minX + f.width * Double(rest[1])!, dy: y))
                let b = origin.withOffset(CGVector(dx: f.minX + f.width * Double(rest[2])!, dy: y))
                log("dragel \(rest[0]) at \(f) y \(y) from \(before)")
                Self.lastDrag = (rest[0], before, Double(rest[2])!)
                a.press(forDuration: 0.05, thenDragTo: b, withVelocity: XCUIGestureVelocity(Double(rest.count > 3 ? rest[3] : "800")!), thenHoldForDuration: 0.05)
            case "dragcheck":
                // dragcheck: once the jump has landed and the controls are up, the last dragel's element must exist and sit
                // within 0.1 of where the drag ended. A changed label isn't enough: "31 percent" becomes "Page 225 of 743"
                // when the pages are counted, without anything moving, so a drag that missed it would pass.
                guard let last = Self.lastDrag else { XCTFail("dragcheck before any dragel"); break }
                let e = el(last.id)
                let now = e.waitForExistence(timeout: 10) ? ((e.value as? String) ?? "") : "absent"
                let at = Self.position(now)
                log("dragcheck \(last.id) from \(last.before) to \(now), at \(at.map { String(format: "%.3f", $0) } ?? "?") for \(last.to)")
                XCTAssertTrue(e.exists, "dragcheck: \(last.id) is not on screen to read")
                guard let at else { XCTFail("dragcheck: can't read a position from \"\(now)\""); break }
                XCTAssertLessThanOrEqual(abs(at - last.to), 0.1, "\(last.id) reads \(now), not near \(last.to): the drag missed it")
            case "swipe":
                let w = app.windows.firstMatch
                switch rest[0] { case "up": w.swipeUp(); case "down": w.swipeDown(); case "left": w.swipeLeft(); default: w.swipeRight() }
            case "press":
                app.coordinate(withNormalizedOffset: CGVector(dx: Double(rest[0])!, dy: Double(rest[1])!)).press(forDuration: Double(rest.count > 2 ? rest[2] : "1.2")!)
            case "type":
                app.typeText(rest.joined(separator: " "))
            case "wait":
                RunLoop.current.run(until: Date().addingTimeInterval(Double(rest[0]) ?? 1))
            case "orient":
                let o: UIDeviceOrientation = ["portrait": .portrait, "left": .landscapeLeft, "right": .landscapeRight, "upside": .portraitUpsideDown][rest[0]] ?? .portrait
                XCUIDevice.shared.orientation = o
            case "hinge":
                if env["OURO_DUO_POSTURE_DIR"] == nil,
                   let dir = try? String(contentsOfFile: "/Users/Shared/jank/hinge.txt", encoding: .utf8) {
                    setenv("OURO_DUO_POSTURE_DIR", dir.trimmingCharacters(in: .whitespacesAndNewlines), 1)
                }
                if hinge == nil {
                    do { hinge = try OuroDuoHinge() } catch { log("hinge init failed: \(error)") }
                }
                guard let h = hinge else { log("no hinge"); break }
                switch rest.joined(separator: " ") {
                case "rotate": try? h.rotateRight()
                case "closed": try? h.set(.closed)
                case "open": try? h.set(.open)
                default: try? h.set(.partiallyOpen)
                }
            case "home":
                XCUIDevice.shared.press(.home)
            case "activate":
                app.activate()
            case "shot":
                shot(rest[0])
            case "frames":
                log("frames " + rest.map(frameOf).joined(separator: " ; ") + " window=\(app.windows.firstMatch.frame)")
            case "dump":
                let tree = app.debugDescription
                let a = XCTAttachment(string: tree); a.name = "tree-\(rest.first ?? "tree")"; a.lifetime = .keepAlways; add(a)
            case "watch":
                // watch <seconds> <id...>: log the frames of ids every 0.1 s, to see what moves.
                let until = Date().addingTimeInterval(Double(rest[0]) ?? 2)
                while Date() < until {
                    log("watch " + rest.dropFirst().map(frameOf).joined(separator: " ; "))
                    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                }
            default:
                log("unknown \(op)")
            }
            log("end \(op)")
        }
    }
}
