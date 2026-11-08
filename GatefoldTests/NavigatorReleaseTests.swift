import GatefoldCloud
import GatefoldCore
import ReadiumNavigator
import ReadiumShared
import Testing
import UIKit
import WebKit
@testable import Gatefold

/// #109: a navigator taken out of the reader lets go of its web views, and with them their web content
/// processes. Every typography reflow retires the 6 page counters; when their web views stayed alive, one
/// Fine-Tune test left 187 web content processes (4.8 GB) on a 7 GB runner, and its UI queries timed out (#28).
@MainActor @Suite(.serialized) struct NavigatorReleaseTests {
    private final class Held {
        weak var web: WKWebView?
        init(_ web: WKWebView) { self.web = web }
    }

    private static func webViews(in view: UIView) -> [WKWebView] {
        if let web = view as? WKWebView { return [web] }
        return view.subviews.flatMap(webViews)
    }

    @Test func retiredNavigatorsLetGoOfTheirWebViews() async throws {
        let publication = try await HighlightTests.publication()
        // In the app's scene, as the reader's window is: a window outside any scene may never send the
        // appearance calls a closed reader waits for.
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        let host = UIViewController()
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        var held: [Held] = []
        // Three rounds, as three reflows each retire the counters they started.
        for _ in 0..<3 {
            let navigator = try ReaderHostController.makeNavigator(publication: publication, at: nil, preferences: EPUBPreferences())
            host.addChild(navigator)
            navigator.view.frame = host.view.bounds
            host.view.addSubview(navigator.view)
            navigator.didMove(toParent: host)
            var webs: [WKWebView] = []
            for _ in 0..<100 where webs.isEmpty {
                try await Task.sleep(for: .milliseconds(100))
                webs = Self.webViews(in: navigator.view)
            }
            try #require(!webs.isEmpty, "the navigator made a web view")
            held += webs.map(Held.init)
            ReaderHostController.retire(navigator)
        }
        for _ in 0..<50 where held.contains(where: { $0.web != nil }) {
            try await Task.sleep(for: .milliseconds(100))
        }
        let alive = held.filter { $0.web != nil }.count
        #expect(alive == 0, "\(alive) of \(held.count) retired web views are still alive")
    }

    /// Open a book, close it, and its page's web views go once the reader is off screen: three times over,
    /// as he opens and closes books in a session.
    @Test func aClosedReaderLetsGoOfItsWebViews() async throws {
        let publication = try await HighlightTests.publication()
        // In the app's scene, as the reader's window is: a window outside any scene may never send the
        // appearance calls a closed reader waits for.
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        defer { window.isHidden = true }
        var held: [Held] = []
        for round in 0..<3 {
            let app = AppModel(sync: FakeSyncService(), libraryRoot: URL.temporaryDirectory.appending(path: "release-\(UUID().uuidString)"))
            let cloud = CloudBook(fastHash: "release-\(round)", name: "pride-and-prejudice.epub", title: "Pride and Prejudice")
            await app.library.merge([cloud])
            let entry = try #require(app.library.book("release-\(round)"))
            var model: ReaderModel? = ReaderModel(book: entry, publication: publication, app: app)
            let host = try #require(model?.hostController)
            // As SwiftUI shows the reader: a child controller whose view is in the window.
            root.addChild(host)
            host.view.frame = root.view.bounds
            root.view.addSubview(host.view)
            host.didMove(toParent: root)
            var webs: [WKWebView] = []
            for _ in 0..<100 where webs.isEmpty {
                try await Task.sleep(for: .milliseconds(100))
                webs = Self.webViews(in: host.view)
            }
            try #require(!webs.isEmpty, "the reader made a web view")
            held += webs.map(Held.init)
            // As the app closes it: the model first, then SwiftUI takes the reader off screen.
            model?.close()
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
            model = nil
        }
        for _ in 0..<50 where held.contains(where: { $0.web != nil }) {
            try await Task.sleep(for: .milliseconds(100))
        }
        let alive = held.filter { $0.web != nil }.count
        #expect(alive == 0, "\(alive) of \(held.count) closed readers' web views are still alive")
    }
}
