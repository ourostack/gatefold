import GatefoldCloud
import GatefoldCore
import ReadiumNavigator
import ReadiumShared
import Testing
import UIKit
import WebKit
@testable import Gatefold

/// The catch-up page is loaded behind the page before the tap (`prepareStandby`). It must be laid out
/// in the page's own bands: loaded without them, its words were placed for a taller page, and once it
/// was swapped in and Readium asked for the bands, the page re-laid out under him and showed the lines
/// before his place (#46's reviewer leg: ReopenAfterControls 0 of 5, the web view 944 pt tall, then 758).
@MainActor @Suite(.serialized) struct StandbyInsetsTests {
    private static func webViews(in view: UIView) -> [WKWebView] {
        if let web = view as? WKWebView { return [web] }
        return view.subviews.flatMap(webViews)
    }

    /// The first web view's height once it has one and its spread has laid out; nil after 2 min (a hang guard).
    private static func webHeight(in view: UIView) async throws -> CGFloat? {
        for _ in 0..<1200 {
            if let web = webViews(in: view).first, web.bounds.height > 0 { return web.bounds.height }
            try await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    @Test func aStandbyPageIsLaidOutInThePagesOwnBands() async throws {
        let publication = try await HighlightTests.publication()
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1180, height: 820)
        let root = UIViewController()
        // A tablet page, whatever the simulator: the bands are a regular page's (`navigatorContentInset`).
        root.traitOverrides.horizontalSizeClass = .regular
        root.traitOverrides.verticalSizeClass = .regular
        window.rootViewController = root
        window.isHidden = false
        defer { window.isHidden = true }
        let app = AppModel(sync: FakeSyncService(), libraryRoot: URL.temporaryDirectory.appending(path: "standby-\(UUID().uuidString)"))
        let cloud = CloudBook(fastHash: "standby-insets", name: "pride-and-prejudice.epub", title: "Pride and Prejudice")
        await app.library.merge([cloud])
        let entry = try #require(app.library.book("standby-insets"))
        let model = ReaderModel(book: entry, publication: publication, app: app)
        defer { model.close() }
        let host = try #require(model.hostController)
        root.addChild(host)
        host.view.frame = root.view.bounds
        root.view.addSubview(host.view)
        host.didMove(toParent: root)

        let page = try #require(try await Self.webHeight(in: host.navigator.view), "the page made a web view")
        let bands = try #require(host.navigatorContentInset(host.navigator), "a regular page takes the tablet bands")
        #expect(abs(page - (host.navigator.view.bounds.height - bands.top - bands.bottom)) < 1, "the page itself sits in its bands")

        // Another chapter, as the Cloud's place is.
        let link = try #require(publication.readingOrder.dropFirst(3).first)
        nonisolated(unsafe) let book = publication
        let found = await book.locate(link)
        let locator = try #require(found)
        host.prepareStandby(at: locator)
        let standby = try #require(host.standbyPage, "a standby page is loading")
        await standby.ready.value
        let behind = try #require(try await Self.webHeight(in: standby.navigator.view), "the standby made a web view")
        #expect(abs(behind - page) < 1, "the standby page is \(behind) pt tall, the page \(page) pt: laid out for another page")
    }
}
