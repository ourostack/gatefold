import XCTest

/// Reviewer's driver for the build-47 delight review (local simulators): build 46's TasteB46UITests renamed, with
/// hash checks after build 46's failure cases and tests for margins, brushes, sheets, rotation frames and the chrome's paper.
/// Review branch only; never merged.
@MainActor
final class TasteB47UITests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private var app: XCUIApplication!
    private var lines: [String] = []
    private var tag0 = "taste"

    override func setUp() { continueAfterFailure = true }
    override func tearDown() async throws {
        flush()
        XCUIDevice.shared.orientation = .portrait
    }

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func note(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
        lines.append("\(f.string(from: Date())) \(s)")
        flush()
    }
    private func flush() {
        guard let dir = env["TASTE_SHOTS"] else { return }
        try? lines.joined(separator: "\n").write(toFile: "\(dir)/\(tag0).txt", atomically: true, encoding: .utf8)
    }
    private func shot(_ n: String) {
        guard let dir = env["TASTE_SHOTS"] else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(tag0)-\(n).png"))
    }
    private var extra: [String] { env["TASTE_EXTRA"].map { $0.split(separator: " ").map(String.init) } ?? [] }
    private let common = ["-GatefoldFakeCloud", "YES", "-GatefoldSkipWelcome", "YES", "-GatefoldSignedIn", "YES", "-GatefoldAllowReopen", "YES"]
    private func launch(_ args: [String]) {
        app = XCUIApplication()
        app.launchArguments = ["-GatefoldUITest", "YES"] + common + args + extra
        app.launch()
    }
    private func openBook(_ book: String, at spot: String, reset: Bool = true) {
        launch((reset ? ["-GatefoldReset", "YES"] : []) + ["-GatefoldDownloadAll", "YES", "-GatefoldNoLatency", "YES", "-GatefoldOpenBook", book, "-GatefoldGoTo", spot])
        XCTAssertTrue(el("reader.page").waitForExistence(timeout: 300))
    }
    private var fineTune: XCUIElement { app.buttons["appearance.customize"].exists ? app.buttons["appearance.customize"] : app.buttons["Fine-Tune"].firstMatch }
    private var visibleText: String { (el("reader.visibleText").value as? String) ?? "" }
    private func settle(_ timeout: TimeInterval) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var last = visibleText; var still = Date()
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            let t = visibleText
            if t != last { last = t; still = Date() }
            if !t.isEmpty && Date().timeIntervalSince(still) > 4 { break }
        }
        return last
    }
    private func numbers() -> [String] { app.descendants(matching: .any).matching(identifier: "reader.pageNumber").allElementsBoundByIndex.map { $0.label } }
    private func delay() -> String { (el("reader.numberDelay").value as? String) ?? "-" }
    private func forward(_ n: Int) {
        let page = el("reader.page")
        for _ in 0..<n {
            let before = visibleText
            page.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            let d = Date().addingTimeInterval(20)
            while Date() < d && visibleText == before { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
            _ = settle(30)
        }
    }
    private func landscape() { XCUIDevice.shared.orientation = env["TASTE_LANDSCAPE"] != nil ? .landscapeLeft : .portrait; sleep(2) }
    private func leave() {
        XCUIDevice.shared.press(.home)
        sleep(2)
        XCUIApplication(bundleIdentifier: "com.apple.springboard").activate()
        sleep(4)
        app.terminate()
    }

    /// Ten forward turns, logging the page numbers on screen.
    func testA_numbers() throws {
        tag0 = "numbers"
        landscape()
        openBook("gutenberg-pride-and-prejudice", at: env["TASTE_GOTO"] ?? "0.31")
        let t0 = Date()
        _ = el("reader.pageNumber").waitForExistence(timeout: 240)
        note("first number seen by test after \(String(format: "%.1f", Date().timeIntervalSince(t0)))s; app numberDelay=\(delay()) total=\((el("reader.pageCount").value as? String) ?? "-")")
        _ = settle(30)
        for t in 0..<10 {
            note("turn \(t): numbers=\(numbers()) len=\(visibleText.count)")
            if t < 3 { shot("t\(t)") }
            forward(1)
        }
        app.terminate()
    }

    /// Reopen chains with real turns between rounds.
    func testB_reopenChain() throws {
        tag0 = "chain"
        landscape()
        let spots = (env["TASTE_SPOTS"] ?? "0.31,0.12,0.47").split(separator: ",").map(String.init)
        let rounds = Int(env["TASTE_ROUNDS"] ?? "3")!
        let between = [1, 0, 2]
        var hits = 0, total = 0
        for (k, spot) in spots.enumerated() {
            openBook("gutenberg-pride-and-prejudice", at: spot)
            _ = settle(120)
            forward(2)
            for r in 0..<rounds {
                if r > 0 { forward(between[(r - 1) % between.count]) }
                let left = settle(60)
                let nL = numbers()
                shot("\(k)-\(r)-a-left")
                leave()
                launch([])
                let picture = el("reader.reopenPicture")
                let had = picture.waitForExistence(timeout: 10)
                var lifted = "-"
                if had {
                    let t0 = Date(); let d = Date().addingTimeInterval(40)
                    while Date() < d && picture.exists { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
                    shot("\(k)-\(r)-b2-lifted")
                    lifted = String(format: "%.1f", Date().timeIntervalSince(t0))
                }
                let nLift = numbers()
                let back = settle(120)
                let nR = numbers()
                shot("\(k)-\(r)-c-reopened")
                let ok = !left.isEmpty && back.hasPrefix(String(left.prefix(40)))
                total += 1; if ok { hits += 1 }
                note("spot \(spot) round \(r): numbers left=\(nL) atLift=\(nLift) reopened=\(nR) delay=\(delay()) picture=\(had) liftedAfter=\(lifted)s samePageStart=\(ok) identical=\(back == left)")
            }
            app.terminate()
            sleep(2)
        }
        note("TOTAL \(hits) of \(total)")
    }

    private func setPageNumbers(on: Bool) -> String {
        el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); sleep(2)
        app.buttons["reader.appearance"].tap()
        let fine = fineTune.firstMatch
        XCTAssertTrue(fine.waitForExistence(timeout: 10)); fine.tap(); sleep(2)
        let t = app.switches["appearance.pageNumbers"].firstMatch
        for _ in 0..<4 where t.exists && !t.isHittable { el("appearance.panel").swipeUp() }
        let before = (t.value as? String) ?? "-"
        for _ in 0..<3 where ((t.value as? String) == "1") != on {
            for _ in 0..<4 where !t.isHittable { el("appearance.panel").swipeUp(); sleep(1) }
            t.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap(); sleep(2)
        }
        let useDefault = el("appearance.useAsDefault")
        let label = useDefault.exists ? useDefault.label : "-"
        shot("finetune-\(on ? "on" : "off")")
        return "toggle was=\(before) now=\((t.value as? String) ?? "-") defaultButton=[\(label)]"
    }

    /// Numbers on in one book means on in another, and words never move.
    func testC_global() throws {
        tag0 = "global"
        landscape()
        openBook("gutenberg-pride-and-prejudice", at: "0.31")
        let a0 = settle(60)
        note("book A default: numbers=\(numbers())")
        shot("a-default")
        note("book A: \(setPageNumbers(on: true))")
        sleep(3)
        let a1 = visibleText
        note("book A after on: identical=\(a0 == a1) numbers=\(numbers())")
        app.terminate()
        openBook("gutenberg-alice-in-wonderland", at: "0.4", reset: false)
        _ = settle(60)
        _ = el("reader.pageNumber").waitForExistence(timeout: 120)
        note("book B opened: numbers=\(numbers()) delay=\(delay())")
        shot("b-opened")
        app.terminate()
        openBook("gutenberg-alice-in-wonderland", at: "0.4", reset: false)
        let b0 = settle(60)
        note("book B: \(setPageNumbers(on: false))")
        sleep(2)
        note("book B after off: identical=\(b0 == visibleText) numbers=\(numbers())")
        app.terminate()
        openBook("gutenberg-pride-and-prejudice", at: "0.31", reset: false)
        _ = settle(60)
        sleep(5)
        note("book A after off in B: numbers=\(numbers())")
        shot("a-after-off-in-b")
        app.terminate()
    }

    /// Still frames through spread landings.
    func testD_burst() throws {
        tag0 = "burst"
        landscape()
        openBook("gutenberg-pride-and-prejudice", at: "0.3")
        _ = settle(60)
        let page = el("reader.page")
        guard let dir = env["TASTE_SHOTS"] else { return }
        let plan: [(Bool, Int)] = [(true, 0), (true, 0), (true, 0), (true, 0), (false, 0), (false, 0), (true, 1), (true, 1), (false, 1)]
        for (k, step) in plan.enumerated() {
            page.coordinate(withNormalizedOffset: CGVector(dx: step.0 ? 0.93 : 0.07, dy: 0.5)).tap()
            let t0 = Date()
            for f in 0..<14 {
                let png = XCUIScreen.main.screenshot().pngRepresentation
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(String(format: "burst-%02d-%@-%02d-%.2f.png", k, step.0 ? "fwd" : "back", f, Date().timeIntervalSince(t0))))
            }
            sleep(step.1 == 1 ? 0 : 2)
        }
        app.terminate()
    }

    /// One tap per trial, never retried: does a single tap on the Page Numbers switch always land?
    func testE_singleTap() throws {
        tag0 = "singletap"
        landscape()
        openBook("gutenberg-pride-and-prejudice", at: "0.31")
        let book = app.descendants(matching: .any)
        _ = book
        sleep(2)
        el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); sleep(1)
        el("reader.appearance").tap()
        XCTAssertTrue(fineTune.waitForExistence(timeout: 10))
        fineTune.tap()
        let t = app.switches["appearance.pageNumbers"]
        XCTAssertTrue(t.waitForExistence(timeout: 10))
        note("panel scrollViews=\(el("appearance.panel").scrollViews.count) panel=\(el("appearance.panel").frame) switch=\(t.frame) hittable=\(t.isHittable) delay=\(delay())")
        shot("panel")
        var trials = 0, misses = 0
        func trial(_ name: String, expectChange: Bool = true, _ act: () -> Void) {
            let v0 = (t.value as? String) ?? "?"
            let f0 = t.frame, h0 = t.isHittable
            act()
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            let v1 = (t.value as? String) ?? "?"
            let changed = v0 != v1
            if expectChange { trials += 1; if !changed { misses += 1; shot("miss-\(trials)") } }
            note("\(name): \(v0)->\(v1) changed=\(changed) frame=\(f0) hittable=\(h0) now=\(t.frame) delay=\(delay()) nums=\(numbers())")
        }
        func at(_ dx: CGFloat, _ dy: CGFloat) -> XCUICoordinate { t.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy)) }
        for k in 0..<4 { trial("centre-\(k)") { at(0.5, 0.5).tap() } }
        for k in 0..<2 { trial("right-\(k)") { at(0.9, 0.5).tap() } }
        for k in 0..<2 { trial("left-\(k)") { at(0.1, 0.5).tap() } }
        for k in 0..<2 { trial("top-edge-\(k)") { at(0.5, 0.05).tap() } }
        trial("row-gap", expectChange: false) {
            let label = app.staticTexts["Page Numbers"]
            let mid = (label.frame.maxX + t.frame.minX) / 2
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: mid, dy: t.frame.midY)).tap()
        }
        trial("title", expectChange: false) { app.staticTexts["Page Numbers"].tap() }
        for k in 0..<2 {
            trial("after-spacing-\(k)") {
                app.buttons[k == 0 ? "Airy" : "Easy"].tap()
                at(0.5, 0.5).tap()
            }
        }
        for k in 0..<3 {
            trial("reopen-finetune-\(k)") {
                el("appearance.back").tap()
                fineTune.tap()
                at(0.5, 0.5).tap()
            }
        }
        for k in 0..<2 { trial("double-quick-\(k)", expectChange: false) { at(0.5, 0.5).tap(); at(0.5, 0.5).tap() } }
        note("SUMMARY trials=\(trials) misses=\(misses)")
        shot("end")
    }

    /// Thirty single taps on the switch's centre, plus taps straight after a font change (a reflow).
    func testF_tapRate() throws {
        tag0 = "taprate"
        landscape()
        openBook("gutenberg-pride-and-prejudice", at: "0.31")
        sleep(3)
        for _ in 0..<5 where !el("reader.appearance").isHittable {
            el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); sleep(2)
        }
        el("reader.appearance").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(fineTune.waitForExistence(timeout: 10))
        fineTune.tap()
        let t = app.switches[env["TASTE_SWITCH"] ?? "appearance.pageNumbers"]
        XCTAssertTrue(t.waitForExistence(timeout: 10)); sleep(2)
        shot("start"); note("start win=\(app.windows.firstMatch.frame) scrollViews=\(el("appearance.panel").scrollViews.count) switch=\(t.frame) hittable=\(t.isHittable) delay=\(delay()) fonts=\(app.buttons.matching(NSPredicate(format: "label IN %@", ["Georgia", "Original"])).count)")
        var trials = 0, misses = 0
        func one(_ name: String, _ pre: (() -> Void)? = nil) {
            let v0 = (t.value as? String) ?? "?"
            let t0 = Date()
            pre?()
            if env["TASTE_TAPX"] == "knob" { t.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: t.frame.width - 36, dy: 0)).tap() }
            else { t.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
            let tapped = Date().timeIntervalSince(t0)
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            let v1 = (t.value as? String) ?? "?"
            trials += 1
            if v0 == v1 { misses += 1; shot("miss-\(trials)") }
            note("\(name) #\(trials): \(v0)->\(v1) \(v0 == v1 ? "MISS" : "ok") tapTook=\(String(format: "%.1f", tapped))s frame=\(t.frame) hittable=\(t.isHittable)")
        }
        for k in 0..<(Int(env["TASTE_COUNT"] ?? "30") ?? 30) { one("centre-\(k)") }
        for k in 0..<6 { one("after-font-\(k)") { self.app.buttons[k % 2 == 0 ? "Georgia" : "Original"].tap() } }
        note("SUMMARY trials=\(trials) misses=\(misses)")
    }

    /// Control: the same single-tap loop on a system Settings switch, on the same simulator.
    func testG_settingsControl() throws {
        tag0 = "settingscontrol"
        let set = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        set.launch()
        sleep(3)
        set.staticTexts["General"].firstMatch.tap(); sleep(2)
        set.staticTexts["Keyboard"].firstMatch.tap(); sleep(3)
        XCTAssertTrue(set.switches.firstMatch.waitForExistence(timeout: 10))
        let all = set.switches.allElementsBoundByIndex
        note("switches: " + all.map { "\($0.label)|\($0.value ?? "-")|\($0.frame.width)" }.joined(separator: "; "))
        let t = all.first { ($0.label == "Auto-Capitalization" || $0.label == "Auto-Correction") } ?? all.last!
        note("control switch=\(t.label) frame=\(t.frame) hittable=\(t.isHittable)")
        var trials = 0, misses = 0
        for k in 0..<30 {
            let v0 = (t.value as? String) ?? "?"
            t.coordinate(withNormalizedOffset: CGVector(dx: 0.0, dy: 0.5)).withOffset(CGVector(dx: t.frame.width - 36, dy: 0)).tap()
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            let v1 = (t.value as? String) ?? "?"
            trials += 1
            if v0 == v1 { misses += 1 }
            note("centre-\(k) #\(trials): \(v0)->\(v1) \(v0 == v1 ? "MISS" : "ok")")
        }
        note("SUMMARY trials=\(trials) misses=\(misses) final=\((t.value as? String) ?? "?")")
    }

    private func openFineTune() -> XCUIElement {
        for _ in 0..<5 where !el("reader.appearance").isHittable {
            el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); sleep(2)
        }
        el("reader.appearance").tap()
        XCTAssertTrue(fineTune.waitForExistence(timeout: 10))
        fineTune.tap()
        let t = app.switches["appearance.pageNumbers"]
        XCTAssertTrue(t.waitForExistence(timeout: 10)); sleep(2)
        return t
    }

    /// How the row-as-button feels: title taps, knob taps, a knob drag, a zero-length press.
    func testH_rowFeel() throws {
        tag0 = "rowfeel"
        landscape()
        openBook("gutenberg-pride-and-prejudice", at: "0.31")
        sleep(3)
        let t = openFineTune()
        note("row switch frame=\(t.frame) hittable=\(t.isHittable)")
        shot("panel")
        func v() -> String { (t.value as? String) ?? "?" }
        func kind(_ name: String, _ n: Int, _ act: () -> Void) {
            var flips = 0
            for _ in 0..<n {
                let v0 = v(); act(); RunLoop.current.run(until: Date().addingTimeInterval(1.0))
                if v() != v0 { flips += 1 }
            }
            note("\(name): \(flips) of \(n) flipped exactly-once-check value=\(v())")
        }
        kind("title-tap", 10) { t.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap() }
        kind("row-gap-tap", 6) { t.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)).tap() }
        let knob = { t.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: t.frame.width - 36, dy: 0)) }
        kind("knob-tap", 10) { knob().tap() }
        kind("zero-press", 10) { knob().press(forDuration: 0) }
        kind("knob-drag-30pt", 6) { let k = knob(); k.press(forDuration: 0.1, thenDragTo: k.withOffset(CGVector(dx: (((t.value as? String) == "1") ? -30 : 30), dy: 0))) }
        kind("drag-off-row", 4) { let k = knob(); k.press(forDuration: 0.1, thenDragTo: k.withOffset(CGVector(dx: 0, dy: -120))) }
        kind("double-tap", 4) { knob().doubleTap() }
        shot("end")
    }

    /// Fresh open with numbers on: the placeholder's life, and whether the words move.
    func testI_placeholder() throws {
        tag0 = "placeholder"
        landscape()
        launch(["-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES", "-GatefoldNoLatency", "YES", "-GatefoldOpenBook", env["TASTE_BOOK"] ?? "gutenberg-pride-and-prejudice", "-GatefoldGoTo", env["TASTE_GOTO"] ?? "0.47", "-GatefoldPageFurniture", "YES"])
        XCTAssertTrue(el("reader.page").waitForExistence(timeout: 300))
        let t0 = Date()
        var firstText = "", sawCounting: Double = -1, sawNumber: Double = -1, moved = 0, blank = 0, samples = 0, shotC = false
        while Date().timeIntervalSince(t0) < (Double(env["TASTE_WINDOW"] ?? "90") ?? 90) {
            let now = Date().timeIntervalSince(t0)
            let txt = visibleText
            let counting = el("reader.pageCounting").exists
            let nums = numbers()
            samples += 1
            if firstText.isEmpty && !txt.isEmpty { firstText = txt }
            else if !txt.isEmpty && txt != firstText { moved += 1 }
            if counting && sawCounting < 0 { sawCounting = now }
            if samples % 5 == 0 { note("sample \(samples) t=\(String(format: "%.1f", now)) counting=\(counting) nums=\(nums) delay=\(delay())") }
            if counting && !shotC && now > 1.5 { shot("counting"); shotC = true }
            if !counting && nums.isEmpty && !txt.isEmpty { blank += 1 }
            if !nums.isEmpty && sawNumber < 0 { sawNumber = now; note("number \(nums) at \(String(format: "%.1f", now))s delay=\(delay())"); sleep(1); shot("number") }
            if sawNumber >= 0 && now - sawNumber > 4 { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        note("SUMMARY counting-first=\(String(format: "%.1f", sawCounting))s number=\(String(format: "%.1f", sawNumber))s samples=\(samples) blankSlot=\(blank) wordsMoved=\(moved) final-identical=\(visibleText == firstText) countingShown=\((el("reader.countingShown").value as? String) ?? "-")")
    }

    private func fit(_ e: XCUIElement) -> String {
        guard e.exists else { return "absent" }
        let w = app.windows.firstMatch.frame
        return w.insetBy(dx: -0.5, dy: -0.5).contains(e.frame) ? "INSIDE" : "OUTSIDE"
    }

    /// Plain fresh launch, no orientation set: chrome, the Your Page panel and Fine-Tune inside the window,
    /// then the same after a landscape turn and back. Then single taps on the Fine-Tune rows at their real,
    /// visible coordinates.
    func testJ_portraitPanel() throws {
        tag0 = "portraitpanel"
        note("device orientation at start=\(XCUIDevice.shared.orientation.rawValue)")
        openBook("gutenberg-pride-and-prejudice", at: env["TASTE_GOTO"] ?? "0.31")
        sleep(5)
        var outside = 0
        func look(_ n: String) {
            for _ in 0..<5 where !el("reader.appearance").exists {
                el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); sleep(2)
            }
            let win = app.windows.firstMatch.frame
            for id in ["reader.close", "reader.bookmark", "reader.contents", "reader.share", "reader.search", "reader.appearance"] where el(id).exists {
                let f = fit(el(id)); if f == "OUTSIDE" { outside += 1 }
                note("\(n) \(id) \(el(id).frame) \(f) win=\(win)")
            }
            el("reader.appearance").tap(); sleep(2)
            let p = el("appearance.panel")
            let f1 = fit(p); if f1 == "OUTSIDE" { outside += 1 }
            note("\(n) panel \(p.frame) \(f1)")
            shot("\(n)-panel")
            if !fineTune.isHittable { p.swipeUp() }
            fineTune.tap(); sleep(2)
            let f2 = fit(p); if f2 == "OUTSIDE" { outside += 1 }
            let sw = app.switches["appearance.pageNumbers"]
            let f3 = fit(sw); if f3 == "OUTSIDE" { outside += 1 }
            note("\(n) finetune \(p.frame) \(f2) row=\(sw.frame) \(f3) orient=\(XCUIDevice.shared.orientation.rawValue)")
            shot("\(n)-finetune")
        }
        look("a-fresh")
        // taps on rows, at the visible point, in portrait
        let sw = app.switches["appearance.pageNumbers"]
        var trials = 0, misses = 0
        for k in 0..<(Int(env["TASTE_COUNT"] ?? "20") ?? 20) {
            let v0 = (sw.value as? String) ?? "?"
            let at = k % 2 == 0 ? CGVector(dx: 0.5, dy: 0.5) : CGVector(dx: 0.15, dy: 0.5)
            sw.coordinate(withNormalizedOffset: at).tap()
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            let v1 = (sw.value as? String) ?? "?"
            trials += 1; if v0 == v1 { misses += 1; shot("miss-\(trials)") }
            note("row-tap #\(trials) \(v0)->\(v1) \(v0 == v1 ? "MISS" : "ok") at=\(sw.frame)")
        }
        note("ROWTAPS trials=\(trials) misses=\(misses)")
        // dismiss panel by tapping page area above it
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap(); sleep(2)
        note("panel after dismiss tap exists=\(el("appearance.panel").exists)")
        XCUIDevice.shared.orientation = .landscapeLeft; sleep(5)
        if el("appearance.panel").exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap(); sleep(2) }
        look("b-landscape")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap(); sleep(2)
        XCUIDevice.shared.orientation = .portrait; sleep(5)
        if el("appearance.panel").exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap(); sleep(2) }
        look("c-back-portrait")
        note("SUMMARY outside=\(outside)")
    }

    /// Contents jumps with natural loading: sample the veil, Readium's spinner and the words through each jump.
    func testK_contentsJump() throws {
        tag0 = "contents"
        landscape()
        openBook("gutenberg-pride-and-prejudice", at: "0.05")
        var before = settle(30)
        let chapters = (env["TASTE_CHAPTERS"] ?? "Chapter XXX,Chapter XLV,Chapter X,Chapter LX,Chapter III").split(separator: ",").map(String.init)
        var bareTotal = 0, spinTotal = 0, emptyTotal = 0, landed = 0
        for (k, ch) in chapters.enumerated() {
            for _ in 0..<5 where !app.buttons["reader.contents"].exists {
                el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); sleep(2)
            }
            app.buttons["reader.contents"].tap()
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Chapter I")).firstMatch.waitForExistence(timeout: 10))
            let row = app.buttons.matching(NSPredicate(format: "label ENDSWITH[c] %@ OR label BEGINSWITH[c] %@", ch, ch + ",")).firstMatch
            let anyRow = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", ch + " ")).firstMatch
            var target = row
            for _ in 0..<25 where !(row.exists && row.isHittable) && !(anyRow.exists && anyRow.isHittable) { app.swipeUp(velocity: .slow) }
            if !(row.exists && row.isHittable) { target = anyRow }
            for _ in 0..<25 where !(target.exists && target.isHittable) { app.swipeDown(velocity: .slow) }
            guard target.exists && target.isHittable else { note("jump \(k) \(ch): row not found"); app.swipeDown(); continue }
            note("jump \(k) to row labelled-hash=\(target.label.hashValue)")
            target.tap()
            let t0 = Date()
            var samples = 0, bare = 0, spin = 0, empty = 0, veilUp = 0, frames = 0
            var arrived: Double = -1
            while Date().timeIntervalSince(t0) < 8 {
                samples += 1
                let veil = el("reader.veil").exists
                let spinning = app.activityIndicators.count > 0
                let txt = visibleText
                if veil { veilUp += 1 }
                if spinning { spin += 1 }
                if txt.isEmpty { empty += 1 }
                if !veil && (spinning || txt.isEmpty) { bare += 1; shot("jump\(k)-bare-\(bare)") }
                if arrived < 0 && !txt.isEmpty && txt != before && !veil { arrived = Date().timeIntervalSince(t0) }
                if frames < 4 { shot("jump\(k)-f\(frames)"); frames += 1 }
                RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            }
            let after = settle(20)
            if after != before && !after.isEmpty { landed += 1 }
            bareTotal += bare; spinTotal += spin; emptyTotal += empty
            note("jump \(k): samples=\(samples) veilUp=\(veilUp) spinner=\(spin) emptyText=\(empty) bareWhileLoading=\(bare) wordsArrived=\(String(format: "%.2f", arrived))s moved=\(after != before)")
            shot("jump\(k)-landed")
            before = after
        }
        note("SUMMARY jumps=\(chapters.count) landed=\(landed) bare=\(bareTotal) spinnerSamples=\(spinTotal) emptySamples=\(emptyTotal)")
    }

    // MARK: Spazz and place-loss repro (real gestures, opened from the shelf, no GoTo)

    private func fnv(_ s: String) -> String {
        var h: UInt32 = 2166136261
        for b in s.utf8 { h ^= UInt32(b); h = h &* 16777619 }
        return String(format: "%08x", h)
    }
    private func opening(_ t: String) -> String { t.split(whereSeparator: \.isWhitespace).prefix(12).joined(separator: " ") }
    private func place() -> String { let o = opening(visibleText); return o.isEmpty ? "EMPTY" : fnv(o) }
    private func quiet(_ timeout: TimeInterval = 15, still: TimeInterval = 2.5) {
        let deadline = Date().addingTimeInterval(timeout)
        var last = visibleText; var since = Date()
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            let t = visibleText
            if t != last { last = t; since = Date() }
            if !t.isEmpty && Date().timeIntervalSince(since) > still { break }
        }
    }
    private var unexpected = 0, steps = 0, missedTurns = 0, doubleTurns = 0
    private var history: [String] = []
    /// expect: 0 no move, 1 one move forward/back (any), -1 unknown (log only)
    private func step(_ name: String, expect: Int, _ act: () -> Void) {
        let p0 = place(); let t0 = visibleText; let s0 = shown(); let chrome0 = el("reader.contents").exists
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
        note("BEGIN \(name) wall=\(f.string(from: Date())) place=\(p0)")
        act()
        quiet()
        let p1 = place(); steps += 1
        let moved = p0 != p1
        var verdict = "ok"
        if expect == 0 && moved { unexpected += 1; verdict = "UNEXPECTED-MOVE"; shot("unexpected-\(steps)") }
        if expect == 1 && !moved { missedTurns += 1; verdict = "NO-TURN" }
        if expect == 1 && moved && history.suffix(3).contains(p1) == false && history.count > 2 { /* fine */ }
        history.append(p1)
        note("END \(name) wall=\(f.string(from: Date())) place \(p0)->\(p1) moved=\(moved) expect=\(expect) \(verdict) hisWordsOnScreen=\(holds(t0)) shown \(s0)->\(shown()) chrome \(chrome0)->\(el("reader.contents").exists) nums=\(numbers())")
    }
    /// Taps the page only when the page itself takes the tap: with a sheet still up, a centre tap lands on
    /// whatever row is there (gatefold#305: three Contents "jumps" were this tap).
    private func hideChrome() {
        if el("reader.contents").exists, el("reader.page").isHittable { el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); sleep(1) }
    }
    /// Closes Contents with its own Done button if the swipe left it up (gatefold#305), and waits until the page is back.
    /// Build 47: #539 replaced Contents' navigation bar (and its Done) with `contents.header` and `contents.close`,
    /// so build 46's Done never matched and Contents stayed up; its close button is tried first now.
    private func closeContentsIfUp() {
        let close = app.buttons["contents.close"].firstMatch
        let done = app.navigationBars.buttons["Done"]
        if close.exists {
            note("contents still up after the gesture; closed with its close button")
            close.tap()
        } else if !el("reader.page").isHittable, done.exists {
            note("contents still up after the swipe; closed with Done")
            done.tap()
        }
        for _ in 0..<10 where !el("reader.page").isHittable { sleep(1) }
    }
    private func at(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate { app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)) }

    private var foldN = 0
    /// Asks the host watcher to press a DeviceHub posture ("Open", "Closed", "Partially Open") and waits for its ack.
    private func posture(_ name: String) {
        guard let dir = env["TASTE_SHOTS"] else { return }
        foldN += 1
        let req = "\(dir)/req-\(foldN)"
        try? name.write(toFile: req, atomically: true, encoding: .utf8)
        let ack = "\(dir)/ack-\(foldN)"
        let up = Date().addingTimeInterval(40)
        while Date() < up && !FileManager.default.fileExists(atPath: ack) { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        note("posture \(name) #\(foldN) acked=\(FileManager.default.fileExists(atPath: ack))")
    }
    /// Asks the host watcher for a screenshot of every display (the Duo's cover and inner screens); a no-op without one.
    private func hubShot(_ n: String) { if env["TASTE_HUB"] != nil { posture("SHOT:\(tag0)-\(n)") } }

    func testS_spazz() throws {
        tag0 = "spazz"
        if env["TASTE_LANDSCAPE"] != nil { XCUIDevice.shared.orientation = .landscapeLeft; sleep(2) }
        launch(["-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES"])
        let cover = el("book.gutenberg-pride-and-prejudice")
        XCTAssertTrue(cover.waitForExistence(timeout: 120), "shelf")
        sleep(3)
        shot("shelf"); hubShot("shelf")
        for _ in 0..<8 where !cover.isHittable { el("library.grid").swipeUp(); sleep(1) }
        cover.tap()
        XCTAssertTrue(el("reader.page").waitForExistence(timeout: 120))
        quiet(60)
        note("opened from shelf place=\(place()) win=\(app.windows.firstMatch.frame) orient=\(XCUIDevice.shared.orientation.rawValue)")
        at(0.5, 0.5).tap(); sleep(2)
        for id in ["reader.close", "reader.contents", "reader.appearance"] where el(id).exists { note("FIT \(id) \(el(id).frame) \(fit(el(id)))") }
        if el("reader.appearance").exists {
            el("reader.appearance").tap(); sleep(2)
            note("FIT panel \(el("appearance.panel").frame) \(fit(el("appearance.panel")))")
            if fineTune.exists { fineTune.tap(); sleep(2); note("FIT finetune \(el("appearance.panel").frame) \(fit(el("appearance.panel")))"); shot("fit-finetune") }
            at(0.5, 0.1).tap(); sleep(2)
            note("panel up after a tap above it: \(el("appearance.panel").exists)")
            if el("appearance.panel").exists { at(0.5, 0.1).tap(); sleep(2); note("after a 2nd tap: \(el("appearance.panel").exists)") }
            if el("appearance.panel").exists { at(0.5, 0.05).press(forDuration: 0.05, thenDragTo: at(0.5, 0.05)); app.swipeDown(); sleep(2); note("after swipe down: \(el("appearance.panel").exists)") }
        }
        hideChrome(); quiet()
        note("start place=\(place())")
        let rounds = Int(env["TASTE_ROUNDS"] ?? "2") ?? 2
        for r in 0..<rounds {
            note("ROUND \(r)")
            for k in 0..<4 { step("swipe-left-\(k)", expect: 1) { at(0.75, 0.5).press(forDuration: 0.05, thenDragTo: at(0.25, 0.5)) } }
            step("swipe-right", expect: 1) { at(0.25, 0.5).press(forDuration: 0.05, thenDragTo: at(0.75, 0.5)) }
            // stray taps across zones (each followed by a chrome hide)
            for (x, y) in [(0.5, 0.5), (0.5, 0.04), (0.5, 0.96), (0.3, 0.5), (0.7, 0.5), (0.3, 0.1), (0.7, 0.9), (0.5, 0.25), (0.5, 0.75)] as [(CGFloat, CGFloat)] {
                step("stray-tap-\(x),\(y)", expect: 0) { at(x, y).tap(); sleep(1); hideChrome() }
            }
            for (x, y) in [(0.2, 0.5), (0.8, 0.5), (0.03, 0.5), (0.97, 0.5), (0.9, 0.05), (0.9, 0.95)] as [(CGFloat, CGFloat)] {
                step("edge-zone-tap-\(x),\(y)", expect: 1) { at(x, y).tap() }
            }
            // taps while the page is still settling
            step("turn-then-centre-tap", expect: 1) { at(0.9, 0.5).tap(); at(0.5, 0.5).tap(); sleep(1); hideChrome() }
            step("swipe-then-centre-tap", expect: 1) { at(0.75, 0.5).press(forDuration: 0.05, thenDragTo: at(0.25, 0.5)); at(0.5, 0.5).tap(); sleep(1); hideChrome() }
            step("turn-then-top-tap", expect: 1) { at(0.9, 0.5).tap(); at(0.5, 0.06).tap(); sleep(1); hideChrome() }
            step("double-turn-quick", expect: -1) { at(0.9, 0.5).tap(); at(0.9, 0.5).tap() }
            step("back-then-fwd-quick", expect: -1) { at(0.1, 0.5).tap(); at(0.9, 0.5).tap() }
            // non-horizontal swipes
            step("swipe-up", expect: 0) { at(0.5, 0.7).press(forDuration: 0.05, thenDragTo: at(0.5, 0.3)) }
            step("swipe-down", expect: 0) { at(0.5, 0.3).press(forDuration: 0.05, thenDragTo: at(0.5, 0.7)) }
            step("diagonal-swipe", expect: 0) { at(0.45, 0.3).press(forDuration: 0.05, thenDragTo: at(0.52, 0.7)) }
            step("short-horizontal-drag-20pt", expect: 0) { at(0.5, 0.5).press(forDuration: 0.05, thenDragTo: at(0.5, 0.5).withOffset(CGVector(dx: -20, dy: 0))) }
            step("slow-scroll-like-drag", expect: -1) { at(0.6, 0.4).press(forDuration: 0.4, thenDragTo: at(0.45, 0.55)) }
            // edge swipes
            step("edge-swipe-from-left", expect: -1) { at(0.002, 0.5).press(forDuration: 0.05, thenDragTo: at(0.5, 0.5)) }
            if !el("reader.page").exists { note("left edge swipe LEFT THE READER"); if cover.exists { cover.tap(); quiet(30) } }
            step("edge-swipe-from-right", expect: -1) { at(0.998, 0.5).press(forDuration: 0.05, thenDragTo: at(0.5, 0.5)) }
            step("edge-swipe-from-top", expect: 0) { at(0.5, 0.002).press(forDuration: 0.05, thenDragTo: at(0.5, 0.4)); sleep(1); hideChrome() }
            if !el("reader.page").isHittable { XCUIDevice.shared.press(.home); sleep(1); app.activate(); sleep(2) }
            // controls
            for k in 0..<3 { step("controls-show-hide-\(k)", expect: 0) { at(0.5, 0.5).tap(); sleep(1); at(0.5, 0.5).tap() } }
            step("contents-open-cancel", expect: 0) {
                at(0.5, 0.5).tap(); sleep(1)
                if app.buttons["reader.contents"].waitForExistence(timeout: 3) { app.buttons["reader.contents"].tap(); sleep(2) }
                at(0.5, 0.2).press(forDuration: 0.05, thenDragTo: at(0.5, 0.98)); sleep(2)
                closeContentsIfUp()
                hideChrome()
            }
            step("contents-open-scroll-cancel", expect: 0) {
                at(0.5, 0.5).tap(); sleep(1)
                if app.buttons["reader.contents"].waitForExistence(timeout: 3) { app.buttons["reader.contents"].tap(); sleep(2) }
                app.swipeUp(velocity: .fast); sleep(1)
                at(0.5, 0.2).press(forDuration: 0.05, thenDragTo: at(0.5, 0.98)); sleep(2)
                closeContentsIfUp()
                hideChrome()
            }
            step("yourpage-open-dismiss", expect: 0) {
                at(0.5, 0.5).tap(); sleep(1)
                if el("reader.appearance").waitForExistence(timeout: 3) { el("reader.appearance").tap(); sleep(2) }
                at(0.5, 0.1).tap(); sleep(2); hideChrome()
            }
            step("finetune-open-back-close", expect: 0) {
                at(0.5, 0.5).tap(); sleep(1)
                if el("reader.appearance").waitForExistence(timeout: 3) { el("reader.appearance").tap(); sleep(2) }
                if fineTune.waitForExistence(timeout: 3) { fineTune.tap(); sleep(2) }
                if el("appearance.back").exists { el("appearance.back").tap(); sleep(1) }
                at(0.5, 0.1).tap(); sleep(2); hideChrome()
            }
            step("finetune-toggle-justify-close", expect: 0) {
                at(0.5, 0.5).tap(); sleep(1)
                if el("reader.appearance").waitForExistence(timeout: 3) { el("reader.appearance").tap(); sleep(2) }
                if fineTune.waitForExistence(timeout: 3) { fineTune.tap(); sleep(2) }
                let sw = app.switches["appearance.pageNumbers"]
                if sw.exists { sw.tap(); sleep(2) }
                at(0.5, 0.1).tap(); sleep(2); hideChrome()
            }
            // Build 46's step above flips Page Numbers (its name says Justify); this one flips Justify itself.
            step("finetune-justify-switch-close", expect: 0) {
                at(0.5, 0.5).tap(); sleep(1)
                if el("reader.appearance").waitForExistence(timeout: 3) { el("reader.appearance").tap(); sleep(2) }
                if fineTune.waitForExistence(timeout: 3) { fineTune.tap(); sleep(2) }
                let j = app.switches["appearance.justify"].firstMatch
                for _ in 0..<4 where j.exists && !j.isHittable { el("appearance.panel").swipeUp(); sleep(1) }
                if j.exists { j.tap(); sleep(3) }
                at(0.5, 0.1).tap(); sleep(2); hideChrome()
            }
            // rotation mid-turn (iPad)
            if UIDevice.current.userInterfaceIdiom == .pad {
                let land = XCUIDevice.shared.orientation.isLandscape
                step("rotate-mid-turn", expect: 1) { at(0.9, 0.5).tap(); XCUIDevice.shared.orientation = land ? .portrait : .landscapeLeft; sleep(3) }
                step("rotate-back-no-turn", expect: 0) { XCUIDevice.shared.orientation = land ? .landscapeLeft : .portrait; sleep(3) }
                step("rotate-twice-no-turn", expect: 0) { XCUIDevice.shared.orientation = land ? .portrait : .landscapeLeft; sleep(3); XCUIDevice.shared.orientation = land ? .landscapeLeft : .portrait; sleep(3) }
            }
            if env["TASTE_FOLD"] != nil {
                step("unfold-no-turn", expect: 0) { posture("Open"); sleep(6) }
                step("fold-no-turn", expect: 0) { posture("Closed"); sleep(6) }
                step("unfold-mid-turn", expect: 1) { at(0.9, 0.5).tap(); posture("Open"); sleep(6) }
                step("stray-tap-centre-open", expect: 0) { at(0.5, 0.5).tap(); sleep(1); hideChrome() }
                step("half-open-no-turn", expect: 0) { posture("Partially Open"); sleep(6) }
                step("flat-again-no-turn", expect: 0) { posture("Open"); sleep(6) }
                step("fold-mid-turn", expect: 1) { at(0.9, 0.5).tap(); posture("Closed"); sleep(6) }
                step("fold-unfold-quick", expect: 0) { posture("Open"); sleep(1); posture("Closed"); sleep(6) }
            }
            // leave and come back
            step("home-and-back", expect: 0) { XCUIDevice.shared.press(.home); sleep(3); app.activate(); sleep(2) }
            step("home-long-and-back", expect: 0) { XCUIDevice.shared.press(.home); sleep(12); app.activate(); sleep(2) }
            for k in 0..<3 { step("several-turns-\(k)", expect: 1) { at(0.9, 0.5).tap() } }
            step("reopen-after-terminate", expect: 0) {
                XCUIDevice.shared.press(.home); sleep(3); app.terminate(); sleep(1)
                launch([]); _ = el("reader.page").waitForExistence(timeout: 60); quiet(30)
            }
            step("reopen-again-no-turn", expect: 0) {
                XCUIDevice.shared.press(.home); sleep(3); app.terminate(); sleep(1)
                launch([]); _ = el("reader.page").waitForExistence(timeout: 60); quiet(30)
            }
            step("touch-during-reopen", expect: -1) {
                XCUIDevice.shared.press(.home); sleep(3); app.terminate(); sleep(1)
                launch([]); sleep(1); at(0.5, 0.5).tap(); _ = el("reader.page").waitForExistence(timeout: 60); quiet(30); hideChrome()
            }
        }
        note("SUMMARY steps=\(steps) unexpectedMoves=\(unexpected) missedTurns=\(missedTurns)")
    }

    // MARK: Build 25 additions: catch-up and sync, looks, Duo poses

    /// The InkPad reads ahead while the page is open: the offer, the tab it folds into, and Catch up.
    func testL_catchUp() throws {
        tag0 = "catchup"
        landscape()
        launch(["-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES", "-GatefoldNoLatency", "YES", "-GatefoldOpenBook", "gutenberg-pride-and-prejudice",
                "-GatefoldGoTo", "0.31", "-GatefoldRemoteAheadAfter", "12", "-GatefoldRemoteAheadTo", "0.6"])
        XCTAssertTrue(el("reader.page").waitForExistence(timeout: 300))
        _ = settle(30)
        let p0 = place(); note("open place=\(p0) nums=\(numbers())"); shot("a-open"); hubShot("a-open")
        let banner = el("banner")
        let t0 = Date()
        let had = banner.waitForExistence(timeout: 90)
        note("banner up=\(had) after \(String(format: "%.1f", Date().timeIntervalSince(t0)))s place=\(place()) samePlace=\(place() == p0)")
        sleep(1); shot("b-offer"); hubShot("b-offer")
        forward(1)
        let tab = el("banner.tab")
        let tabUp = tab.waitForExistence(timeout: 20)
        let p1 = place()
        note("after a turn: tab=\(tabUp) banner=\(banner.exists) place=\(p1)"); shot("c-tab"); hubShot("c-tab")
        if tabUp && !el("banner.jump").exists { tab.tap(); sleep(2); note("tab tapped: banner=\(banner.exists) jump=\(el("banner.jump").exists)"); shot("d-tab-tapped") }
        let jump = el("banner.jump")
        if jump.waitForExistence(timeout: 10) {
            jump.tap()
            for k in 0..<6 { RunLoop.current.run(until: Date().addingTimeInterval(0.4)); shot("e-catching-\(k)") }
            _ = settle(40)
            let p2 = place()
            note("caught up: place \(p1)->\(p2) moved=\(p1 != p2) nums=\(numbers()) backPill=\(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Back to page'")).firstMatch.exists)")
            shot("f-caught-up"); hubShot("f-caught-up")
        } else { note("no Catch up button") }
        note("SUMMARY offer=\(had) tab=\(tabUp)")
    }

    /// Typography and appearance: every theme on one page, the shelf, Contents, Your Page and Fine-Tune, in this orientation.
    func testM_looks() throws {
        tag0 = env["TASTE_LANDSCAPE"] != nil ? "looks-land" : "looks"
        landscape()
        launch(["-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES", "-GatefoldNoLatency", "YES"])
        _ = el("library.grid").waitForExistence(timeout: 120); sleep(6)
        shot("shelf"); hubShot("shelf")
        app.terminate()
        for (k, theme) in ["daylight", "vellum", "fog", "sage", "dusk", "midnight"].enumerated() {
            launch(["-GatefoldDownloadAll", "YES", "-GatefoldNoLatency", "YES", "-GatefoldOpenBook", "gutenberg-pride-and-prejudice", "-GatefoldGoTo", "0.31", "-GatefoldTheme", theme])
            XCTAssertTrue(el("reader.page").waitForExistence(timeout: 300))
            _ = settle(30); sleep(2)
            note("theme \(theme) place=\(place()) nums=\(numbers())")
            shot("theme-\(k)-\(theme)"); hubShot("theme-\(k)-\(theme)")
            if k == 0 {
                at(0.5, 0.5).tap(); sleep(2); shot("chrome"); hubShot("chrome")
                if el("reader.contents").exists { el("reader.contents").tap(); sleep(3); shot("contents"); hubShot("contents"); app.swipeDown(velocity: .fast); sleep(2) }
                if !el("reader.appearance").exists { at(0.5, 0.5).tap(); sleep(2) }
                if el("reader.appearance").exists {
                    el("reader.appearance").tap(); sleep(2); shot("yourpage"); hubShot("yourpage")
                    if fineTune.waitForExistence(timeout: 5) { fineTune.tap(); sleep(2); shot("finetune"); hubShot("finetune") }
                }
            }
            app.terminate()
        }
    }

    /// The Duo's hinge with a book open: shut, flat, half open and back, the place hash at each, every display shot.
    func testN_duoPoses() throws {
        tag0 = "poses"
        guard env["TASTE_HUB"] != nil else { throw XCTSkip("needs the host's hinge watcher") }
        posture("Closed"); sleep(4)
        launch(["-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES", "-GatefoldNoLatency", "YES", "-GatefoldOpenBook", "gutenberg-pride-and-prejudice", "-GatefoldGoTo", "0.31"])
        XCTAssertTrue(el("reader.page").waitForExistence(timeout: 300))
        quiet(60)
        forward(2)
        let his = place()
        note("closed place=\(his) nums=\(numbers())"); hubShot("1-closed")
        func pose(_ n: String, _ hub: [String], wait: UInt32 = 8) {
            for h in hub { posture(h); sleep(3) }
            sleep(wait); quiet(30)
            let p = place()
            note("POSE \(n) place=\(p) same=\(p == his) win=\(app.windows.firstMatch.frame) nums=\(numbers())")
            hubShot(n)
        }
        pose("2-open", ["Open"])
        pose("3-closed-again", ["Closed"])
        pose("4-open-again", ["Open"])
        pose("5-half-open", ["Rotate Right", "Partially Open"])
        pose("6-flat", ["Open"])
        pose("7-flat-upright", ["Rotate Right", "Rotate Right", "Rotate Right"])
        pose("8-closed", ["Closed"])
        // Reopen while folded, then unfold straight after the page shows.
        XCUIDevice.shared.press(.home); sleep(3); app.terminate(); sleep(1)
        launch([]); _ = el("reader.page").waitForExistence(timeout: 60)
        quiet(30)
        note("reopened folded place=\(place()) same=\(place() == his)"); hubShot("9-reopened-closed")
        pose("10-open-after-reopen", ["Open"], wait: 2)
        note("SUMMARY")
    }

    // MARK: Build 46 additions: rotation and fold at several places, then reopen (gatefold#482, #508)

    /// The reflow's own verdict ("anchor-visible n", "anchor-lost n", "settling n"); never its detail, which holds words.
    private func anchorCheck() -> String { let e = el("reader.anchorCheck"); return e.exists ? e.label : "-" }
    /// Whether the first words of a page read earlier are still on screen now, by comparison only (no words kept).
    private func holds(_ before: String) -> Bool { let o = opening(before); return !o.isEmpty && visibleText.contains(o) }
    private func orientName() -> String { XCUIDevice.shared.orientation.isLandscape ? "land" : "port" }
    private var anchorLost = 0, notHeld = 0
    /// Logs where he is after a layout change: the page's hash, whether his page's first words are on screen, the reflow's verdict.
    private func check(_ n: String, his: String) {
        quiet(30, still: 3)
        let held = holds(his); let a = anchorCheck()
        if !held { notHeld += 1 }
        if a.hasPrefix("anchor-lost") { anchorLost += 1 }
        note("CHECK \(n) orient=\(orientName()) place=\(place()) hisPlace=\(fnv(opening(his))) startsSame=\(opening(visibleText) == opening(his)) hisWordsOnScreen=\(held) anchorCheck=[\(a)] shown=\(shown()) nums=\(numbers()) win=\(app.windows.firstMatch.frame)")
        shot(n); hubShot(n)
    }
    private func rotate(_ o: UIDeviceOrientation, wait: UInt32 = 3) { XCUIDevice.shared.orientation = o; sleep(wait) }

    // MARK: Build 47 additions: hash checks after build 46's failure cases, clip marks, direction

    /// The page Readium last reported, as `file@progression` (`reader.shownPlace`): no words, for direction only.
    private func shown() -> String { (el("reader.shownPlace").value as? String) ?? "-" }
    /// Orders two `file@progression` places: the file's last number, then the progression. nil if either can't be read.
    private func order(_ s: String) -> (Int, Double)? {
        let parts = s.split(separator: "@")
        guard parts.count >= 2, let prog = Double(parts.last!) else { return nil }
        let file = parts.dropLast().joined(separator: "@")
        let n = file.split(whereSeparator: { !$0.isNumber }).last.flatMap { Int($0) } ?? -1
        return (n, prog)
    }
    private func direction(_ a: String, _ b: String) -> String {
        guard let x = order(a), let y = order(b) else { return "?" }
        if x == y { return "same" }
        return (y.0, y.1) > (x.0, x.1) ? "forward" : "backward"
    }
    private func wallNow() -> String { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f.string(from: Date()) }
    /// BEGIN and END lines with `CLIP`: the filing script cuts a 720-px clip of the recording between them.
    private func clipBegin(_ n: String) { note("BEGIN \(n) wall=\(wallNow()) place=\(place())") }
    private func clipEnd(_ n: String) { note("END \(n) wall=\(wallNow()) place=\(place()) CLIP") }
    private var hashHeld = 0, hashMoved = 0
    /// Build 46's hashing (FNV-1a of the page's first 12 words), against the page he should be on.
    /// mode `same`: the page now opens with his first 12 words (same layout as his page).
    /// mode `within`: his first 12 words are on screen (a layout with more on screen, as a spread from a page).
    private func hashCheck(_ n: String, expect his: String, mode: String) {
        let want = fnv(opening(his)), got = place(), on = holds(his)
        let ok = mode == "same" ? got == want : on
        if ok { hashHeld += 1 } else { hashMoved += 1 }
        note("HASHCHECK \(n) mode=\(mode) want=\(want) got=\(got) sameHash=\(got == want) hisWordsOnScreen=\(on) \(ok ? "HELD" : "MOVED") orient=\(orientName()) shown=\(shown()) anchorCheck=[\(anchorCheck())]")
    }
    private func back(_ n: Int) {
        let page = el("reader.page")
        for _ in 0..<n {
            let before = visibleText
            page.coordinate(withNormalizedOffset: CGVector(dx: 0.07, dy: 0.5)).tap()
            let d = Date().addingTimeInterval(20)
            while Date() < d && visibleText == before { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
            _ = settle(30)
        }
    }
    /// One page on and back, to learn the page a forward tap should land on. Returns that page's text (never logged).
    private func peekNext(_ n: String) -> String {
        let p = visibleText, ps = shown()
        forward(1); let next = visibleText; let ns = shown()
        back(1)
        note("PEEK \(n) from=\(fnv(opening(p))) next=\(fnv(opening(next))) backToSame=\(place() == fnv(opening(p))) shown \(ps) next \(ns) now \(shown())")
        return next
    }

    /// iPad: at several places, rotations (single, repeated, quick, mid-turn), then leave and reopen, also rotated while away.
    /// Steps 0 to 12 are build 46's, unchanged in their gestures; each of build 46's failure cases now has a HASHCHECK.
    /// T1 to T5 repeat the turn-then-rotate with his next page learnt first; 13 and 14 reopen the other way round.
    func testR_rotations() throws {
        tag0 = "rot"
        let spots = (env["TASTE_SPOTS"] ?? "0.12,0.31,0.47,0.73").split(separator: ",").map(String.init)
        for (k, spot) in spots.enumerated() {
            rotate(.portrait, wait: 2)
            openBook("gutenberg-pride-and-prejudice", at: spot)
            quiet(90, still: 4)
            forward(1)
            var his = visibleText
            note("SPOT \(spot) opened place=\(place()) shown=\(shown()) anchorCheck=[\(anchorCheck())]"); shot("\(k)-0-open")
            let opened = his
            // One turn of the device, then back.
            rotate(.landscapeLeft); check("\(k)-1-land", his: his)
            hashCheck("\(k)-1-land", expect: opened, mode: "within")
            rotate(.portrait); check("\(k)-2-port", his: his)
            hashCheck("\(k)-2-port", expect: opened, mode: "same")
            // Three round trips in a row.
            for r in 0..<3 { rotate(.landscapeLeft); rotate(.portrait) ; note("round trip \(r) done") }
            check("\(k)-3-after-3-round-trips", his: his)
            hashCheck("\(k)-3-after-3-round-trips", expect: opened, mode: "same")
            // Quick turns of the device, under a second apart, ending in landscape.
            clipBegin("\(k)-4-quick-rotations")
            for o in [UIDeviceOrientation.landscapeLeft, .portrait, .landscapeRight, .portrait, .landscapeLeft] { XCUIDevice.shared.orientation = o; usleep(600_000) }
            sleep(3); check("\(k)-4-quick-rotations-land", his: his)
            hashCheck("\(k)-4-quick-rotations-land", expect: opened, mode: "within")
            clipEnd("\(k)-4-quick-rotations")
            // He turns a page in landscape; that is his page now.
            forward(1); his = visibleText
            note("turned in landscape place=\(place()) shown=\(shown())")
            let landTurn = his
            rotate(.portrait); check("\(k)-5-port-after-land-turn", his: his)
            hashCheck("\(k)-5-port-after-land-turn", expect: landTurn, mode: "within")
            his = visibleText
            // A page turn with the device turned straight after it, before the turn has settled (build 46's rot-*-6, -7).
            let pre = place(), preShown = shown()
            clipBegin("\(k)-6-7-midturn")
            at(0.9, 0.5).tap(); XCUIDevice.shared.orientation = .landscapeLeft; sleep(4)
            quiet(30, still: 3)
            note("MIDTURN portrait->landscape from=\(pre) to=\(place()) moved=\(pre != place()) direction=\(direction(preShown, shown())) shown=\(shown()) anchorCheck=[\(anchorCheck())]"); shot("\(k)-6-midturn-land")
            his = visibleText
            rotate(.portrait); check("\(k)-7-port-after-midturn", his: his)
            clipEnd("\(k)-6-7-midturn")
            // Build 46's failure: back in portrait he should be one page on from `pre`, never on it or before it.
            note("TAPFROM \(k)-7 tappedFrom=\(pre) now=\(place()) onTappedFromPage=\(place() == pre) direction=\(direction(preShown, shown())) shown \(preShown)->\(shown())")
            his = visibleText
            let pre2 = place(), pre2Shown = shown()
            clipBegin("\(k)-8-midturn-twice")
            at(0.9, 0.5).tap(); XCUIDevice.shared.orientation = .landscapeLeft; usleep(300_000); XCUIDevice.shared.orientation = .portrait; sleep(4)
            quiet(30, still: 3)
            note("MIDTURN twice from=\(pre2) to=\(place()) moved=\(pre2 != place()) direction=\(direction(pre2Shown, shown())) shown=\(shown()) anchorCheck=[\(anchorCheck())]"); shot("\(k)-8-midturn-twice")
            clipEnd("\(k)-8-midturn-twice")
            note("TAPFROM \(k)-8 tappedFrom=\(pre2) now=\(place()) onTappedFromPage=\(place() == pre2) direction=\(direction(pre2Shown, shown()))")

            // The same cases with his next page learnt first, so the hash says exactly where a tap should land.
            var next = peekNext("\(k)-T1")
            clipBegin("\(k)-T1-T2-tap-then-land")
            at(0.9, 0.5).tap(); XCUIDevice.shared.orientation = .landscapeLeft; sleep(4); quiet(30, still: 3)
            hashCheck("\(k)-T1-tap-then-land", expect: next, mode: "within"); shot("\(k)-T1-tap-then-land")
            rotate(.portrait); quiet(30, still: 3)
            hashCheck("\(k)-T2-back-to-port", expect: next, mode: "same"); shot("\(k)-T2-back-to-port")
            clipEnd("\(k)-T1-T2-tap-then-land")
            next = peekNext("\(k)-T3")
            clipBegin("\(k)-T3-tap-then-land-and-back")
            at(0.9, 0.5).tap(); XCUIDevice.shared.orientation = .landscapeLeft; usleep(300_000); XCUIDevice.shared.orientation = .portrait; sleep(4); quiet(30, still: 3)
            hashCheck("\(k)-T3-tap-then-land-and-back", expect: next, mode: "same"); shot("\(k)-T3-tap-then-land-and-back")
            clipEnd("\(k)-T3-tap-then-land-and-back")
            rotate(.landscapeLeft); quiet(30, still: 3)
            next = peekNext("\(k)-T4")
            clipBegin("\(k)-T4-T5-land-tap-then-port")
            at(0.9, 0.5).tap(); XCUIDevice.shared.orientation = .portrait; sleep(4); quiet(30, still: 3)
            hashCheck("\(k)-T4-land-tap-then-port", expect: next, mode: "within"); shot("\(k)-T4-land-tap-then-port")
            rotate(.landscapeLeft); quiet(30, still: 3)
            hashCheck("\(k)-T5-back-to-land", expect: next, mode: "same"); shot("\(k)-T5-back-to-land")
            clipEnd("\(k)-T4-T5-land-tap-then-port")
            rotate(.portrait); quiet(30, still: 3)
            his = visibleText

            // Leave and reopen in the same orientation.
            leave(); launch([]); _ = el("reader.page").waitForExistence(timeout: 60)
            check("\(k)-9-reopen-port", his: his)
            hashCheck("\(k)-9-reopen-port", expect: his, mode: "same")
            his = visibleText
            let leftPortrait = his
            // Leave in portrait, turn the device while away, reopen in landscape (build 46's rot-1-10).
            leave(); rotate(.landscapeLeft, wait: 2); launch([]); _ = el("reader.page").waitForExistence(timeout: 60)
            check("\(k)-10-reopen-rotated-away-land", his: his)
            hashCheck("\(k)-10-reopen-rotated-away-land", expect: leftPortrait, mode: "within")
            his = visibleText
            leave(); launch([]); _ = el("reader.page").waitForExistence(timeout: 60)
            check("\(k)-11-reopen-land-again", his: his)
            hashCheck("\(k)-11-reopen-land-again", expect: leftPortrait, mode: "within")
            his = visibleText
            rotate(.portrait); check("\(k)-12-port-after-reopens", his: his)
            hashCheck("\(k)-12-port-after-reopens", expect: leftPortrait, mode: "same")
            // The other way: leave in landscape, turn to portrait while away, reopen in portrait, then landscape again.
            rotate(.landscapeLeft); quiet(30, still: 3)
            let leftLandscape = visibleText
            note("left in landscape place=\(place()) shown=\(shown())"); shot("\(k)-13a-left-land")
            leave(); rotate(.portrait, wait: 2); launch([]); _ = el("reader.page").waitForExistence(timeout: 60)
            check("\(k)-13-reopen-rotated-away-port", his: leftLandscape)
            hashCheck("\(k)-13-reopen-rotated-away-port", expect: leftLandscape, mode: "within")
            rotate(.landscapeLeft); check("\(k)-14-land-after-port-reopen", his: leftLandscape)
            hashCheck("\(k)-14-land-after-port-reopen", expect: leftLandscape, mode: "same")
            app.terminate(); sleep(2)
        }
        note("SUMMARY spots=\(spots.count) hisWordsOffScreen=\(notHeld) anchorLost=\(anchorLost) hashHeld=\(hashHeld) hashMoved=\(hashMoved)")
    }

    /// Duo: at several places, fold and unfold (plain, mid-turn, quick), then reopen folded and unfold.
    func testF_duoFolds() throws {
        tag0 = "folds"
        guard env["TASTE_HUB"] != nil else { throw XCTSkip("needs the host's hinge watcher") }
        let spots = (env["TASTE_SPOTS"] ?? "0.12,0.31,0.47,0.73").split(separator: ",").map(String.init)
        for (k, spot) in spots.enumerated() {
            posture("Closed"); sleep(4)
            openBook("gutenberg-pride-and-prejudice", at: spot)
            quiet(90, still: 4)
            forward(1)
            var his = visibleText
            note("SPOT \(spot) opened folded place=\(place()) anchorCheck=[\(anchorCheck())]"); hubShot("\(k)-0-closed")
            posture("Open"); sleep(6); check("\(k)-1-open", his: his)
            posture("Closed"); sleep(6); check("\(k)-2-closed", his: his)
            for r in 0..<3 { posture("Open"); sleep(4); posture("Closed"); sleep(4); note("fold round trip \(r) done") }
            check("\(k)-3-closed-after-3-round-trips", his: his)
            posture("Open"); sleep(6); check("\(k)-4-open", his: his)
            // He turns a page unfolded; that is his page now.
            forward(1); his = visibleText; note("turned unfolded place=\(place())")
            posture("Closed"); sleep(6); check("\(k)-5-closed-after-open-turn", his: his)
            his = visibleText
            let pre = place()
            at(0.9, 0.5).tap(); posture("Open"); sleep(6)
            quiet(30, still: 3)
            note("MIDTURN unfold from=\(pre) to=\(place()) moved=\(pre != place()) anchorCheck=[\(anchorCheck())]"); hubShot("\(k)-6-midturn-unfold")
            his = visibleText
            let pre2 = place()
            at(0.9, 0.5).tap(); posture("Closed"); sleep(6)
            quiet(30, still: 3)
            note("MIDTURN fold from=\(pre2) to=\(place()) moved=\(pre2 != place()) anchorCheck=[\(anchorCheck())]"); hubShot("\(k)-7-midturn-fold")
            his = visibleText
            // Reopen folded, then unfold straight after the page shows.
            leave(); launch([]); _ = el("reader.page").waitForExistence(timeout: 60)
            check("\(k)-8-reopen-closed", his: his)
            his = visibleText
            posture("Open"); sleep(2); check("\(k)-9-open-after-reopen", his: his)
            his = visibleText
            // Reopen unfolded, fold while away, reopen folded.
            leave(); launch([]); _ = el("reader.page").waitForExistence(timeout: 60)
            check("\(k)-10-reopen-open", his: his)
            his = visibleText
            leave(); posture("Closed"); sleep(4); launch([]); _ = el("reader.page").waitForExistence(timeout: 60)
            check("\(k)-11-reopen-folded-while-away", his: his)
            app.terminate(); sleep(2)
        }
        note("SUMMARY spots=\(spots.count) hisWordsOffScreen=\(notHeld) anchorLost=\(anchorLost)")
    }

    // MARK: Build 47 additions: margins and brushes (#547), sheets (#539), rotation frames (#550), chrome paper (#549)

    private func waitUntil(_ timeout: TimeInterval, _ done: () -> Bool) -> Bool {
        let up = Date().addingTimeInterval(timeout)
        while Date() < up { if done() { return true }; RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        return done()
    }
    /// Opens the book fresh and waits until it is ready and the opening cover has gone.
    private func openReady(at spot: String, extra more: [String] = []) {
        launch(["-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES", "-GatefoldNoLatency", "YES",
                "-GatefoldOpenBook", "gutenberg-pride-and-prejudice", "-GatefoldGoTo", spot] + more)
        XCTAssertTrue(el("reader.page").waitForExistence(timeout: 300))
        let ready = waitUntil(180) { anchorCheck().hasPrefix("ready") }
        let coverGone = waitUntil(60) { !el("reader.opening").exists }
        quiet(60, still: 4)
        note("OPENED at \(spot) ready=\(ready) coverGone=\(coverGone) place=\(place()) shown=\(shown()) posture=\(el("reader.posture").exists ? el("reader.posture").label : "-") win=\(app.windows.firstMatch.frame)")
    }
    private func landedCount() -> Int {
        let w = (el("reader.turnPlacement").exists ? el("reader.turnPlacement").label : "").split(separator: " ")
        return w.first == "landed" && w.count > 1 ? Int(w[1]) ?? 0 : 0
    }
    private func showChrome(_ id: String) {
        for _ in 0..<4 where !app.buttons[id].exists { at(0.5, 0.5).tap(); _ = waitUntil(5) { app.buttons[id].exists } }
    }

    /// iPad (#547): taps in the margins turn the page, forward on the right and back on the left; taps in the middle
    /// show the controls; a 10- to 30-pt brush turns nothing; a flick and a swipe still turn. In this orientation.
    /// END lines whose outcome is not the expected one carry UNEXPECTED-MOVE or NO-TURN and get a clip.
    func testT_margins() throws {
        tag0 = env["TASTE_LANDSCAPE"] != nil ? "margins-land" : "margins"
        landscape()
        openReady(at: env["TASTE_GOTO"] ?? "0.31")
        shot("0-open")
        var tally: [String: Int] = [:]
        /// expect: "forward", "backward", "none" (no move), "any" (logged only).
        func trial(_ n: String, expect: String, _ act: () -> Void) {
            hideChrome(); quiet(10, still: 2)
            let p0 = place(), s0 = shown(), l0 = landedCount(), t0 = visibleText
            note("BEGIN \(n) wall=\(wallNow()) place=\(p0)")
            act()
            _ = waitUntil(6) { landedCount() != l0 || app.buttons["reader.close"].exists || place() != p0 }
            quiet(15, still: 2.5)
            let p1 = place(), s1 = shown(), l1 = landedCount(), controls = app.buttons["reader.close"].exists
            let moved = p1 != p0, dir = moved ? direction(s0, s1) : "none"
            var verdict = "ok"
            switch expect {
            case "none": if moved { verdict = "UNEXPECTED-MOVE" }
            case "forward", "backward": if !moved { verdict = "NO-TURN CLIP" } else if dir != expect && dir != "?" { verdict = "WRONG-WAY CLIP" }
            default: break
            }
            tally[verdict.split(separator: " ")[0].description, default: 0] += 1
            note("END \(n) wall=\(wallNow()) place \(p0)->\(p1) moved=\(moved) direction=\(dir) expect=\(expect) \(verdict) landed \(l0)->\(l1) controlsUp=\(controls) hisWordsOnScreen=\(holds(t0)) shown \(s0)->\(s1)")
            shot(n)
        }
        // Margin taps, in the window's coordinates, as build 46's spazz run tapped.
        for (x, y) in [(0.97, 0.5), (0.93, 0.5), (0.90, 0.5), (0.97, 0.15), (0.97, 0.85)] as [(CGFloat, CGFloat)] {
            trial("tap-\(x),\(y)", expect: "forward") { at(x, y).tap() }
        }
        for (x, y) in [(0.03, 0.5), (0.07, 0.5), (0.10, 0.5), (0.03, 0.15), (0.03, 0.85)] as [(CGFloat, CGFloat)] {
            trial("tap-\(x),\(y)", expect: "backward") { at(x, y).tap() }
        }
        // Build 46's 20% and 80% taps (inside the text on most layouts): logged only.
        for (x, y) in [(0.8, 0.5), (0.2, 0.5)] as [(CGFloat, CGFloat)] { trial("tap-\(x),\(y)", expect: "any") { at(x, y).tap() } }
        // The middle shows the controls and turns nothing.
        for x in [0.5, 0.3, 0.7] as [CGFloat] { trial("middle-tap-\(x)", expect: "none") { at(x, 0.5).tap(); sleep(1) } }
        // Brushes: build 46's gesture (pressed 0.05 s, dragged and let go), across the middle and either side.
        for dx in [-20, 20, -10, 10, -30, 30] as [CGFloat] {
            trial("brush-\(Int(dx))pt-mid", expect: "none") { at(0.5, 0.5).press(forDuration: 0.05, thenDragTo: at(0.5, 0.5).withOffset(CGVector(dx: dx, dy: 0))) }
        }
        for (x, dx) in [(0.3, -20), (0.7, -20), (0.3, 20), (0.7, 20)] as [(CGFloat, CGFloat)] {
            trial("brush-\(Int(dx))pt-at-\(x)", expect: "none") { at(x, 0.5).press(forDuration: 0.05, thenDragTo: at(x, 0.5).withOffset(CGVector(dx: dx, dy: 0))) }
        }
        trial("brush-20pt-slow", expect: "none") { at(0.5, 0.5).press(forDuration: 0.4, thenDragTo: at(0.5, 0.5).withOffset(CGVector(dx: -20, dy: 0))) }
        trial("brush-20pt-diagonal", expect: "none") { at(0.5, 0.5).press(forDuration: 0.05, thenDragTo: at(0.5, 0.5).withOffset(CGVector(dx: -20, dy: 12))) }
        // Committed gestures still turn.
        trial("flick-60pt-fwd", expect: "forward") {
            at(0.6, 0.5).press(forDuration: 0.05, thenDragTo: at(0.6, 0.5).withOffset(CGVector(dx: -60, dy: 0)), withVelocity: XCUIGestureVelocity(600), thenHoldForDuration: 0)
        }
        trial("flick-60pt-back", expect: "backward") {
            at(0.4, 0.5).press(forDuration: 0.05, thenDragTo: at(0.4, 0.5).withOffset(CGVector(dx: 60, dy: 0)), withVelocity: XCUIGestureVelocity(600), thenHoldForDuration: 0)
        }
        trial("swipe-fwd", expect: "forward") { at(0.75, 0.5).press(forDuration: 0.05, thenDragTo: at(0.25, 0.5)) }
        trial("swipe-back", expect: "backward") { at(0.25, 0.5).press(forDuration: 0.05, thenDragTo: at(0.75, 0.5)) }
        // Margin taps once more, quickly after one another (a reader tapping on).
        for i in 0..<4 { trial("tap-run-fwd-\(i)", expect: "forward") { at(0.95, 0.5).tap() } }
        for i in 0..<2 { trial("tap-run-back-\(i)", expect: "backward") { at(0.05, 0.5).tap() } }
        note("SUMMARY \(tally.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
    }

    private var contentsRows: XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ OR identifier BEGINSWITH %@", "contents.current", "contents.entry."))
    }

    /// Contents (#539), Your Page and Fine-Tune, opened and closed without choosing: the same page, by build 46's hash.
    /// Each case gets BEGIN/END CLIP lines (a clip) and three shots: open, scrolled, after.
    func testQ_sheets() throws {
        tag0 = env["TASTE_LANDSCAPE"] != nil ? "sheets-land" : "sheets"
        landscape()
        let spots = (env["TASTE_SPOTS"] ?? "0.52,0.31").split(separator: ",").map(String.init)
        for (k, spot) in spots.enumerated() {
            openReady(at: spot)
            func openContents() -> Bool {
                showChrome("reader.contents")
                guard app.buttons["reader.contents"].exists else { return false }
                app.buttons["reader.contents"].tap()
                return contentsRows.firstMatch.waitForExistence(timeout: 20)
            }
            func scrollList() {
                let list = app.collectionViews.firstMatch
                if list.exists { list.swipeUp(velocity: .fast); list.swipeUp(velocity: .fast) } else { app.swipeUp(velocity: .fast) }
                sleep(3)
            }
            func sheet(_ n: String, contents: Bool = true, scrollFirst: Bool, _ open: (() -> Bool)? = nil, _ close: () -> Void) {
                if let only = env["TASTE_CASES"], !only.split(separator: ",").contains(Substring(n)) { return }
                if contentsRows.firstMatch.exists { note("SHEET \(k)-\(n): Contents was still up before the case; closing it"); closeContentsIfUp(); _ = waitUntil(10) { !contentsRows.firstMatch.exists } }
                hideChrome(); quiet(15, still: 3)
                let his = visibleText, s0 = shown()
                clipBegin("\(k)-\(n)")
                let up = contents ? openContents() : (open?() ?? false)
                shot("\(k)-\(n)-a-open")
                if scrollFirst { scrollList(); shot("\(k)-\(n)-b-scrolled") }
                let header = el("contents.header").exists
                close()
                let closed = contents ? waitUntil(15) { !contentsRows.firstMatch.exists && !app.collectionViews.firstMatch.exists } : waitUntil(15) { !el("appearance.panel").exists }
                let stillUp = !closed
                if contents { closeContentsIfUp() } else if el("appearance.panel").exists { at(0.5, 0.05).tap(); sleep(2) }
                hideChrome(); quiet(15, still: 3)
                note("SHEET \(k)-\(n) opened=\(up) headerSeen=\(header) closedByGesture=\(closed) neededDone=\(stillUp) contentsUpAtCheck=\(contentsRows.firstMatch.exists) backPill=\(el("reader.back").exists) direction=\(direction(s0, shown()))")
                hashCheck("\(k)-\(n)", expect: his, mode: "same")
                shot("\(k)-\(n)-c-after")
                clipEnd("\(k)-\(n)")
                // A move is recorded above; carry on from wherever he now is.
                if el("reader.back").exists { note("back pill up after \(n)") }
            }
            let pull = {
                let h = self.el("contents.header")
                let from = h.exists ? h.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)) : self.at(0.5, 0.2)
                from.press(forDuration: 0.05, thenDragTo: self.at(0.1, 0.98)); sleep(2)
            }
            sheet("contents-pull-header", scrollFirst: false) { pull() }
            sheet("contents-scroll-pull-header", scrollFirst: true) { pull() }
            sheet("contents-scroll-close-button", scrollFirst: true) {
                let c = self.app.buttons["contents.close"].firstMatch
                if c.exists { c.tap() } else { self.note("no contents.close button") }
                sleep(2)
            }
            // Build 46's spazz gesture, which jumped him two chapters on the folded Duo.
            sheet("contents-scroll-drag-b46", scrollFirst: true) { self.at(0.5, 0.2).press(forDuration: 0.05, thenDragTo: self.at(0.5, 0.98)); sleep(2) }
            sheet("contents-scroll-swipedown", scrollFirst: true) { self.app.swipeDown(velocity: .fast); sleep(2) }
            sheet("contents-scroll-pull-list", scrollFirst: true) {
                let l = self.app.collectionViews.firstMatch
                let from = l.exists ? l.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)) : self.at(0.5, 0.4)
                from.press(forDuration: 0.05, thenDragTo: self.at(0.5, 0.98)); sleep(2)
            }
            // Your Page opened and dismissed with a tap above it (build 46's spazz step).
            sheet("yourpage-open-dismiss", contents: false, scrollFirst: false, {
                self.showChrome("reader.appearance")
                guard self.app.buttons["reader.appearance"].exists else { return false }
                self.app.buttons["reader.appearance"].tap(); sleep(2); return self.el("appearance.panel").exists
            }) { self.at(0.5, 0.1).tap(); sleep(2) }
            // Fine-Tune: Justify flipped, then closed by a tap above (#539's sibling fix; his first words should stay).
            sheet("finetune-justify-close", contents: false, scrollFirst: false, {
                self.showChrome("reader.appearance")
                guard self.app.buttons["reader.appearance"].exists else { return false }
                self.app.buttons["reader.appearance"].tap(); sleep(2)
                if self.fineTune.waitForExistence(timeout: 5) { if !self.fineTune.isHittable { self.el("appearance.panel").swipeUp() }; self.fineTune.tap(); sleep(2) }
                let j = self.app.switches["appearance.justify"].firstMatch
                for _ in 0..<4 where j.exists && !j.isHittable { self.el("appearance.panel").swipeUp(); sleep(1) }
                let was = (j.value as? String) ?? "?"
                if j.exists { j.press(forDuration: 0); sleep(4) }
                self.note("justify \(was)->\((j.value as? String) ?? "?")"); self.shot("\(k)-justify-flipped")
                return j.exists
            }) {
                let p = self.el("appearance.panel"), w = self.app.windows.firstMatch.frame
                let off = p.frame.minY > 60 ? CGVector(dx: w.midX, dy: p.frame.minY / 2) : CGVector(dx: (p.frame.maxX + w.maxX) / 2, dy: w.midY)
                self.app.coordinate(withNormalizedOffset: .zero).withOffset(off).tap(); sleep(2)
            }
            app.terminate(); sleep(2)
        }
        note("SUMMARY hashHeld=\(hashHeld) hashMoved=\(hashMoved)")
    }

    /// iPad (#550): screenshots as fast as they come for 4 s after each turn of the device, and the ink of each
    /// frame's two halves (a spread's pages; top and bottom in portrait). Two plain round trips, then a forward tap
    /// with the turn of the device straight after it, each way.
    func testW_rotationFrames() throws {
        tag0 = "rotframes"
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad rotation") }
        rotate(.portrait, wait: 2)
        openReady(at: env["TASTE_GOTO"] ?? "0.31")
        forward(1)
        guard let dir = env["TASTE_SHOTS"] else { return }
        func film(_ n: String, to o: UIDeviceOrientation, tapFirst: Bool = false) {
            quiet(15, still: 3)
            let his = visibleText
            clipBegin(n)
            if tapFirst { at(0.9, 0.5).tap() }
            XCUIDevice.shared.orientation = o
            let t0 = Date(); var k = 0, notWhole = 0
            while Date().timeIntervalSince(t0) < 4 {
                let s = XCUIScreen.main.screenshot()
                let dt = Date().timeIntervalSince(t0)
                let i = TasteB47.ink(s.image)
                let whole = i.map { $0.0 > 0.01 && $0.1 > 0.01 } ?? false
                if !whole { notWhole += 1 }
                if k < 8 {
                    try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(String(format: "rotframes-%@-%02d-%.2fs.png", n, k, dt)))
                }
                note("FRAME \(n) \(k) t=\(String(format: "%.2f", dt)) ink=\(i.map { String(format: "%.3f/%.3f", $0.0, $0.1) } ?? "none") whole=\(whole)")
                k += 1
            }
            quiet(30, still: 3)
            note("FILM \(n) frames=\(k) notWhole=\(notWhole) hisWordsOnScreen=\(holds(his)) place=\(place()) anchorCheck=[\(anchorCheck())]")
            clipEnd(n)
            shot("\(n)-settled")
        }
        for r in 0..<2 { film("\(r)-to-land", to: .landscapeLeft); film("\(r)-to-port", to: .portrait) }
        film("tap-then-land", to: .landscapeLeft, tapFirst: true)
        film("tap-then-port", to: .portrait, tapFirst: true)
    }

    /// The paper beneath the controls (#549): with the controls up, the app's own measure (`reader.chromeOverText`,
    /// `-GatefoldChromeBackingProbe`): for each floating control, lines of text under it and how many no paper covers.
    /// Three themes and places; controls up on opening, after a turn, and with the Back pill up after a scrub.
    func testP_chromePaper() throws {
        tag0 = "paper"
        func measure(_ step: String) {
            let probe = el("reader.chromeOverText")
            var last = "", same = 0
            let ok = waitUntil(40) {
                let now = (probe.value as? String) ?? ""
                same = now == last && now.hasPrefix("pass 3: ") ? same + 1 : 0
                last = now
                return same >= 4
            }
            note("PAPER \(step) settled=\(ok) measure=[\(last)]")
        }
        for (k, (theme, spot)) in [("vellum", "0.31"), ("daylight", "0.12"), ("midnight", "0.73")].enumerated() {
            openReady(at: spot, extra: ["-GatefoldChromeBackingProbe", "YES", "-GatefoldTheme", theme])
            showChrome("reader.contents"); sleep(2)
            measure("\(k)-\(theme)-opened"); shot("\(k)-\(theme)-a-controls")
            hideChrome(); forward(1)
            showChrome("reader.contents"); sleep(2)
            measure("\(k)-\(theme)-after-turn"); shot("\(k)-\(theme)-b-after-turn")
            let scr = el("reader.scrubber")
            if scr.exists {
                scr.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.2, thenDragTo: scr.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)))
                sleep(4)
                showChrome("reader.contents"); sleep(2)
                measure("\(k)-\(theme)-back-pill"); shot("\(k)-\(theme)-c-back-pill")
            } else { note("PAPER \(k) no scrubber") }
            app.terminate(); sleep(2)
        }
    }
}
