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
