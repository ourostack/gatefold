import Foundation
import Testing
import UIKit
import WebKit
@testable import Gatefold

/// The reader's place is the first words on his page. When the page opens on the second half of a
/// word hyphenated across the page break ("her Lady-" | "ship would…"), the place must still be on
/// his page: build 15's larger iPad type put such a break on a reopened page, and the anchor's
/// whole word started a page early, so the reopen landed one page back.
@MainActor
@Suite(.serialized)
struct AnchorWordTests {
    /// A paginated page laid out as Readium does (columns one screen wide, turned by scrolling),
    /// in narrow columns of long words that may break at any soft hyphen.
    private static let page = """
    <!doctype html><html><head><meta name="viewport" content="width=300, height=200, initial-scale=1, maximum-scale=1, user-scalable=no">
    <style>
    :root { height: 100vh; column-width: 100vw; column-gap: 0; column-fill: auto; overflow: hidden; }
    body { margin: 0; padding: 0 12px; font: 20px/24px Menlo, monospace; hyphens: manual; -webkit-hyphens: manual; }
    </style></head><body><p>\(
        (0..<400).map { "w\($0)su\u{AD}per\u{AD}cal\u{AD}if\u{AD}rag\u{AD}il\u{AD}is\u{AD}tic\u{AD}ex\u{AD}pi\u{AD}al\u{AD}i\u{AD}do\u{AD}cious" }.joined(separator: " ")
    )</p></body></html>
    """

    private final class Loaded: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
    }

    private func eval(_ web: WKWebView, _ js: String) async -> Any? {
        try? await web.evaluateJavaScript(js)
    }

    /// Runs `js` on the page scrolled by `scroll` (a statement), in one call: a late layout pass in a
    /// bare web view can put the scroll back to the start between two calls (Readium holds its own).
    private func eval(_ web: WKWebView, at scroll: String, _ js: String) async -> Any? {
        try? await web.evaluateJavaScript("\(scroll); \(js)")
    }

    @Test func thePlaceStartsOnHisPageWhenAWordBreaksAcrossThePageTurn() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        // Clear of the screen's safe areas, which would shrink the page the web view lays out.
        window.frame = CGRect(x: 0, y: 200, width: 300, height: 200)
        let web = WKWebView(frame: window.bounds)
        web.scrollView.contentInsetAdjustmentBehavior = .never
        window.addSubview(web)
        window.isHidden = false
        let loaded = Loaded()
        web.navigationDelegate = loaded
        await withCheckedContinuation { continuation in
            loaded.done = continuation
            web.loadHTMLString(Self.page, baseURL: nil)
        }
        for _ in 0..<50 {
            if await eval(web, "[window.innerWidth, window.innerHeight].join('x')") as? String == "300x200" { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        _ = await eval(web, ReaderJS.install)

        // Find a page that opens mid-word: the word's first letters are on the page before.
        var found = false
        for pageIndex in 1..<40 {
            let scroll = "document.scrollingElement.scrollLeft = \(pageIndex) * window.innerWidth"
            let midWord = await eval(web, at: scroll, """
            (function () {
              const w = window.innerWidth;
              for (let y = 6; y < window.innerHeight - 6; y += 10) {
                for (let x = 4; x < w - 4; x += 14) {
                  const r = document.caretRangeFromPoint(x, y);
                  if (r && r.startContainer.nodeType === Node.TEXT_NODE) {
                    const t = r.startContainer.textContent;
                    return r.startOffset > 0 && !/\\s/.test(t[r.startOffset - 1]);
                  }
                }
              }
              return false;
            })()
            """) as? Bool ?? false
            guard midWord else { continue }
            found = true

            let json = await eval(web, at: scroll, ReaderJS.anchor(column: 0)) as? String
            struct Found: Decodable { var highlight: String }
            let anchor = try #require(json.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(Found.self, from: $0) })
            // The anchor's first letter is on this page, not at the foot of the page before.
            let left = await eval(web, at: scroll, """
            (function () {
              const words = \(String(decoding: try JSONEncoder().encode(anchor.highlight), as: UTF8.self));
              const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
              let text = "", nodes = [];
              while (walker.nextNode()) { nodes.push([walker.currentNode, text.length]); text += walker.currentNode.data; }
              const at = text.indexOf(words);
              for (const [node, start] of nodes) {
                if (start + node.data.length <= at) { continue; }
                const range = document.createRange();
                range.setStart(node, at - start);
                range.setEnd(node, at - start + 1);
                return range.getBoundingClientRect().left;
              }
              return null;
            })()
            """) as? Double
            let x = try #require(left)
            #expect(x >= 0, "page \(pageIndex): the place starts \(x) pt left of his page, on the page before")
            // And the settle's own check finds it on screen.
            let onScreen = (await eval(web, at: scroll, ReaderJS.visibleText) as? String).map(ReaderJS.normalize) ?? ""
            let probe = String(ReaderJS.normalize(anchor.highlight).prefix(24))
            #expect(onScreen.contains(probe), "page \(pageIndex): the place's first words are not on screen")
            break
        }
        #expect(found, "no page opened mid-word; the test page did not break a word across a turn")
        window.isHidden = true
    }
    /// The exact case, built to measure rather than searched for: every line is filled to the column's
    /// width with made-up words, and the column's last line ends "Lady-", so the next page opens on
    /// "ship". Paginated (the word's start is in the column before) and scrolled (the line above).
    private static let exactPage = """
    <!doctype html><html><head><meta name="viewport" content="width=300, height=200, initial-scale=1, maximum-scale=1, user-scalable=no">
    <style>
    :root { height: 100vh; overflow: hidden; }
    :root.columns { column-width: 100vw; column-gap: 0; column-fill: auto; }
    :root.scrolled { overflow: scroll; }
    body { margin: 0; padding: 0; font: 20px/24px Menlo, monospace; hyphens: manual; -webkit-hyphens: manual; }
    p { margin: 0; }
    </style></head><body><p id="t"></p></body></html>
    """

    /// Fills the page so its first column (or first screen) ends on "Lady-"; returns where the halves are.
    private static func build(columns: Bool) -> String {
        """
        (function () {
          document.documentElement.className = \(columns ? "'columns'" : "'scrolled'");
          const p = document.getElementById('t');
          const probe = document.createElement('span'); probe.textContent = 'x'.repeat(100); p.appendChild(probe);
          const adv = probe.getBoundingClientRect().width / 100; probe.remove();
          const n = Math.floor(window.innerWidth / adv + 0.001), lines = Math.floor(window.innerHeight / 24);
          const word = (i, len) => (String.fromCharCode(97 + (i % 26)) + String.fromCharCode(97 + Math.floor(i / 26) % 26) + 'q'.repeat(64)).slice(0, len);
          const out = [];
          for (let i = 0; i < lines - 1; i++) { const a = Math.floor(n / 2); out.push(word(2 * i, a) + ' ' + word(2 * i + 1, n - a - 1)); }
          out.push(word(90, n - 6) + ' Lady\\u00ADship would');
          for (let i = 0; i < 60; i++) { out.push(word(100 + i, 7)); }
          p.textContent = out.join(' ');
          const text = p.firstChild, at = text.data.indexOf('Lady');
          const rect = (o) => { const r = document.createRange(); r.setStart(text, o); r.setEnd(text, o + 1); return r.getBoundingClientRect(); };
          const head = rect(at), tail = rect(at + 5);
          return JSON.stringify({ n: n, lines: lines, headLeft: head.left, headTop: head.top, tailLeft: tail.left, tailTop: tail.top, w: window.innerWidth, h: window.innerHeight });
        })()
        """
    }

    @Test(arguments: [true, false])
    func aPageOpeningOnTheSecondHalfOfAHyphenatedWordKeepsThePlaceOnIt(columns: Bool) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        // Clear of the screen's safe areas, which would shrink the page the web view lays out.
        window.frame = CGRect(x: 0, y: 200, width: 300, height: 200)
        let web = WKWebView(frame: window.bounds)
        web.scrollView.contentInsetAdjustmentBehavior = .never
        window.addSubview(web)
        window.isHidden = false
        defer { window.isHidden = true }
        let loaded = Loaded()
        web.navigationDelegate = loaded
        await withCheckedContinuation { continuation in
            loaded.done = continuation
            web.loadHTMLString(Self.exactPage, baseURL: nil)
        }
        // The case is measured, so the viewport must be the web view's own, unscaled.
        for _ in 0..<50 {
            let size = await eval(web, "[window.innerWidth, window.innerHeight].join('x')") as? String
            if size == "300x200" { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        struct Built: Decodable { var n: Int; var lines: Int; var headLeft, headTop, tailLeft, tailTop, w, h: Double }
        let json = try #require(await eval(web, Self.build(columns: columns)) as? String)
        let built = try JSONDecoder().decode(Built.self, from: Data(json.utf8))
        // The case is exact: "Lady-" ends the first page, "ship" opens the second, on its first line.
        let scroll: String
        if columns {
            #expect(built.headLeft < built.w && built.tailLeft >= built.w && built.tailLeft < built.w + 24 && built.tailTop < 24, "not the case: \(json)")
            scroll = "document.scrollingElement.scrollLeft = window.innerWidth"
        } else {
            #expect(built.tailTop >= Double(built.lines) * 24 && built.tailTop < Double(built.lines + 1) * 24 && built.tailLeft < 24 && built.headTop < built.tailTop, "not the case: \(json)")
            scroll = "document.scrollingElement.scrollTop = \(built.lines * 24)"
        }
        _ = await eval(web, ReaderJS.install)
        // The page opens mid-word: its first caret is inside "Ladyship", after "Lady".
        let firstCaret = await eval(web, at: scroll, """
        (function () {
          for (let y = 6; y < window.innerHeight - 6; y += 10) {
            for (let x = 4; x < window.innerWidth - 4; x += 14) {
              const r = document.caretRangeFromPoint(x, y);
              if (r && r.startContainer.nodeType === Node.TEXT_NODE) { return r.startContainer.data.slice(r.startOffset - 5, r.startOffset + 4); }
            }
          }
          return null;
        })()
        """) as? String
        #expect(firstCaret?.hasPrefix("Lady\u{AD}") == true, "the page does not open on the word's second half: \(String(describing: firstCaret))")

        struct Found: Decodable { var highlight: String }
        let anchorJSON = try #require(await eval(web, at: scroll, ReaderJS.anchor(column: 0)) as? String)
        let anchor = try JSONDecoder().decode(Found.self, from: Data(anchorJSON.utf8))
        // The place is the page's first whole word, never the word's start on the page before.
        #expect(anchor.highlight.hasPrefix("would"), "the place starts \(anchor.highlight.prefix(12))")
        let onScreen = (await eval(web, at: scroll, ReaderJS.visibleText) as? String).map(ReaderJS.normalize) ?? ""
        #expect(onScreen.contains(String(ReaderJS.normalize(anchor.highlight).prefix(24))), "the place's first words are not on his page")
    }
}
