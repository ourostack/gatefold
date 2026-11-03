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
    <!doctype html><html><head><meta name="viewport" content="width=device-width">
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

    @Test func thePlaceStartsOnHisPageWhenAWordBreaksAcrossThePageTurn() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        let web = WKWebView(frame: window.bounds)
        window.addSubview(web)
        window.isHidden = false
        let loaded = Loaded()
        web.navigationDelegate = loaded
        await withCheckedContinuation { continuation in
            loaded.done = continuation
            web.loadHTMLString(Self.page, baseURL: nil)
        }
        _ = await eval(web, ReaderJS.install)

        // Find a page that opens mid-word: the word's first letters are on the page before.
        var found = false
        for pageIndex in 1..<40 {
            _ = await eval(web, "document.scrollingElement.scrollLeft = \(pageIndex) * window.innerWidth; true")
            let midWord = await eval(web, """
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

            let json = await eval(web, ReaderJS.anchor(column: 0)) as? String
            struct Found: Decodable { var highlight: String }
            let anchor = try #require(json.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(Found.self, from: $0) })
            // The anchor's first letter is on this page, not at the foot of the page before.
            let left = await eval(web, """
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
            let onScreen = (await eval(web, ReaderJS.visibleText) as? String).map(ReaderJS.normalize) ?? ""
            let probe = String(ReaderJS.normalize(anchor.highlight).prefix(24))
            #expect(onScreen.contains(probe), "page \(pageIndex): the place's first words are not on screen")
            break
        }
        #expect(found, "no page opened mid-word; the test page did not break a word across a turn")
        window.isHidden = true
    }
}
