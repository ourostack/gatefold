import Foundation
import GatefoldCore
import Testing
import UIKit
import WebKit
@testable import Gatefold

/// On a spread, the words on screen are both pages': the left page's and then the right's. Real unfold
/// (#58) opened a chapter whose left page starts with a picture's caption, then the heading his place
/// was taken from. The scan for the first words ran across both pages row by row, skipped the caption
/// and found the right page's first line before the left page's heading, so his words, plainly on the
/// left page, read as lost, and the restore jumped for them.
@MainActor
@Suite(.serialized)
struct SpreadVisibleTextTests {
    private static func html(columns: Int, picture: Bool, words: Int, tail: Bool = false) -> String {
        """
        <!doctype html><html><head><meta name="viewport" content="width=400, height=200, initial-scale=1, maximum-scale=1, user-scalable=no, shrink-to-fit=no">
        <style>
        :root { height: 100vh; column-width: \(columns == 2 ? "50vw" : "100vw"); column-gap: 0; column-fill: auto; overflow: hidden; }
        body { margin: 0; padding: 0 12px; font: 14px/18px Menlo, monospace; }
        .figcenter { height: 60px; } h2 { margin: 0; font-size: 14px; }
        .full { height: 182px; overflow: hidden; margin: 0; } .tail { break-before: column; margin: 0; }
        </style></head><body>
        \(picture ? "<div class=\"figcenter\"><span class=\"caption\">alpha caption words under the picture</span></div>" : "")
        <h2>Heading Nineteen.</h2>
        <p\(tail ? " class=\"full\"" : "")>\((0..<words).map { "word\($0)" }.joined(separator: " "))</p>
        \(tail ? "<p class=\"tail\">tail0 tail1 tail2</p>" : "")
        </body></html>
        """
    }

    private final class Loaded: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
    }

    private func eval(_ web: WKWebView, _ js: String) async -> Any? {
        try? await web.evaluateJavaScript(js)
    }

    /// A 400 x 200 page laid out in `columns` columns, with the reader's script installed.
    private func load(_ html: String, columns: Int?) async throws -> (UIWindow, WKWebView) {
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 200, width: 400, height: 200)
        let web = WKWebView(frame: window.bounds)
        web.scrollView.contentInsetAdjustmentBehavior = .never
        window.addSubview(web)
        window.isHidden = false
        let loaded = Loaded()
        web.navigationDelegate = loaded
        await withCheckedContinuation { continuation in
            loaded.done = continuation
            web.loadHTMLString(html, baseURL: nil)
        }
        var size = ""
        for _ in 0..<50 where size != "400x200" {
            size = await eval(web, "[window.innerWidth, window.innerHeight].join('x')") as? String ?? ""
            if size != "400x200" { try? await Task.sleep(for: .milliseconds(100)) }
        }
        try #require(size == "400x200", "the page never laid out at 400x200 (\(size))")
        _ = await eval(web, ReaderJS.install)
        if let columns { _ = await eval(web, ReaderJS.setColumns(columns)) }
        return (window, web)
    }

    /// His place as the reader takes it, and the words the reader reads as on screen.
    private func placeAndScreen(_ web: WKWebView) async throws -> (ReadingAnchor, String?) {
        let json = try #require(await eval(web, ReaderJS.anchor(column: 0)) as? String)
        struct Found: Decodable { var highlight: String }
        let found = try JSONDecoder().decode(Found.self, from: Data(json.utf8))
        let anchor = ReadingAnchor(href: "chapter.html", progression: 0, text: ReaderJS.normalize(found.highlight))
        return (anchor, await eval(web, ReaderJS.visibleText) as? String)
    }

    /// Real unfold's chapter: the left page opens with a captioned picture, then the heading his place was
    /// taken from; the right page is full of words from its first line.
    @Test func theLeftPagesWordsAreOnScreenWhenItOpensWithAPicture() async throws {
        let (window, web) = try await load(Self.html(columns: 2, picture: true, words: 40), columns: 2)
        defer { window.isHidden = true }
        let (anchor, text) = try await placeAndScreen(web)
        #expect(anchor.text?.hasPrefix("Heading Nineteen.") == true, "the place is the heading under the picture")
        let visible = VisibleRange(href: "chapter.html", start: 0, end: 0.1, text: text)
        #expect(visible.contains(anchor), "his words on the left page read as lost")
        #expect(text?.hasPrefix("Heading Nineteen.") == true, "the words on screen start with the left page's")
    }

    /// A chapter's own web view, turned or jumped into on a spread before the reader has told it the
    /// page count: the layout's two columns are read as two pages all the same.
    @Test func aChapterNotYetToldItsPagesIsReadPageByPage() async throws {
        let (window, web) = try await load(Self.html(columns: 2, picture: true, words: 40), columns: nil)
        defer { window.isHidden = true }
        let (anchor, text) = try await placeAndScreen(web)
        #expect(anchor.text?.hasPrefix("Heading Nineteen.") == true, "the place is the heading under the picture")
        #expect(VisibleRange(href: "chapter.html", start: 0, end: 0.1, text: text).contains(anchor), "his words on the left page read as lost")
    }

    /// Readium's own count decides when it gives one: a one-page window whose column width is under half
    /// of it (an 850-pt-wide landscape window takes Readium's 20em columns) is one page, and a count of
    /// two is two.
    @Test func aChapterNotYetToldItsPagesTakesReadiumsCount() async throws {
        for (style, pages) in [("column-count: 1; column-width: 150px", 1), ("column-count: 2; column-width: 150px", 2),
                               ("column-width: 200px", 2), ("column-width: 400px", 1)] {
            let html = Self.html(columns: 1, picture: false, words: 30)
                .replacingOccurrences(of: "column-width: 100vw;", with: style + ";")
            let (window, web) = try await load(html, columns: nil)
            defer { window.isHidden = true }
            #expect(await eval(web, "window.gatefold.pages()") as? Int == pages, "\(style) read as \(pages == 1 ? "two pages" : "one page")")
        }
    }

    /// The mirror: a chapter's last spread, whose right page ends a few lines down while the left page is
    /// full. The words on screen run to the right page's last word, not the left page's.
    @Test func theRightPagesWordsAreOnScreenWhenItEndsHigher() async throws {
        let (window, web) = try await load(Self.html(columns: 2, picture: false, words: 200, tail: true), columns: 2)
        defer { window.isHidden = true }
        let (_, text) = try await placeAndScreen(web)
        #expect(text?.hasPrefix("Heading Nineteen.") == true)
        #expect(text?.contains("tail1") == true, "the right page's last words are missing from the words on screen")
    }

    /// One page: unchanged, the page's first words to its last.
    @Test func aSinglePageReadsFromItsFirstWordsToItsLast() async throws {
        let (window, web) = try await load(Self.html(columns: 1, picture: false, words: 30), columns: 1)
        defer { window.isHidden = true }
        let (anchor, text) = try await placeAndScreen(web)
        #expect(VisibleRange(href: "chapter.html", start: 0, end: 0.1, text: text).contains(anchor))
        #expect(text?.hasPrefix("Heading Nineteen.") == true)
        #expect(text?.contains("word28") == true)
    }
}
