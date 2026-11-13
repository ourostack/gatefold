import XCTest

/// Reviewer's driver for the build-25 delight review (CI). Local to the reviewer's clone; never committed.
@MainActor
final class TasteB36UITests: XCTestCase {
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
        let p0 = place(); let chrome0 = el("reader.contents").exists
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
        note("END \(name) wall=\(f.string(from: Date())) place \(p0)->\(p1) moved=\(moved) expect=\(expect) \(verdict) chrome \(chrome0)->\(el("reader.contents").exists) nums=\(numbers())")
    }
    /// Taps the page only when the page itself takes the tap: with a sheet still up, a centre tap lands on
    /// whatever row is there (gatefold#305: three Contents "jumps" were this tap).
    private func hideChrome() {
        if el("reader.contents").exists, el("reader.page").isHittable { el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); sleep(1) }
    }
    /// Closes Contents with its own Done button if the swipe left it up (gatefold#305), and waits until the page is back.
    private func closeContentsIfUp() {
        let done = app.navigationBars.buttons["Done"]
        if !el("reader.page").isHittable, done.exists {
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
}
