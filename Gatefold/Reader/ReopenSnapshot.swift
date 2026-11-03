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
        /// The reading view's frame (x, y, width, height): the leaf a turn asked of the picture lifts.
        var navigator: [Double]?
        /// 2 for a spread.
        var columns: Int?

        var navigatorFrame: CGRect? { navigator.flatMap { $0.count == 4 ? CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil } }
        var pageFrame: CGRect? { page.flatMap { $0.count == 4 ? CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil } }
    }

    /// A picture that fits this launch.
    struct Picture {
        let image: UIImage
        let meta: Meta
        /// Made from a picture taken in another paper or window (recoloured, or its page set into this
        /// window): his page, but not pixel for pixel the live one, which fades in over it.
        var adapted = false
    }

    private static var directory: URL {
        URL.cachesDirectory.appending(path: "Reopen", directoryHint: .isDirectory)
    }

    private static func name(book: String, size: CGSize) -> String {
        let safe = book.map { $0.isLetter || $0.isNumber || $0 == "-" ? String($0) : "_" }.joined()
        return "\(safe)-\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
    }

    private static func read(_ base: URL, book: String) -> Picture? {
        guard let data = try? Data(contentsOf: base.appendingPathExtension("json")),
              let meta = try? JSONDecoder().decode(Meta.self, from: data), meta.book == book,
              let file = UIImage(contentsOfFile: base.appendingPathExtension("png").path), let cg = file.cgImage, meta.width > 0 else { return nil }
        // Read from disk a picture has scale 1; it was drawn at the screen's scale.
        return Picture(image: UIImage(cgImage: cg, scale: CGFloat(cg.width) / meta.width, orientation: .up), meta: meta)
    }

    /// The saved picture of `book` for a window of `size` in `theme`. Taken in another paper (the
    /// system turned dark) it is recoloured; taken in a window of another size (the iPad turned, the
    /// Duo opened or closed) its page is set into this one. Only the cover is left when there is none.
    static func load(book: String, size: CGSize, theme: ReaderTheme) -> Picture? {
        let began = Date()
        let exact = read(directory.appending(path: name(book: book, size: size)), book: book)
        if let exact, exact.meta.theme == theme.rawValue { return exact }
        // Leaving keeps one picture per book (`take` empties the others), so any other is his page.
        let found = exact ?? otherSize(book: book, size: size)
        guard let found, let from = ReaderTheme(rawValue: found.meta.theme) else { return nil }
        let sameSize = abs(found.meta.width - size.width) < 1 && abs(found.meta.height - size.height) < 1
        guard let image = adapt(found, to: size, sameSize: sameSize, from: from, to: theme) else { return nil }
        readerLog.notice("reopen: picture adapted from \(Int(found.meta.width), privacy: .public)x\(Int(found.meta.height), privacy: .public) \(from.rawValue, privacy: .public) to \(Int(size.width), privacy: .public)x\(Int(size.height), privacy: .public) \(theme.rawValue, privacy: .public) in \(Date().timeIntervalSince(began), privacy: .public) s")
        var meta = found.meta
        meta.theme = theme.rawValue
        if !sameSize { meta.width = size.width; meta.height = size.height; meta.page = nil; meta.navigator = nil; meta.columns = nil }
        return Picture(image: image, meta: meta, adapted: true)
    }

    private static func otherSize(book: String, size: CGSize) -> Picture? {
        let prefix = name(book: book, size: .zero).replacingOccurrences(of: "-0x0", with: "-")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return files.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".json") }
            .compactMap { read(directory.appending(path: String($0.dropLast(5))), book: book) }
            .max { $0.meta.savedAt < $1.meta.savedAt }
    }

    /// The picture redrawn for this window and paper.
    private static func adapt(_ found: Picture, to size: CGSize, sameSize: Bool, from: ReaderTheme, to theme: ReaderTheme) -> UIImage? {
        var image = found.image
        if !sameSize {
            let source = CGSize(width: found.meta.width, height: found.meta.height)
            let page = found.meta.navigatorFrame ?? found.meta.pageFrame ?? CGRect(origin: .zero, size: source)
            let column = ReopenFit.firstColumn(page: page, columns: found.meta.columns ?? 1)
            let target = ReopenFit.place(column: column, from: source, in: size)
            let scale = image.scale
            guard let cg = image.cgImage?.cropping(to: CGRect(x: column.minX * scale, y: column.minY * scale, width: column.width * scale, height: column.height * scale)) else { return nil }
            let format = UIGraphicsImageRendererFormat.preferred()
            format.opaque = true
            format.scale = scale
            let paper = from.uiBackground
            image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
                paper.setFill()
                ctx.fill(CGRect(origin: .zero, size: size))
                UIImage(cgImage: cg, scale: scale, orientation: .up).draw(in: target)
            }
        }
        return from == theme ? image : recolor(image, from: from.palette, to: theme.palette)
    }

    private static func recolor(_ image: UIImage, from: ThemePalette, to: ThemePalette) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let w = cg.width, h = cg.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let table = PictureRecolor.table(from: from, to: to)
        pixels.withUnsafeMutableBufferPointer { p in
            var i = 0
            while i < p.count {
                let c = table[PictureRecolor.luma(p[i], p[i + 1], p[i + 2])]
                p[i] = c.r; p[i + 1] = c.g; p[i + 2] = c.b
                i += 4
            }
        }
        guard let out = ctx.makeImage() else { return nil }
        return UIImage(cgImage: out, scale: image.scale, orientation: .up)
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
        let nav = host.navigator.view.convert(host.navigator.view.bounds, to: window)
        let meta = Meta(book: model.bookID, width: size.width, height: size.height, theme: model.theme.rawValue, savedAt: Date(),
                        page: [frame.minX, frame.minY, frame.width, frame.height],
                        navigator: [nav.minX, nav.minY, nav.width, nav.height],
                        columns: model.layout.columns == .two ? 2 : 1)
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
                // One picture per book: one kept for another window size is of an older page now.
                let mine = base.lastPathComponent
                let prefix = String(mine[..<(mine.lastIndex(of: "-") ?? mine.endIndex)]) + "-"
                for file in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
                where file.hasPrefix(prefix) && file.hasSuffix(".json") && file != mine + ".json" {
                    try? Data().write(to: directory.appending(path: file))
                }
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
        // The window without the page (paper, head, footer, ribbon). Drawn from the layer tree in this
        // process, with the page's layer hidden only for the drawing and shown again before anything
        // is committed: the screen never sees it hidden. (`drawHierarchy` with screen updates committed
        // the hidden page, which blinked the page blank as he left, or pulled down Control Center.)
        let pageLayer = host.navigator.view.layer
        let overlays = UIGraphicsImageRenderer(bounds: bounds, format: format).image { ctx in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let hidden = pageLayer.isHidden
            pageLayer.isHidden = true
            window.layer.render(in: ctx.cgContext)
            pageLayer.isHidden = hidden
            CATransaction.commit()
        }
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
    /// Where the reading view was when pictured: the leaf a turn lifts. Nil lifts nothing (the turn
    /// still plays when the live page lands).
    var leaf: CGRect? = nil
    var isSpread = false
    var theme: ReaderTheme = .vellum
    /// The lifted leaf, shared with the reader so it can land the turn on the live page.
    var curl: CurlModel? = nil
    /// A turn asked for on the picture (forward or back); returns whether it was kept (only the first is).
    var onTurn: (Bool) -> Bool = { _ in false }
    @State private var width: CGFloat = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image(uiImage: image)
                .resizable()
                .interpolation(.none)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let curl, let leaf, curl.isActive {
                CurlOverlay(model: curl)
                    .frame(width: leaf.width, height: leaf.height)
                    .offset(x: leaf.minX, y: leaf.minY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("reader.reopenPicture")
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // The picture can't turn yet, but it answers the finger at once: the leaf's corner lifts
        // (the same leaf as the live page's), and the turn lands when the live page is up beneath
        // (`ReaderHostController.landLiftedTurn`).
        .contentShape(.rect)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onEnded { value in
                    readerLog.notice("reopen: touch on the picture at x \(Int(value.startLocation.x), privacy: .public) moved \(Int(value.translation.width), privacy: .public),\(Int(value.translation.height), privacy: .public) of width \(Int(width), privacy: .public)")
                    if let forward = ReopenTurn.forward(start: value.startLocation, translation: value.translation, width: width), onTurn(forward) {
                        lift(forward: forward)
                    }
                }
        )
    }

    private func lift(forward: Bool) {
        guard let curl, let leaf, !curl.isActive, leaf.width > 1, leaf.height > 1 else { return }
        let scale = image.scale
        guard let cg = image.cgImage?.cropping(to: CGRect(x: leaf.minX * scale, y: leaf.minY * scale, width: leaf.width * scale, height: leaf.height * scale)) else { return }
        let top = UIImage(cgImage: cg, scale: scale, orientation: .up)
        let size = leaf.size
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            curl.size = size
            curl.style = .curl
            curl.isSpread = isSpread
            curl.mirrored = !forward
            curl.paper = theme.background
            curl.ink = theme.text
            curl.isDark = theme.palette.isDark
            curl.top = top
            // Beneath, for now, the page itself: the corner lifts off a stack of them.
            curl.beneath = top
            curl.fade = 0
            curl.corner = CGPoint(x: forward ? size.width : 0, y: size.height)
            curl.finger = curl.corner
            curl.isActive = true
        }
        let leafWidth = isSpread ? size.width / 2 : size.width
        let lifted = CGPoint(x: forward ? size.width - leafWidth * 0.2 : leafWidth * 0.2, y: size.height - size.height * 0.15)
        Task { @MainActor in
            await Task.yield()
            withAnimation(.easeOut(duration: 0.18)) { curl.finger = lifted }
            readerLog.notice("reopen: lifted the leaf's corner at \(LaunchClock.sinceLaunch, privacy: .public) s after launch")
        }
    }
}

/// Which way a touch on the reopen picture turns, by the live page's rules: a horizontal swipe turns
/// against its direction; a tap in the outer quarter turns that way; anything else turns nothing.
enum ReopenTurn {
    static func forward(start: CGPoint, translation: CGSize, width: CGFloat) -> Bool? {
        if abs(translation.width) > 30, abs(translation.width) > abs(translation.height) {
            return translation.width < 0
        }
        guard abs(translation.width) < 12, abs(translation.height) < 12, width > 0 else { return nil }
        let edge = width * 0.25
        if start.x < edge { return false }
        if start.x > width - edge { return true }
        return nil
    }
}
