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

    /// Rides on a web view as an associated object, and signals as the web view is freed.
    private final class Gone {
        let signal: AsyncStream<Void>.Continuation
        init(_ signal: AsyncStream<Void>.Continuation) { self.signal = signal }
        deinit { signal.yield() }
    }

    /// Watches web views and waits for each one's release: the event itself, not a span of wall time,
    /// so a slow runner only makes the wait longer, never the verdict different.
    @MainActor private final class Releases {
        nonisolated(unsafe) private static let key = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        private(set) let releases = Releases()
        private let events: AsyncStream<Void>
        private let signal: AsyncStream<Void>.Continuation

        init() { (events, signal) = AsyncStream<Void>.makeStream() }

        func watch(_ webs: [WKWebView]) {
            for web in webs {
                held.append(Held(web))
                objc_setAssociatedObject(web, Self.key, Gone(signal), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
        }

        /// How many watched web views are still alive once every one has been freed, or once `hangGuard`
        /// has passed with some still held (only so a leak fails rather than hangs).
        func alive(hangGuard: Duration = .seconds(120)) async -> Int {
            let signal = self.signal
            let guardTask = Task { try? await Task.sleep(for: hangGuard); signal.finish() }
            defer { guardTask.cancel() }
            var gone = 0
            for await _ in events {
                gone += 1
                if gone >= held.count { break }
            }
            return held.filter { $0.web != nil }.count
        }
    }

    private static func webViews(in view: UIView) -> [WKWebView] {
        if let web = view as? WKWebView { return [web] }
        return view.subviews.flatMap(webViews)
    }

    /// Retired once its page has loaded. This passed on Readium 3.11.1 before the fix too (run 42509490935):
    /// it guards the plain path; the mid-load case below is the one that leaked.
    @Test func retiredNavigatorsLetGoOfTheirWebViews() async throws {
        let publication = try await HighlightTests.publication()
        // In the app's scene, as the reader's window is.
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        let host = UIViewController()
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        let releases = Releases()
        // Three rounds, as three reflows each retire the counters they started.
        for _ in 0..<3 {
            let navigator = try ReaderHostController.makeNavigator(publication: publication, at: nil, preferences: EPUBPreferences())
            host.addChild(navigator)
            navigator.view.frame = host.view.bounds
            host.view.addSubview(navigator.view)
            navigator.didMove(toParent: host)
            var webs: [WKWebView] = []
            for _ in 0..<1200 where webs.isEmpty { // until it has one; 2 min is only a hang guard
                try await Task.sleep(for: .milliseconds(100))
                webs = Self.webViews(in: navigator.view)
            }
            try #require(!webs.isEmpty, "the navigator made a web view")
            releases.watch(webs)
            ReaderHostController.retire(navigator)
        }
        let alive = await releases.alive()
        #expect(alive == 0, "\(alive) of \(releases.held.count) retired web views are still alive")
    }

    private final class Flag { var done = false }

    /// Retired mid-load, with a script waiting for the page to load (the standby's `ready`, or a counter on a
    /// chapter still loading): the web views go too. Readium kept the waiter, and with it the page, forever.
    @Test func aNavigatorRetiredMidLoadLetsGoOfItsWebViews() async throws {
        let publication = try await HighlightTests.publication()
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        let host = UIViewController()
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        let releases = Releases()
        var waited = 0
        for _ in 0..<3 {
            let navigator = try ReaderHostController.makeNavigator(publication: publication, at: nil, preferences: EPUBPreferences())
            host.addChild(navigator)
            navigator.view.frame = host.view.bounds
            host.view.addSubview(navigator.view)
            navigator.didMove(toParent: host)
            var webs: [WKWebView] = []
            for _ in 0..<24000 where webs.isEmpty { // until it has one; 2 min is only a hang guard
                try await Task.sleep(for: .milliseconds(5))
                webs = Self.webViews(in: navigator.view)
            }
            try #require(!webs.isEmpty, "the navigator made a web view")
            releases.watch(webs)
            let flag = Flag()
            Task { @MainActor in
                _ = await navigator.evaluateJavaScript("1")
                flag.done = true
            }
            for _ in 0..<3 { await Task.yield() }
            if !flag.done { waited += 1 }
            ReaderHostController.retire(navigator)
        }
        // A page that loaded before its script asked proves nothing about the waiter.
        try #require(waited > 0, "no script was left waiting on a page still loading")
        let alive = await releases.alive()
        #expect(alive == 0, "\(alive) of \(releases.held.count) web views retired mid-load are still alive (\(waited) waited)")
    }

    /// Open a book, close it, and the close itself retires its page, so the page's web views go: three times
    /// over, as he opens and closes books in a session.
    @Test func aClosedReaderLetsGoOfItsWebViews() async throws {
        let publication = try await HighlightTests.publication()
        // In the app's scene, as the reader's window is.
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        defer { window.isHidden = true }
        let releases = Releases()
        // Kept alive to the end, so the web views go because the close retired them, not because the model did.
        var models: [ReaderModel?] = []
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
            for _ in 0..<1200 where webs.isEmpty { // until it has one; 2 min is only a hang guard
                try await Task.sleep(for: .milliseconds(100))
                webs = Self.webViews(in: host.view)
            }
            try #require(!webs.isEmpty, "the reader made a web view")
            releases.watch(webs)
            // As the app closes it: the model first, then SwiftUI takes the reader off screen.
            model?.close()
            // Retired by the close itself, at once and with the reader still on screen: not by a view
            // lifecycle call (which came after the removal in CI run 42513920212), nor by the model going away.
            #expect(host.navigator.parent == nil, "the closed reader's navigator is retired")
            #expect(host.navigator.viewIfLoaded?.subviews.isEmpty ?? true, "and its pagination view is out of it (not proof that no page is made later: #116)")
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
            models.append(model)
            model = nil
        }
        let alive = await releases.alive()
        #expect(alive == 0, "\(alive) of \(releases.held.count) closed readers' web views are still alive")
        withExtendedLifetime(models) {}
    }
}
