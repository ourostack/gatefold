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
        weak var web: UIView?
        init(_ web: UIView) { self.web = web }
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
        private(set) var held: [Held] = []
        private let events: AsyncStream<Void>
        private let signal: AsyncStream<Void>.Continuation

        init() { (events, signal) = AsyncStream<Void>.makeStream() }

        func watch(_ webs: [UIView]) {
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

    /// The view as it is on screen, drawn through the render server as the screen is.
    private static func render(_ view: UIView) -> CGImage? {
        UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            _ = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }.cgImage
    }

    private static func pixels(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        bytes.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    /// Of a picture's pixels, the share that differ from its paper (its commonest colour): the page's ink.
    private static func ink(_ image: CGImage) -> Double {
        let p = pixels(image)
        var counts: [UInt32: Int] = [:]
        for i in stride(from: 0, to: p.count, by: 4 * 97) {
            counts[UInt32(p[i]) << 16 | UInt32(p[i + 1]) << 8 | UInt32(p[i + 2]), default: 0] += 1
        }
        guard let paper = counts.max(by: { $0.value < $1.value })?.key else { return 0 }
        let rgb = [Int(paper >> 16 & 0xff), Int(paper >> 8 & 0xff), Int(paper & 0xff)]
        var inked = 0
        for i in stride(from: 0, to: p.count, by: 4) where (0..<3).contains(where: { abs(Int(p[i + $0]) - rgb[$0]) > 24 }) {
            inked += 1
        }
        return Double(inked) / Double(p.count / 4)
    }

    /// The share of pixels that differ between two pictures of the same size.
    private static func change(_ a: CGImage, _ b: CGImage) -> Double {
        let p = pixels(a), q = pixels(b)
        guard p.count == q.count else { return 1 }
        var changed = 0
        for i in stride(from: 0, to: p.count, by: 4) where (0..<3).contains(where: { abs(Int(p[i + $0]) - Int(q[i + $0])) > 24 }) {
            changed += 1
        }
        return Double(changed) / Double(p.count / 4)
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
    /// #275: a reader closed before its page has been drawn even once still leaves a picture in the page's place.
    /// The page's own snapshot needs a drawn page (UIKit logs "has not been rendered at least once"), so a close
    /// in that first moment, as on CI's loaded runner 350 ms after the open, left the page's place empty.
    @Test func aReaderClosedBeforeItsFirstFrameStillLeavesAPicture() async throws {
        let publication = try await HighlightTests.publication()
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        defer { window.isHidden = true }
        let app = AppModel(sync: FakeSyncService(), libraryRoot: URL.temporaryDirectory.appending(path: "first-frame-\(UUID().uuidString)"))
        let cloud = CloudBook(fastHash: "first-frame", name: "pride-and-prejudice.epub", title: "Pride and Prejudice")
        await app.library.merge([cloud])
        let entry = try #require(app.library.book("first-frame"))
        let model = ReaderModel(book: entry, publication: publication, app: app)
        let host = try #require(model.hostController)
        // Shown and closed in one turn of the main thread: no frame is drawn between the two.
        root.addChild(host)
        host.view.frame = root.view.bounds
        root.view.addSubview(host.view)
        host.didMove(toParent: root)
        try #require(host.navigator.viewIfLoaded != nil, "the reader's page is in its view")
        model.close()
        let picture = try #require(host.closePicture, "the reader closed before its first frame shows a picture of its page")
        #expect(host.view.subviews.last === picture, "over everything the reader draws")
        host.willMove(toParent: nil)
        host.view.removeFromSuperview()
        host.removeFromParent()
    }

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
        let pictures = Releases()
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
            // The first round films the close's own frame: the page drawn, then the picture in its place.
            var before: CGImage?
            if round == 0 {
                // Until the page has drawn and holds still (two shots in a row agree, so no fade is caught
                // midway); 2 min is only a hang guard.
                var last: CGImage?
                for _ in 0..<1200 {
                    if let shot = Self.render(host.view), Self.ink(shot) > 0.005 {
                        if let last, Self.change(last, shot) < 0.01 { before = shot; break }
                        last = shot
                    } else {
                        last = nil
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                try #require(before != nil, "the reader drew its page, and it held still, before the close")
            }
            // As the app closes it: the model first, then SwiftUI takes the reader off screen.
            model?.close()
            if let before {
                let after = try #require(Self.render(host.view))
                let changed = Self.change(before, after)
                #expect(changed < 0.01, "the close left the page drawn: \(Int(changed * 1000)) per mille of pixels changed (ink \(Int(Self.ink(before) * 1000)) to \(Int(Self.ink(after) * 1000)) per mille)")
            }
            // The picture that holds the screen as the reader leaves: freed with the reader.
            let picture = try #require(host.closePicture, "the closed reader shows a picture of its page")
            #expect(host.view.subviews.last === picture, "over everything the reader draws")
            pictures.watch([picture])
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
        // Then the readers go, and with them the pictures that stood in for their pages.
        try #require(!pictures.held.isEmpty, "a closed reader on screen put a picture in its page's place")
        models.removeAll()
        let pictured = await pictures.alive()
        #expect(pictured == 0, "\(pictured) of \(pictures.held.count) close pictures outlived their readers")
    }
}
