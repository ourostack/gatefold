import GatefoldCore
import SwiftUI
import UIKit
import WebKit

/// The page as the reader left it, kept so that coming back to Gatefold after iOS has ended it opens
/// straight onto his page, as a printed book left open would be: the picture is up from the first
/// frame, and the live page takes its place, pixel for pixel the same, once it has laid out.
///
/// One picture per book and window size (so per posture: the folded Duo, the spread, the iPad either
/// way up), taken as the app goes to the background, in the Caches folder.
@MainActor
enum ReopenSnapshot {
    struct Meta: Codable, Equatable {
        var book: String
        var width: Double
        var height: Double
        var theme: String
        var savedAt: Date
        /// The page's frame when pictured (x, y, width, height): the live page matches it only if it
        /// lays out the same way.
        var page: [Double]?
    }

    /// A picture that fits this launch.
    struct Picture {
        let image: UIImage
        let meta: Meta
    }

    private static var directory: URL {
        URL.cachesDirectory.appending(path: "Reopen", directoryHint: .isDirectory)
    }

    private static func name(book: String, size: CGSize) -> String {
        let safe = book.map { $0.isLetter || $0.isNumber || $0 == "-" ? String($0) : "_" }.joined()
        return "\(safe)-\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
    }

    /// The saved picture of `book` for a window of `size` in `theme`, if there is one.
    static func load(book: String, size: CGSize, theme: ReaderTheme) -> Picture? {
        let base = directory.appending(path: name(book: book, size: size))
        guard let data = try? Data(contentsOf: base.appendingPathExtension("json")),
              let meta = try? JSONDecoder().decode(Meta.self, from: data),
              meta.book == book, meta.theme == theme.rawValue,
              let image = UIImage(contentsOfFile: base.appendingPathExtension("png").path) else { return nil }
        return Picture(image: image, meta: meta)
    }

    private static var taking: Task<Void, Never>?
    /// The picture on disk is of the page as it was when the app last stopped being active.
    private static var keptFor: URL?

    /// He may be leaving (the app has stopped being active, and can still draw): picture the page now
    /// and keep it. iOS may end Gatefold any time once it is in the background.
    static func keep(model: ReaderModel) {
        taking?.cancel()
        taking = Task { await take(model: model) }
    }

    /// Back in the app: the page will move on, so the kept picture no longer shows where he is.
    /// A new one is taken the next time he leaves.
    static func setAside() {
        taking?.cancel()
        taking = nil
        if let keptFor { forget(keptFor) }
        keptFor = nil
    }

    /// Takes the picture of the whole window as it is now: the page, its running head and footer.
    /// Nothing is kept over a moment the page will not reopen to (an end leaf, a slip, the controls
    /// up); a stale picture for this size is set aside instead.
    private static func take(model: ReaderModel) async {
        guard let host = model.hostController, let window = host.navigator.view.window else { return }
        let size = window.bounds.size
        let base = directory.appending(path: name(book: model.bookID, size: size))
        guard model.pageReady, model.endLeaf == nil, model.slip == nil, !model.chromeVisible, !model.isClosed else {
            forget(base)
            readerLog.notice("reopen: no picture kept (page ready \(model.pageReady, privacy: .public), end leaf \(model.endLeaf != nil, privacy: .public), slip \(model.slip != nil, privacy: .public), controls \(model.chromeVisible, privacy: .public))")
            return
        }
        let began = Date()
        let image = await picture(of: window, page: host)
        guard !Task.isCancelled else { return }
        let frame = model.layout.pageFrame
        let meta = Meta(book: model.bookID, width: size.width, height: size.height, theme: model.theme.rawValue, savedAt: Date(),
                        page: [frame.minX, frame.minY, frame.width, frame.height])
        let pictured = Date().timeIntervalSince(began)
        keptFor = base
        // Encoding and writing off the main thread; the picture itself had to be drawn on it.
        let directory = directory
        await Task.detached(priority: .userInitiated) {
            do {
                guard let png = image.pngData() else { return }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try png.write(to: base.appendingPathExtension("png"), options: .atomic)
                try JSONEncoder().encode(meta).write(to: base.appendingPathExtension("json"), options: .atomic)
            } catch {
                readerLog.notice("reopen: couldn't keep the picture: \(error.localizedDescription, privacy: .public)")
            }
        }.value
        readerLog.notice("reopen: kept a picture of the page \(Int(size.width), privacy: .public)x\(Int(size.height), privacy: .public) (drawn in \(pictured, privacy: .public) s, kept in \(Date().timeIntervalSince(began), privacy: .public) s)")
    }

    private static func forget(_ base: URL) {
        // Emptied rather than deleted: a later save overwrites it, and an empty file never loads.
        try? Data().write(to: base.appendingPathExtension("json"))
    }

    /// The window drawn as it is on screen, with each web view's own rendering drawn over its frame
    /// where the window's drawing left it bare, then the window's overlays (the running head, the
    /// footer) drawn again on top.
    private static func picture(of window: UIWindow, page host: ReaderHostController) async -> UIImage {
        let bounds = window.bounds
        let pageImage = await host.snapshot()
        let pageFrame = host.navigator.view.convert(host.navigator.view.bounds, to: window)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = true
        format.scale = window.screen.scale
        // The window without the page: hide the page's view, draw the window (paper, head, footer, ribbon).
        let pageView = host.navigator.view!
        let alpha = pageView.alpha
        pageView.alpha = 0
        let overlays = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            window.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        pageView.alpha = alpha
        let theme = host.weakModel?.theme
        let paper = theme?.uiBackground ?? .systemBackground
        let dark = theme?.palette.isDark ?? false
        return UIGraphicsImageRenderer(bounds: bounds, format: format).image { ctx in
            paper.setFill()
            ctx.fill(bounds)
            pageImage.draw(in: pageFrame)
            // The head, footer and ribbon over the words: both lie on the same paper, so keeping the
            // inkier pixel of the two (the darker on light paper, the lighter on dark) keeps each.
            overlays.draw(in: bounds, blendMode: dark ? .lighten : .darken, alpha: 1)
        }
    }
}

/// The saved page, full-window, while the live one lays out beneath it.
struct ReopenPictureView: View {
    let image: UIImage

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .interpolation(.none)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .accessibilityIdentifier("reader.reopenPicture")
            // A touch waits for the live page: a turn under the picture would move the page it shows.
            .contentShape(.rect)
    }
}
