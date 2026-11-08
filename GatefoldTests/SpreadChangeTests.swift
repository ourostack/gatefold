import GatefoldCloud
import GatefoldCore
import ReadiumNavigator
import ReadiumShared
import Testing
import UIKit
import WebKit
@testable import Gatefold

/// gatefold#109: a script waiting on a page that a jump or reflow replaced never runs there. Our Readium
/// fork answers it at once with `spreadNotLoaded` (stock Readium kept it waiting forever, and the page with
/// it), and the reader runs its scripts again on the page that replaced it. Taken as an empty answer
/// instead, the anchor had no words, and the reader never said its first page was ready.
@MainActor @Suite(.serialized) struct SpreadChangeTests {
    private final class Asked {
        var anchor: ReadingAnchor?
        var done = false
    }

    private static func webViews(in view: UIView) -> [WKWebView] {
        if let web = view as? WKWebView { return [web] }
        return view.subviews.flatMap(webViews)
    }

    @Test func anAnchorAskedAsItsPageIsReplacedComesFromThePageThatReplacedIt() async throws {
        let publication = try await HighlightTests.publication()
        let order = publication.readingOrder
        try #require(order.count > 12, "the book has chapters to jump between")
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        defer { window.isHidden = true }
        let app = AppModel(sync: FakeSyncService(), libraryRoot: URL.temporaryDirectory.appending(path: "spread-\(UUID().uuidString)"))
        let cloud = CloudBook(fastHash: "spread-change", name: "pride-and-prejudice.epub", title: "Pride and Prejudice")
        await app.library.merge([cloud])
        let entry = try #require(app.library.book("spread-change"))
        let model = ReaderModel(book: entry, publication: publication, app: app)
        let host = try #require(model.hostController)
        root.addChild(host)
        host.view.frame = root.view.bounds
        root.view.addSubview(host.view)
        host.didMove(toParent: root)
        defer {
            model.close()
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
        }

        // Until the first page answers with its words; 2 min is only a hang guard.
        var opened = false
        for _ in 0..<1200 where !opened {
            opened = await host.currentAnchor()?.0.text != nil
            if !opened { try await Task.sleep(for: .milliseconds(100)) }
        }
        try #require(opened, "the first page answered with its words")

        // A jump to a chapter, and the anchor asked while its page is still loading (only the page on
        // screen is loaded here, so the jump makes a new one).
        let before = Set(Self.webViews(in: host.navigator.view).map(ObjectIdentifier.init))
        Task { _ = await host.navigator.go(to: order[6], options: .init(animated: false)) }
        var loading: WKWebView?
        for _ in 0..<24000 where loading == nil { // until the jump's page exists; 2 min is only a hang guard
            await Task.yield()
            loading = Self.webViews(in: host.navigator.view).first { !before.contains(ObjectIdentifier($0)) }
            if loading == nil { try await Task.sleep(for: .milliseconds(5)) }
        }
        let first = try #require(loading, "the jump made a new page")
        let asked = Asked()
        let (answered, signal) = AsyncStream<Void>.makeStream()
        Task { @MainActor in
            asked.anchor = await host.currentAnchor()?.0
            asked.done = true
            signal.yield()
        }
        for _ in 0..<3 { await Task.yield() }
        // A page that loaded before the second jump proves nothing about a replaced one.
        try #require(first.isLoading && !asked.done, "the anchor's script was waiting on a page still loading")
        // A second jump replaces that page while the anchor's script waits on it.
        Task { _ = await host.navigator.go(to: order[10], options: .init(animated: false)) }

        // On stock Readium the script waits forever: 2 min is only a hang guard.
        let hangGuard = Task { try? await Task.sleep(for: .seconds(120)); signal.finish() }
        for await _ in answered { break }
        hangGuard.cancel()
        #expect(asked.done, "the anchor came back")
        #expect(asked.anchor?.text != nil, "with words, from the page that replaced the one it waited on")
    }
}
