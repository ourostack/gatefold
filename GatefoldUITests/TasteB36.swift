import CryptoKit
import UIKit
import XCTest

/// Reviewer 2's build 25 checks (CI), through Ari's words. Reviewer-only, never committed. No book text is
/// printed: pages are compared by SHA-256 of the first 30 characters, captures are blurred before filing.
@MainActor
final class TasteB36: XCTestCase {
    private var app: XCUIApplication!
    private let env = ProcessInfo.processInfo.environment
    private var pad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    override func setUp() async throws { continueAfterFailure = true; app = XCUIApplication() }
    override func tearDown() async throws { XCUIDevice.shared.orientation = .portrait }

    private let base = ["-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldSkipWelcome", "YES",
                        "-GatefoldSignedIn", "YES", "-GatefoldAllowReopen", "YES", "-GatefoldNoLatency", "YES"]

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    private var vtext: String { (el("reader.visibleText").value as? String) ?? "" }
    private func hash(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined() }
    private func head(_ s: String) -> String { String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30)) }
    private func middle(_ t: String) -> String {
        let c = Array(t); guard c.count > 60 else { return t }
        let s = c.count / 2 - 20; return String(c[s..<(s + 40)])
    }
    private func note(_ s: String) { print("R2 \(s)") }
    private func f(_ d: Double) -> String { String(format: "%.1f", d) }

    private func settle(_ timeout: TimeInterval = 60) -> String {
        let up = Date().addingTimeInterval(timeout)
        var last = "", since = Date()
        while Date() < up {
            let now = vtext
            if now != last { last = now; since = Date() }
            if !now.isEmpty, Date().timeIntervalSince(since) > 2.5 { return now }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return vtext
    }

    @discardableResult
    private func turnForward() -> Bool {
        let before = vtext
        el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let up = Date().addingTimeInterval(15)
        while Date() < up { if vtext != before, !vtext.isEmpty { _ = settle(20); return true }; RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        return false
    }

    private func waitCounted(_ timeout: TimeInterval = 300) -> Bool {
        let c = el("reader.pageCount")
        let up = Date().addingTimeInterval(timeout)
        while Date() < up { if let v = c.value as? String, !v.isEmpty { return true }; RunLoop.current.run(until: Date().addingTimeInterval(0.5)) }
        return false
    }

    private func save(_ name: String, _ shot: XCUIScreenshot = XCUIScreen.main.screenshot()) {
        if let dir = env["R2_SHOTS"] { try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")) }
    }

    /// Share of dark pixels in each half along the long side (a spread's two pages; top and bottom in portrait).
    static func ink(_ image: UIImage, dark: UInt8 = 110) -> (Double, Double)? {
        guard let cg = image.cgImage else { return nil }
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var a = 0, b = 0
        let alongX = w >= h
        for y in stride(from: 0, to: h, by: 2) {
            for x in stride(from: 0, to: w, by: 2) where px[y * w + x] < dark {
                if (alongX ? x < w / 2 : y < h / 2) { a += 1 } else { b += 1 }
            }
        }
        let half = Double(w * h) / 8
        return (Double(a) / half, Double(b) / half)
    }
    private func inkText(_ i: (Double, Double)?) -> String { i.map { String(format: "%.3f/%.3f", $0.0, $0.1) } ?? "none" }

    private func leaveAndRelaunch(_ orientation: UIDeviceOrientation?) -> String {
        XCUIDevice.shared.press(.home)
        sleep(3)
        app.terminate()
        app.launchArguments = base
        app.launch()
        if let o = orientation { XCUIDevice.shared.orientation = o }
        _ = el("reader.page").waitForExistence(timeout: 60)
        sleep(2)
        _ = settle(60)
        sleep(4)
        return settle(10)
    }

    /// Contents, last row (or row `index`); samples the screen every 0.25 s for `window` s.
    /// Reports: the probe's change time, any blank frame (both halves under 0.004 ink), any spinner,
    /// how long the veil was up, and the back pill.
    private func contentsJump(_ tag: String, window: TimeInterval = 25) -> Bool {
        el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(2)
        guard el("reader.contents").waitForExistence(timeout: 5) else { note("\(tag) no contents button"); return false }
        el("reader.contents").tap()
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'contents.entry.'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15), "the contents list is up")
        sleep(1)
        let before = vtext
        let rowCount = rows.count
        let pick = rows.element(boundBy: min(30, max(0, rowCount - 1)))
        let pickID = pick.identifier
        for _ in 0..<6 where !pick.isHittable { app.swipeUp() }
        pick.tap()
        let t0 = Date()
        var changedAt = -1.0, veilFirst = -1.0, veilLast = -1.0, blankFrames = 0, frames = 0, spinner = false, minInk = 9.0
        var marks: [Double] = [0.5, 1.5, 3, 6, 10]
        while Date().timeIntervalSince(t0) < window {
            let dt = Date().timeIntervalSince(t0)
            let now = vtext
            if changedAt < 0, !now.isEmpty, head(now) != head(before) { changedAt = dt }
            if el("reader.veil").exists { if veilFirst < 0 { veilFirst = dt }; veilLast = dt }
            if app.activityIndicators.count > 0 { spinner = true }
            let shot = XCUIScreen.main.screenshot()
            if let i = Self.ink(shot.image) {
                frames += 1
                let m = i.0 + i.1
                minInk = min(minInk, m)
                if Self.ink(shot.image, dark: 170).map({ $0.0 + $0.1 < 0.004 }) ?? false { blankFrames += 1; if blankFrames <= 2 { save("\(tag)-blank-\(f(dt))", shot) } }
            }
            if let m = marks.first, dt >= m { save("\(tag)-\(m)s", shot); marks.removeFirst() }
            if changedAt >= 0, dt > changedAt + 3, marks.isEmpty || dt > 12 { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        let pill = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Back to page'")).firstMatch.exists
        note("\(tag) jump row=\(pickID) rows=\(rowCount) wordsChangedAt=\(f(changedAt)) s veil=\(f(veilFirst))..\(f(veilLast)) s frames=\(frames) blankFrames=\(blankFrames) minInkSum=\(String(format: "%.3f", minInk)) spinner=\(spinner) backPill=\(pill)")
        _ = settle(30)
        return changedAt >= 0
    }

    // MARK: A. Cold-start rotation repro (the build 19 blocker), with the jump measured and the spread sampled.

    func testA_ColdRotation() throws {
        try XCTSkipUnless(pad, "iPad path")
        XCUIDevice.shared.orientation = .portrait
        sleep(1)
        app.launchArguments = base + ["-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES",
                                      "-GatefoldOpenBook", "gutenberg-pride-and-prejudice", "-GatefoldGoTo", "0.31"]
        let launchAt = Date()
        app.launch()
        XCTAssertTrue(el("reader.page").waitForExistence(timeout: 120))
        let counted = waitCounted()
        note("A counted=\(counted) after \(f(Date().timeIntervalSince(launchAt))) s")
        _ = settle(60); sleep(3)
        save("a0-portrait-open")

        let jumped = contentsJump("a1")
        save("a1-after-jump")
        turnForward(); turnForward(); sleep(3)
        let portraitPage = vtext
        save("a2-two-pages-read")

        XCUIDevice.shared.orientation = .landscapeLeft
        let r0 = Date()
        var wholeAt = -1.0, worst: (Double, Double)? = nil, lastInk: (Double, Double)? = nil, stuckFrames = 0
        var marks: [Double] = [1, 3, 6, 10, 15]
        while Date().timeIntervalSince(r0) < 20 {
            let dt = Date().timeIntervalSince(r0)
            let shot = XCUIScreen.main.screenshot()
            if let i = Self.ink(shot.image) {
                lastInk = i
                if i.0 > 0.01, i.1 > 0.01 { if wholeAt < 0 { wholeAt = dt } } else { stuckFrames += 1; if worst == nil || min(i.0, i.1) < min(worst!.0, worst!.1) { worst = i } }
            }
            if let m = marks.first, dt >= m { save("a3-rot-\(Int(m))s", shot); marks.removeFirst() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        _ = settle(60); sleep(3)
        let his = vtext
        let endInk = Self.ink(XCUIScreen.main.screenshot().image)
        save("a4-his-page")
        let whole = (endInk?.0 ?? 0) > 0.01 && (endInk?.1 ?? 0) > 0.01
        note("A rotation wholeAt=\(f(wholeAt)) s nonWholeFrames=\(stuckFrames) worst=\(inkText(worst)) at20s=\(inkText(lastInk)) end=\(inkText(endInk)) \(whole ? "WHOLE" : "STUCK") hisContainsPortraitStart=\(his.contains(head(portraitPage)))")
        note("A setup jumped=\(jumped) hisHead=\(hash(head(his)))")
        XCTAssertTrue(whole, "the spread is whole after the rotation")

        var green = 0
        for round in 1...3 {
            let back = leaveAndRelaunch(.landscapeLeft)
            let bi = Self.ink(XCUIScreen.main.screenshot().image)
            save("a5-back-\(round)")
            let same = head(back) == head(his)
            let mid = back.contains(middle(his))
            if same { green += 1 }
            note("A round \(round) \(same ? "GREEN" : "RED") startsSame=\(same) middleSame=\(mid) reopenedHead=\(hash(head(back))) ink=\(inkText(bi))")
            XCTAssertTrue(same, "round \(round): reopened on his page")
        }
        note("A SUMMARY green=\(green) of 3 whole=\(whole)")
    }

    // MARK: B. Reopen on his words, by hash, after ordinary reading, in both orientations.

    func testB_ReopenOnWords() throws {
        let rounds = Int(env["R2_ROUNDS"] ?? "8") ?? 8
        let landscape = env["R2_LANDSCAPE"] != nil
        let o: UIDeviceOrientation = landscape ? .landscapeLeft : .portrait
        XCUIDevice.shared.orientation = o
        sleep(1)
        app.launchArguments = base + ["-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES",
                                      "-GatefoldOpenBook", "gutenberg-pride-and-prejudice", "-GatefoldGoTo", "0.42"]
        app.launch()
        XCTAssertTrue(el("reader.page").waitForExistence(timeout: 120))
        note("B counted=\(waitCounted())")
        _ = settle(60); sleep(3)
        var same = 0
        for r in 1...rounds {
            for _ in 0..<(1 + r % 3) { turnForward() }
            sleep(2)
            let his = settle(10)
            let back = leaveAndRelaunch(o)
            let ok = head(back) == head(his)
            if ok { same += 1 } else { save("b-miss-\(r)") }
            if r == 1 { save("b-back-1") }
            note("B round \(r) \(ok ? "SAME" : "MISS") his=\(hash(head(his))) back=\(hash(head(back))) middleSame=\(back.contains(middle(his)))")
        }
        note("B SUMMARY \(landscape ? "landscape" : "portrait") same=\(same) of \(rounds)")
    }

    // MARK: C. Contents jumps alone, three per launch.

    func testC_Jumps() throws {
        XCUIDevice.shared.orientation = env["R2_LANDSCAPE"] != nil ? .landscapeLeft : .portrait
        sleep(1)
        app.launchArguments = base + ["-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES",
                                      "-GatefoldOpenBook", "gutenberg-pride-and-prejudice", "-GatefoldGoTo", "0.31"]
        app.launch()
        XCTAssertTrue(el("reader.page").waitForExistence(timeout: 120))
        _ = settle(60); sleep(2)
        // The first jump comes before the count finishes (a fresh book), the next ones after.
        _ = contentsJump("c1")
        note("C counted=\(waitCounted())")
        _ = settle(30)
        // Back toward the front so the last row is a real jump again.
        let back = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Back to page'")).firstMatch
        if back.exists { back.tap(); _ = settle(30) }
        _ = contentsJump("c2")
        if back.exists { back.tap(); _ = settle(30) }
        _ = contentsJump("c3")
    }

    // MARK: D. Duo: launch on his page, rotation, last page.

    func testD_Duo() throws {
        XCUIDevice.shared.orientation = .portrait
        sleep(1)
        app.launchArguments = base + ["-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES",
                                      "-GatefoldOpenBook", "gutenberg-pride-and-prejudice", "-GatefoldGoTo", "0.31"]
        let t0 = Date()
        app.launch()
        XCTAssertTrue(el("reader.page").waitForExistence(timeout: 120))
        _ = settle(60)
        note("D first words after \(f(Date().timeIntervalSince(t0))) s ink=\(inkText(Self.ink(XCUIScreen.main.screenshot().image)))")
        save("d0-open")
        note("D counted=\(waitCounted())")
        _ = settle(30)
        turnForward(); turnForward(); sleep(2)
        var his = settle(10)
        var same = 0
        for r in 1...3 {
            let l0 = Date()
            let back = leaveAndRelaunch(.portrait)
            let ok = head(back) == head(his)
            if ok { same += 1 }
            save("d1-back-\(r)")
            note("D launch round \(r) \(ok ? "SAME" : "MISS") relaunchToSettled=\(f(Date().timeIntervalSince(l0))) s his=\(hash(head(his))) back=\(hash(head(back)))")
        }
        note("D SUMMARY launch same=\(same) of 3")

        // A turn of the phone and back: still his words.
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2); let land = settle(30); save("d2-landscape")
        note("D landscape ink=\(inkText(Self.ink(XCUIScreen.main.screenshot().image))) containsHisStart=\(land.contains(head(his))) hisStartsLandscape=\(head(land) == head(his))")
        XCUIDevice.shared.orientation = .portrait
        sleep(2); let port = settle(30); save("d3-portrait-again")
        note("D portrait again startsSame=\(head(port) == head(his)) back=\(hash(head(port)))")
        his = port

        // Last page: go near the end and read to it.
        app.terminate()
        app.launchArguments = base + ["-GatefoldOpenBook", "gutenberg-pride-and-prejudice", "-GatefoldGoTo", "0.995"]
        app.launch()
        XCTAssertTrue(el("reader.page").waitForExistence(timeout: 60))
        _ = settle(60); sleep(2)
        var n = 0, stalls = 0
        while n < 40, !el("endLeaf").exists {
            if !turnForward() { stalls += 1; if stalls > 2 { break } }
            n += 1
        }
        sleep(2)
        let lastInk = Self.ink(XCUIScreen.main.screenshot().image)
        save("d4-end")
        note("D end turns=\(n) stalls=\(stalls) endLeaf=\(el("endLeaf").exists) ink=\(inkText(lastInk))")
        // Leave at the end and come back.
        let endPage = vtext
        let back = leaveAndRelaunch(.portrait)
        save("d5-end-reopen")
        note("D end reopen startsSame=\(head(back) == head(endPage)) endLeaf=\(el("endLeaf").exists) empty=\(back.isEmpty)")
    }

    // MARK: E. Place loss by real gestures over a long session (no GoTo/OpenBook unless R2_REMOTE).

    private var probe: Bool { env["R2_NOPROBE"] == nil }
    /// A small grey picture of the page band (status bar and home bar cut away) for comparing frames.
    private func sig() -> [UInt8] {
        let img = XCUIScreen.main.screenshot().image
        guard let cg = img.cgImage else { return [] }
        let W = 48, H = 64
        var px = [UInt8](repeating: 0, count: W * H)
        guard let ctx = CGContext(data: &px, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
        let h = CGFloat(cg.height), w = CGFloat(cg.width)
        guard let crop = cg.cropping(to: CGRect(x: 0, y: h * 0.07, width: w, height: h * 0.86)) else { return [] }
        ctx.interpolationQuality = .medium
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: W, height: H))
        return px
    }
    private func dist(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 999 }
        var t = 0; for k in 0..<a.count { t += abs(Int(a[k]) - Int(b[k])) }
        return Double(t) / Double(a.count)
    }
    private var hisText = ""
    private var hisSig: [UInt8] = []
    private var moved = 0, kept = 0
    private func mark(_ step: String) { note("T \(String(format: "%.2f", Date().timeIntervalSince1970)) \(step)") }
    private func current() -> (String, [UInt8]) {
        if probe { let t = settle(20); sleep(1); return (t, sig()) }
        // No probe: wait for the screen to sit still for 2 s.
        var last = sig(), since = Date(); let up = Date().addingTimeInterval(20)
        while Date() < up, Date().timeIntervalSince(since) < 2 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            let now = sig(); if dist(now, last) > 1.5 { last = now; since = Date() }
        }
        return ("", last)
    }
    private func remember() { (hisText, hisSig) = current() }
    /// Expect the place kept: same opening words (probe) and the same picture (no probe).
    @discardableResult
    private func check(_ step: String, expectSame: Bool = true) -> Bool {
        let (t, s) = current()
        let d = dist(s, hisSig)
        let same = probe ? head(t) == head(hisText) : d < 4
        if same { kept += 1 } else { moved += 1 }
        let chrome = app.buttons["reader.close"].exists && app.buttons["reader.close"].isHittable
        note("E \(step) \(same ? "SAME" : "MOVED")\(same == expectSame ? "" : " <-- UNEXPECTED") his=\(hash(head(hisText))) now=\(hash(head(t))) picDist=\(String(format: "%.1f", d)) chromeUp=\(chrome) contains=\(probe ? t.contains(head(hisText)) : false)")
        if !same, expectSame { save("e-moved-\(step)") }
        return same
    }
    private func pageTap(_ x: CGFloat, _ y: CGFloat) { el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).tap() }
    private func hideChromeIfUp() {
        if app.buttons["reader.close"].exists, app.buttons["reader.close"].isHittable { pageTap(0.5, 0.5); sleep(2) }
    }

    func testE_PlaceByHand() throws {
        let o: UIDeviceOrientation = env["R2_LANDSCAPE"] != nil ? .landscapeLeft : .portrait
        XCUIDevice.shared.orientation = o
        sleep(1)
        var args = probe ? base + ["-GatefoldReset", "YES"] : ["-GatefoldSkipWelcome", "YES", "-GatefoldSignedIn", "YES"]
        args += ["-GatefoldDownloadAll", "YES"]
        if let after = env["R2_REMOTE"] {
            // The InkPad reads on while he reads here (fake Cloud; book opened by argument for the hook).
            args += ["-GatefoldOpenBook", "gutenberg-pride-and-prejudice", "-GatefoldRemoteAheadAfter", after, "-GatefoldRemoteAheadTo", env["R2_REMOTE_TO"] ?? "0.6"]
        }
        app.launchArguments = args
        mark("launch")
        app.launch()
        if env["R2_REMOTE"] == nil {
            let cover = el("book.gutenberg-pride-and-prejudice")
            XCTAssertTrue(el("library.grid").waitForExistence(timeout: 60))
            for _ in 0..<8 { if cover.exists, cover.isHittable { break }; el("library.grid").swipeUp(); sleep(1) }
            sleep(3)
            mark("open from shelf")
            cover.tap()
        }
        XCTAssertTrue(el("reader.page").waitForExistence(timeout: 90))
        _ = current(); sleep(3)
        save("e00-open")

        // 1. Read 12 pages: swipes and taps alternately.
        mark("read 12")
        for k in 1...12 {
            let before = current()
            if k % 2 == 0 { el("reader.page").swipeLeft() } else { pageTap(0.92, 0.5) }
            let after = current()
            let changed = probe ? head(after.0) != head(before.0) : dist(after.1, before.1) > 4
            let backwards = probe && !before.0.isEmpty && after.0.contains(head(before.0)) && head(after.0) != head(before.0)
            note("E turn \(k) \(k % 2 == 0 ? "swipe" : "tap") changed=\(changed) containsPrevStart=\(backwards)")
        }
        remember()
        save("e01-his-page")
        if env["R2_REMOTE"] != nil {
            // Keep reading through the moment the InkPad's place arrives.
            for k in 1...10 { pageTap(0.92, 0.5); _ = current(); remember(); note("E remote-window turn \(k) bannerUp=\(el("banner").exists)") }
            sleep(8)
            check("after InkPad read on (no tap on the banner)")
            note("E remote bannerUp=\(el("banner").exists)")
            save("e-remote-banner")
        }

        // 2. Stray taps.
        mark("stray taps")
        pageTap(0.5, 0.02); sleep(2); hideChromeIfUp(); check("tap on running head")
        pageTap(0.5, 0.985); sleep(2); hideChromeIfUp(); check("tap on folio")
        pageTap(0.03, 0.03); sleep(2); hideChromeIfUp(); check("tap top-left corner")
        pageTap(0.97, 0.03); sleep(2); hideChromeIfUp(); check("tap top-right corner", expectSame: false); remember()
        pageTap(0.5, 0.5); sleep(2); check("centre tap (controls up)")
        pageTap(0.5, 0.5); sleep(2); check("centre tap again (controls down)")
        el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap(); sleep(3); hideChromeIfUp(); check("double tap centre")
        el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).doubleTap(); sleep(3); hideChromeIfUp(); check("double tap upper middle")
        el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.6); sleep(2)
        if app.menuItems.count > 0 || app.buttons["Copy"].exists { pageTap(0.5, 0.95); sleep(1) }
        hideChromeIfUp(); check("long press centre (selection)")

        // A double tap at the right edge: how many pages?
        let pre = current()
        el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).doubleTap()
        sleep(3)
        let post = current()
        note("E double tap right edge changed=\(probe ? head(post.0) != head(pre.0) : dist(post.1, pre.1) > 4)")
        remember()

        // A tap while a turn animates.
        mark("tap during turn")
        el("reader.page").swipeLeft()
        pageTap(0.5, 0.5)
        sleep(3)
        let mid = current()
        note("E tap during turn chromeUp=\(app.buttons["reader.close"].exists) changedFromHis=\(probe ? head(mid.0) != head(hisText) : dist(mid.1, hisSig) > 4)")
        hideChromeIfUp()
        remember()
        save("e02-after-tap-during-turn")
        pageTap(0.92, 0.5); usleep(150_000); pageTap(0.08, 0.5); sleep(3)
        check("forward then back quickly")

        // 3. Contents opened and dismissed.
        mark("contents dismiss")
        pageTap(0.5, 0.5); sleep(2)
        if el("reader.contents").waitForExistence(timeout: 5) {
            el("reader.contents").tap(); sleep(3)
            save("e03-contents-up")
            app.swipeDown(velocity: .fast); sleep(3)
            if el("reader.contents").exists == false, app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'contents.entry.'")).count > 0 {
                pageTap(0.5, 0.03); sleep(2)
            }
            hideChromeIfUp()
            check("contents opened, swiped away")
        }
        pageTap(0.5, 0.5); sleep(2)
        if el("reader.contents").waitForExistence(timeout: 5) {
            el("reader.contents").tap(); sleep(3)
            let done = app.buttons.matching(NSPredicate(format: "label IN {'Done','Close','Cancel'}")).firstMatch
            if done.exists { done.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).tap() }
            sleep(3)
            hideChromeIfUp()
            check("contents opened, closed by button/outside")
        }

        // 4. The scrubber: a touch on the thumb that doesn't drag, then a drag and Back.
        mark("scrubber")
        pageTap(0.5, 0.5); sleep(2)
        let scr = el("reader.scrubber")
        if scr.waitForExistence(timeout: 5) {
            note("E scrubber value=\(scr.value as? String ?? "?") frame=\(scr.frame)")
            scr.press(forDuration: 0.3); sleep(3)
            hideChromeIfUp(); check("scrubber pressed without dragging")
            pageTap(0.5, 0.5); sleep(2)
            let a = scr.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            a.press(forDuration: 0.2, thenDragTo: scr.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)))
            sleep(4)
            save("e04-after-scrub")
            let backPill = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Back to page'")).firstMatch
            note("E scrub moved; backPill=\(backPill.exists)")
            if backPill.exists { backPill.tap(); sleep(4) }
            hideChromeIfUp()
            check("scrub then Back to page")
            hideChromeIfUp()
        } else { note("E no scrubber"); hideChromeIfUp() }

        // 5. Background and foreground.
        mark("background")
        for (i, wait) in [2, 5, 1, 8, 3].enumerated() {
            XCUIDevice.shared.press(.home)
            sleep(UInt32(wait))
            app.activate()
            sleep(2)
            check("background \(wait) s and back #\(i + 1)")
        }

        // 6. Rotation, out and back (iPad and Duo).
        mark("rotation")
        for i in 1...2 {
            XCUIDevice.shared.orientation = o == .portrait ? .landscapeLeft : .portrait
            sleep(3)
            let r = current()
            note("E rotate out #\(i) containsHisStart=\(r.0.contains(head(hisText))) startsSame=\(head(r.0) == head(hisText))")
            save("e05-rot-\(i)")
            XCUIDevice.shared.orientation = o
            sleep(3)
            check("rotate out and back #\(i)")
        }

        // 7. Reopen.
        mark("reopen")
        for i in 1...3 {
            XCUIDevice.shared.press(.home); sleep(3)
            app.terminate()
            app.launchArguments = probe ? base : ["-GatefoldSkipWelcome", "YES", "-GatefoldSignedIn", "YES"]
            app.launch()
            XCUIDevice.shared.orientation = o
            _ = el("reader.page").waitForExistence(timeout: 60)
            sleep(3)
            check("reopen #\(i)")
            if i == 1 { save("e06-reopen") }
        }
        mark("end")
        note("E SUMMARY kept=\(kept) moved=\(moved) probe=\(probe)")
    }
}
