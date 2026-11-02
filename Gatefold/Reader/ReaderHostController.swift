import GatefoldCore
import ReadiumNavigator
import ReadiumShared
import SwiftUI
import UIKit
import WebKit
import os

let readerLog = Logger(subsystem: "bot.ouro.gatefold", category: "reader")

/// Hosts Readium's EPUB navigator. Owns page turns (curl, slide, fade, scroll), tap zones and the
/// reading anchor's restore after every reflow. Everything else in the reader is SwiftUI.
@MainActor
final class ReaderHostController: UIViewController, EPUBNavigatorDelegate, UIGestureRecognizerDelegate, ReaderPage {
    let navigator: EPUBNavigatorViewController
    var currentLocation: Locator? { navigator.currentLocation }
    private(set) weak var weakModel: ReaderModel?
    /// The reader outlives this controller in every path but a mid-turn close; callers in tasks guard `weakModel`.
    private var model: ReaderModel { weakModel! }
    private let curl = CurlModel()
    private lazy var curlHost = UIHostingController(rootView: CurlOverlay(model: curl))
    private var observers: [Any] = []

    private var lastSize: CGSize = .zero
    private var reflowTask: Task<Void, Never>?
    private var reflowGeneration = 0
    /// The old page, held over the web view while it repaginates, so a reflow never shows bare paper.
    private var reflowCover: UIView?
    /// Set while a reflow from one page to a spread is the unfold.
    private var unfolding = false
    /// True from the moment a turn begins until it lands or springs back.
    private(set) var isTurning = false
    private var panStart: CGPoint = .zero
    private var panForward = true
    /// Set when the pan ends before the turn is ready; the preparing task finishes with it.
    private var panEnded: Bool?
    private var columns = 1

    init(model: ReaderModel, publication: Publication, initialLocation: Locator?, preferences: EPUBPreferences) throws {
        self.weakModel = model
        navigator = try EPUBNavigatorViewController(
            publication: publication,
            initialLocation: initialLocation,
            config: .init(
                preferences: preferences,
                editingActions: Self.highlightEditingActions,
                contentInset: [.compact: (top: 28, bottom: 28), .regular: (top: 44, bottom: 44)],
                // Readium shows and reports the first page only once every preloaded neighbour has loaded
                // too: 2 behind and 4 ahead held the cover up for three to six seconds. Neighbours load on
                // demand; a turn into a chapter still loading holds the old page (`renderedSnapshot`).
                preloadPreviousPositionCount: 0,
                preloadNextPositionCount: 0,
                decorationTemplates: HTMLDecorationTemplate.defaultTemplates().merging([.gatefoldSync: .gatefoldSync()]) { a, _ in a }
                    .merging(Self.highlightTemplates) { a, _ in a }
            )
        )
        super.init(nibName: nil, bundle: nil)
        navigator.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        if let model = weakModel { readerLog.notice("open: host loads after \(Date().timeIntervalSince(model.openedAt), privacy: .public) s") }
        if LaunchOptions.isUITest || LaunchOptions.openTour != nil { traceWebViews() }
        view.clipsToBounds = true
        addChild(navigator)
        navigator.view.frame = view.bounds
        navigator.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(navigator.view)
        navigator.didMove(toParent: self)

        // Any touch on the page means the next location is the reader's own (slide and scroll swipes
        // belong to Readium, so they're noticed here rather than in the pan handler).
        let noticer = TouchNoticer { [weak self] in
            // Web views loaded since the last location change bring their own scroll pans; switch them
            // off before this touch can drag the page sideways under the curl.
            self?.disablePanningIfNeeded()
            self?.weakModel?.noteInteraction()
        }
        noticer.delegate = self
        navigator.view.addGestureRecognizer(noticer)

        addChild(curlHost)
        curlHost.view.backgroundColor = .clear
        curlHost.view.frame = view.bounds
        curlHost.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        curlHost.view.isUserInteractionEnabled = false
        curlHost.sizingOptions = []
        // The overlay must sit exactly over the page. With safe-area insets (the folded Duo's camera
        // column) SwiftUI centred it in the narrower safe area, so the lifted page drew shifted.
        curlHost.safeAreaRegions = []
        view.addSubview(curlHost.view)
        curlHost.didMove(toParent: self)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)

        observers.append(navigator.addObserver(.tap { [weak self] event in
            self?.handleTap(at: event.location) ?? false
        }))
        observers.append(navigator.addObserver(.key(.arrowRight) { [weak self] in self?.turn(forward: true) ?? false }))
        observers.append(navigator.addObserver(.key(.arrowLeft) { [weak self] in self?.turn(forward: false) ?? false }))
        observers.append(navigator.addObserver(.key(.space) { [weak self] in self?.turn(forward: true) ?? false }))
        model.host = self
    }

    /// For measuring opens: when the first web view appears, starts loading and finishes, after the host loads.
    private func traceWebViews() {
        let start = Date()
        Task { [weak self] in
            var seen = false, loading = false
            for _ in 0..<300 {
                guard let self, let web = Self.firstWebView(in: self.navigator.view) else {
                    try? await Task.sleep(for: .milliseconds(20)); continue
                }
                let t = Date().timeIntervalSince(start)
                if !seen { seen = true; readerLog.notice("open: web view made after \(t, privacy: .public) s") }
                if web.isLoading, !loading { loading = true; readerLog.notice("open: web view loading after \(t, privacy: .public) s") }
                if loading, !web.isLoading { readerLog.notice("open: web view loaded after \(t, privacy: .public) s"); return }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    private static func firstWebView(in view: UIView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        for sub in view.subviews { if let web = firstWebView(in: sub) { return web } }
        return nil
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = view.bounds.size
        guard size != lastSize, size.width > 0 else { return }
        readerLog.notice("host size \(size.width, privacy: .public)x\(size.height, privacy: .public)")
        let first = lastSize == .zero
        lastSize = size
        if !first { beginReflow(model.consumeReflowReason() ?? .resize) }
    }

    // MARK: Preferences

    func apply(_ preferences: EPUBPreferences, columns: Int, reflow: Bool) {
        // One page becoming two is the unfold: the right page swings open once it has laid out.
        unfolding = reflow && self.columns == 1 && columns == 2
        self.columns = columns
        if reflow { beginReflow(model.consumeReflowReason() ?? .typography) }
        navigator.submitPreferences(preferences)
        if reflow { settleReflowSoon() }
        Task {
            if columns == 1 { _ = await navigator.evaluateJavaScript(ReaderJS.removeVerso) }
            _ = await navigator.evaluateJavaScript(ReaderJS.setColumns(columns))
            if reflow, model.pageReady {
                try? await Task.sleep(for: .seconds(1))
                await logTypography()
            }
        }
    }

    // MARK: Reflow and the reading anchor

    private func beginReflow(_ reason: ReflowReason) {
        readerLog.notice("reflow begins: \(String(describing: reason), privacy: .public)")
        model.keeper.reflowWillBegin(reason)
        model.reflowDidBegin()
        if !curl.isActive {
            let page = navigator.view!
            if reflowCover == nil, page.alpha > 0.5, let container = page.superview,
               let cover = page.snapshotView(afterScreenUpdates: false) {
                cover.frame = page.frame
                cover.isUserInteractionEnabled = false
                container.insertSubview(cover, aboveSubview: page)
                reflowCover = cover
            } else if reflowCover == nil, let container = page.superview, let held = heldCover(frame: page.frame) {
                // The old page's view is gone (the app changed screens): the picture held as the hinge moved stands in.
                container.insertSubview(held, aboveSubview: page)
                reflowCover = held
            }
            if reflowCover != nil {
                page.alpha = 0
            } else {
                UIView.animate(withDuration: 0.12) { page.alpha = 0 }
            }
        }
        settleReflowSoon()
    }

    private func settleReflowSoon() {
        reflowTask?.cancel()
        reflowGeneration += 1
        let generation = reflowGeneration
        reflowTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(550))
            guard !Task.isCancelled, let self, self.weakModel != nil else { return }
            await self.restoreAnchor(generation: generation)
        }
    }

    private func restoreAnchor(generation: Int) async {
        // A newer reflow may begin during any await below; it owns the restore from then on.
        func current() -> Bool { generation == reflowGeneration && weakModel != nil }
        _ = await navigator.evaluateJavaScript(ReaderJS.install)
        _ = await navigator.evaluateJavaScript(ReaderJS.setColumns(columns))
        guard current() else { return }
        // A slow device may still be paginating: judge the page only once it shows text. Each
        // phase has its own budget, because a picture-only page never shows text.
        func laidOutRange(within budget: Duration) async -> VisibleRange? {
            let deadline = ContinuousClock.now + budget
            var range = await visibleRange()
            while let r = range, r.text == nil, ContinuousClock.now < deadline,
                  !Task.isCancelled, current() {
                try? await Task.sleep(for: .milliseconds(250))
                range = await visibleRange()
            }
            return range
        }
        let visible = await laidOutRange(within: .seconds(3))
        guard current() else { return }
        var after = visible
        let action = visible.map { model.keeper.reflowDidSettle(visible: $0) } ?? RestoreAction.none
        let held = model.keeper.anchor
        if case let .jump(anchor) = action,
           let locator = model.locator(for: anchor) {
            // A jump made while the book is still settling can land short of the place; try again.
            let jumpBudget = ContinuousClock.now + .seconds(4)
            for _ in 0..<3 {
                _ = await navigator.go(to: locator, options: .init(animated: false))
                try? await Task.sleep(for: .milliseconds(160))
                guard current(), !Task.isCancelled else { return }
                after = await laidOutRange(within: max(.zero, jumpBudget - ContinuousClock.now))
                guard current() else { return }
                if after?.contains(anchor) == true || ContinuousClock.now >= jumpBudget { break }
            }
        }
        // A spread keeps the reader's sentence on its left page, the page he was on.
        var target: ReadingAnchor? = held
        if case let .jump(anchor) = action { target = anchor }
        if columns == 2, let target, let moved = await keepOnLeft(target, current: current) { after = moved }
        guard current() else { return }
        model.keeper.restoreDidComplete()
        model.reflowDidFinish(visible: after)
        disablePanningIfNeeded()
        var cover = reflowCover
        reflowCover = nil
        if unfolding, columns == 2 {
            unfolding = false
            // The swing starts from the page the reader was on, whichever screen it was drawn on.
            let choice = UnfoldCover.choose(held: model.heldPage, liveAvailable: cover != nil, book: model.bookID, now: Date())
            if choice == .held, cover?.tag != Self.heldTag, let container = navigator.view.superview,
               let held = heldCover(frame: navigator.view.frame) {
                container.insertSubview(held, aboveSubview: cover ?? navigator.view)
                cover?.removeFromSuperview()
                cover = held
            }
            if choice == .none { cover?.removeFromSuperview(); cover = nil }
            model.heldPicture = nil
            model.heldPage = nil
            readerLog.notice("unfold: from \(choice == .held ? "the picture held as the hinge moved" : choice == .live ? "the live page" : "nothing (a plain reflow)", privacy: .public)")
            await swingOpen(cover: cover)
            return
        }
        unfolding = false
        UIView.animate(withDuration: 0.25) {
            self.navigator.view.alpha = 1
            cover?.alpha = 0
        } completion: { _ in cover?.removeFromSuperview() }
    }

    /// Moves the spread so `anchor`'s words start its left page: a blank verso before the file's first
    /// page shifts every page one side over. Returns what's on screen after a move, nil when none was needed.
    private func keepOnLeft(_ anchor: ReadingAnchor, current: () -> Bool) async -> VisibleRange? {
        guard let text = anchor.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        func side() async -> Int? {
            ((try? await navigator.evaluateJavaScript(ReaderJS.sideOf(text)).get()) as? NSNumber)?.intValue
        }
        // A jump can land one spread past the words: a word hyphenated across pages leaves the
        // sentence's first letters on the spread before. Step to the spread where it starts.
        var now = await side()
        readerLog.notice("spread: the sentence starts on side \(now.map(String.init) ?? "nil", privacy: .public)")
        var stepped = false
        if now == -1 || now == 2 {
            if now == -1 { _ = await navigator.goBackward(options: .init(animated: false)) }
            else { _ = await navigator.goForward(options: .init(animated: false)) }
            try? await Task.sleep(for: .milliseconds(120))
            guard current() else { return nil }
            stepped = true
            now = await side()
        }
        // Start a fresh column at the reader's words, so they open a page instead of sitting mid-way
        // down it; the column count shifts, so find the words' spread again.
        var pinned = false
        if now == 0 || now == 1,
           ((try? await navigator.evaluateJavaScript(ReaderJS.pinToTop(text)).get()) as? NSNumber)?.intValue == 1 {
            pinned = true
            try? await Task.sleep(for: .milliseconds(120))
            guard current(), let locator = model.locator(for: anchor) else { return nil }
            _ = await navigator.go(to: locator, options: .init(animated: false))
            try? await Task.sleep(for: .milliseconds(160))
            for _ in 0..<2 {
                guard current() else { return nil }
                switch await side() {
                case 2: _ = await navigator.goForward(options: .init(animated: false))
                case -1: _ = await navigator.goBackward(options: .init(animated: false))
                default: break
                }
                try? await Task.sleep(for: .milliseconds(120))
            }
            now = await side()
            readerLog.notice("spread: a new column starts at the sentence; it is on side \(now.map(String.init) ?? "nil", privacy: .public)")
        }
        guard now == 1 else { return stepped || pinned ? await visibleRange() : nil }
        _ = await navigator.evaluateJavaScript(ReaderJS.toggleVerso)
        try? await Task.sleep(for: .milliseconds(120))
        guard current(), let locator = model.locator(for: anchor) else { return nil }
        _ = await navigator.go(to: locator, options: .init(animated: false))
        try? await Task.sleep(for: .milliseconds(160))
        // The progression moved with the verso; step to the spread that holds the words.
        for _ in 0..<2 {
            guard current() else { return nil }
            switch await side() {
            case 2: _ = await navigator.goForward(options: .init(animated: false))
            case -1: _ = await navigator.goBackward(options: .init(animated: false))
            default: break
            }
            try? await Task.sleep(for: .milliseconds(120))
        }
        now = await side()
        readerLog.notice("spread: sentence on the \(now == 0 ? "left" : now == 1 ? "right" : "other", privacy: .public) page after the verso")
        return await visibleRange()
    }

    private static let heldTag = 0x6A7E
    private var holding = false

    /// Takes a picture of the page as it is now, for the unfold to swing from. Called when the hinge
    /// starts to move, before a Duo moves the app from its cover screen to the inner screen.
    func holdPageForUnfold() {
        Task { await holdPage() }
    }

    /// Takes the picture and returns once it is held (or dropped), so a caller can let the hinge move only after.
    func holdPage() async {
        guard columns == 1, !holding, let model = weakModel, model.pageReady, navigator.view.window != nil else { return }
        let reflowing = reflowCover != nil || navigator.view.alpha < 0.5
        let reflowsAtStart = reflowGeneration
        holding = true
        defer { holding = false }
        let picture = await snapshot()
        // A reflow redraws the page underneath; a picture taken across one would swing from a half-laid-out page.
        guard UnfoldCover.pictureIsThePage(reflowingAtStart: reflowing, reflowsAtStart: reflowsAtStart, reflowsAtEnd: reflowGeneration) else {
            readerLog.notice("unfold: a reflow was under way; no new picture taken")
            return
        }
        model.heldPicture = picture
        model.heldPage = HeldPage(book: model.bookID, takenAt: Date())
        readerLog.notice("unfold: held a picture of the page (\(picture.size.width, privacy: .public)x\(picture.size.height, privacy: .public))")
    }

    /// The held picture over paper, set where the left page will be; nil when none is fresh.
    private func heldCover(frame: CGRect) -> UIView? {
        guard let model = weakModel, let picture = model.heldPicture,
              UnfoldCover.choose(held: model.heldPage, liveAvailable: false, book: model.bookID, now: Date()) == .held else { return nil }
        let cover = UIView(frame: frame)
        cover.backgroundColor = model.theme.uiBackground
        cover.isUserInteractionEnabled = false
        cover.tag = Self.heldTag
        let image = UIImageView(image: picture)
        image.frame = UnfoldCover.heldFrame(picture: picture.size, in: CGRect(origin: .zero, size: frame.size))
        cover.addSubview(image)
        return cover
    }

    /// The unfold: the spread has laid out behind the old page. The left page takes the old page's
    /// place; the right page, a picture of the real one, swings open from the spine, its shadow
    /// lifting as it lies flat; then the live page is shown, pixel for pixel the same.
    private func swingOpen(cover: UIView?) async {
        let page = navigator.view!
        guard let container = page.superview else {
            page.alpha = 1
            cover?.removeFromSuperview()
            return
        }
        let image = await snapshot()
        let frame = page.frame
        let spine: CGFloat = {
            guard let model = weakModel, let gutter = model.layout.gutter else { return frame.width / 2 }
            return min(frame.width, max(0, gutter.midX - model.layout.pageFrame.minX))
        }()
        let paper = weakModel?.theme.uiBackground ?? .systemBackground
        func half(_ x: CGFloat, _ w: CGFloat) -> UIView {
            let v = UIView(frame: CGRect(x: frame.minX + x, y: frame.minY, width: w, height: frame.height))
            v.backgroundColor = paper
            v.layer.contents = image.cgImage
            v.layer.contentsScale = image.scale
            v.layer.contentsRect = CGRect(x: x / frame.width, y: 0, width: w / frame.width, height: 1)
            v.isUserInteractionEnabled = false
            return v
        }
        let left = half(0, spine)
        let right = half(spine, frame.width - spine)
        // The leaf's shade: deepest at the spine while it stands up, gone once it lies flat.
        let shade = CAGradientLayer()
        shade.frame = right.bounds
        shade.startPoint = CGPoint(x: 0, y: 0.5)
        shade.endPoint = CGPoint(x: 1, y: 0.5)
        let dark = weakModel?.theme.palette.isDark ?? false
        shade.colors = [UIColor.black.withAlphaComponent(dark ? 0.55 : 0.30).cgColor, UIColor.black.withAlphaComponent(dark ? 0.25 : 0.08).cgColor]
        right.layer.addSublayer(shade)
        left.alpha = 0
        if let cover {
            // The left page comes up through the old one; the leaf rises over it from the spine, so the
            // old page giving way and the leaf opening read as one gesture, with no bare half between.
            container.insertSubview(left, belowSubview: cover)
            container.insertSubview(right, aboveSubview: cover)
        } else {
            container.insertSubview(left, aboveSubview: page)
            container.insertSubview(right, aboveSubview: page)
        }
        let reduce = weakModel?.reduceMotion ?? false
        readerLog.notice("unfold: the right page swings open (reduce motion \(reduce, privacy: .public))")
        // The old page gives way to the new left page through paper, never through each other.
        let out = UIViewPropertyAnimator(duration: 0.12, curve: .easeIn) { cover?.alpha = 0 }
        let into = UIViewPropertyAnimator(duration: 0.16, curve: .easeOut) { left.alpha = 1 }
        out.addCompletion { _ in cover?.removeFromSuperview() }
        out.startAnimation()
        into.startAnimation(afterDelay: 0.1)
        if reduce {
            right.alpha = 0
            shade.opacity = 0
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                UIView.animate(withDuration: 0.25, delay: 0.1, options: .curveEaseOut) { right.alpha = 1 } completion: { _ in c.resume() }
            }
        } else {
            right.layer.anchorPoint = CGPoint(x: 0, y: 0.5)
            right.layer.position = CGPoint(x: frame.minX + spine, y: frame.midY)
            var start = CATransform3DIdentity
            start.m34 = -1 / max(600, frame.width * 1.2)
            right.layer.transform = CATransform3DRotate(start, -.pi * 0.47, 0, 1, 0)
            var flat = CATransform3DIdentity
            flat.m34 = start.m34
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = 0.8
            fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
            fade.fillMode = .both
            fade.isRemovedOnCompletion = false
            // Edge-on at first, the leaf rises as the old page starts to go.
            right.isHidden = true
            try? await Task.sleep(for: .milliseconds(60))
            right.isHidden = false
            fade.beginTime = CACurrentMediaTime()
            shade.add(fade, forKey: "lift")
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                UIView.animate(withDuration: 0.85, delay: 0, usingSpringWithDamping: 0.95, initialSpringVelocity: 0) {
                    right.layer.transform = flat
                } completion: { _ in c.resume() }
            }
        }
        page.alpha = 1
        left.removeFromSuperview()
        right.removeFromSuperview()
        cover?.removeFromSuperview()
    }

    /// What's on screen now: the resource, its progression range and the visible text.
    func visibleRange() async -> VisibleRange? {
        guard let location = navigator.currentLocation else { return nil }
        _ = await navigator.evaluateJavaScript(ReaderJS.install)
        let text = (try? await navigator.evaluateJavaScript(ReaderJS.visibleText).get()) as? String
        let start = location.locations.progression ?? 0
        let end = (try? await navigator.evaluateJavaScript(ReaderJS.pageEnd).get()) as? Double
        return VisibleRange(href: location.href.string, start: start, end: max(start, min(1, end ?? start + 0.0001)), text: text)
    }

    /// Where `quote` is in the resource on screen, as a progression; nil when it isn't there.
    func progression(of quote: String) async -> Double? {
        _ = await navigator.evaluateJavaScript(ReaderJS.install)
        return (try? await navigator.evaluateJavaScript(ReaderJS.progressionOf(quote)).get()) as? Double
    }

    /// The first words on the page the reader is on.
    func currentAnchor() async -> (ReadingAnchor, Locator)? {
        guard let location = navigator.currentLocation else { return nil }
        _ = await navigator.evaluateJavaScript(ReaderJS.install)
        let anchors = weakModel?.contents.fragments(in: location.href.string) ?? []
        let json = (try? await navigator.evaluateJavaScript(ReaderJS.anchor(column: 0, contentsAnchors: anchors)).get()) as? String
        struct Found: Decodable { var highlight: String; var before: String?; var heading: String?; var contents: String? }
        let found = json.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(Found.self, from: $0) }
        weakModel?.heading = found?.heading.map(ReaderJS.tidyHeading)
        weakModel?.contentsFragment = found?.contents
        let anchor = ReadingAnchor(
            href: location.href.string,
            progression: location.locations.progression ?? 0,
            text: found.map { ReaderJS.normalize($0.highlight) }
        )
        let locator = location.copy(text: {
            $0 = Locator.Text(after: nil, before: found?.before, highlight: found?.highlight)
        })
        return (anchor, locator)
    }

    // MARK: EPUBNavigatorDelegate

    /// A link in the book (a contents page, a cross-reference) jumps like the contents sheet does:
    /// the old page stays, dimmed, until the new one has loaded, and Back returns.
    func navigator(_ navigator: VisualNavigator, shouldNavigateToLink link: ReadiumShared.Link) -> Bool {
        guard let model = weakModel else { return true }
        Task { await model.follow(link) }
        return false
    }

    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        guard let model = weakModel else { return }
        if model.location == nil { readerLog.notice("open: navigator reports a place after \(Date().timeIntervalSince(model.openedAt), privacy: .public) s") }
        disablePanningIfNeeded()
        Task { await model.locationDidChange(locator, duringTurn: isTurning) }
    }

    func navigator(_ navigator: Navigator, presentError error: NavigatorError) {
        model.errorMessage = error.localizedDescription
    }

    func navigator(_ navigator: Navigator, didFailToLoadResourceAt href: RelativeURL, withError error: ReadError) {
        model.errorMessage = "Part of this book couldn't be loaded."
    }

    // MARK: Taps

    private func handleTap(at point: CGPoint) -> Bool {
        let width = navigator.view.bounds.width
        let edge = width * 0.25
        if model.chromeVisible {
            model.setChrome(false)
            return true
        }
        if model.pageTurn == .scroll {
            model.setChrome(true)
            return true
        }
        if point.x < edge {
            turn(forward: false)
        } else if point.x > width - edge {
            turn(forward: true)
        } else {
            model.setChrome(true)
        }
        return true
    }

    // MARK: Turning

    @discardableResult
    func turn(forward: Bool) -> Bool {
        guard !isTurning else { return true }
        switch model.pageTurn {
        case .scroll:
            return false
        case .slide:
            isTurning = true
            Task {
                let moved = forward ? await navigator.goForward(options: .init(animated: true)) : await navigator.goBackward(options: .init(animated: true))
                isTurning = false
                if moved { weakModel?.userTurnedPage() } else if forward { weakModel?.reachedEnd() }
            }
        case .curl, .fade:
            Task { await animatedTurn(forward: forward, from: nil) }
        }
        return true
    }

    /// A whole turn without a finger: lift from the lower corner and sweep across.
    private func animatedTurn(forward: Bool, from finger: CGPoint?) async {
        guard await prepareTurn(forward: forward, startingAt: finger ?? CGPoint(x: view.bounds.width, y: view.bounds.height * 0.86)) else { return }
        // The same leaf as a drag: the corner lifts up and in first, so the page bends as a cylinder
        // rather than folding along a flat vertical strip, then sweeps over.
        if curl.style == .curl, !(weakModel?.reduceMotion ?? false) {
            let w = curl.size.width, h = curl.size.height
            let lift = CGPoint(x: forward ? w * 0.80 : w * 0.20, y: h * 0.80)
            withAnimation(.easeOut(duration: 0.12)) { curl.finger = lift }
            try? await Task.sleep(for: .milliseconds(120))
        }
        await finish(complete: true, velocity: 0)
    }

    /// Snapshots the current page, moves the navigator underneath the overlay and snapshots the
    /// destination. Returns false at the start or end of the book.
    private func prepareTurn(forward: Bool, startingAt point: CGPoint) async -> Bool {
        guard !isTurning, weakModel != nil else { return false }
        isTurning = true
        let size = navigator.view.bounds.size
        // The page on screen now; a black or bare capture (seen in spreads) is retried.
        let top = await renderedSnapshot(afterChange: false)
        curl.size = size
        curl.style = model.pageTurn == .fade ? .fade : .curl
        curl.isSpread = model.layout.posture == .spread
        curl.mirrored = !forward
        curl.paper = model.theme.background
        curl.ink = model.theme.text
        curl.isDark = model.theme.palette.isDark
        curl.top = top
        curl.beneath = nil
        curl.fade = 0
        let cornerY: CGFloat = point.y > size.height / 2 ? size.height : 0
        // The corner is always on the leaf's outer edge (mirrored when turning back).
        curl.corner = CGPoint(x: forward ? size.width : 0, y: cornerY)
        curl.finger = curl.corner
        curl.isActive = true
        await nextFrame()

        let moved = forward
            ? await navigator.goForward(options: .init(animated: false))
            : await navigator.goBackward(options: .init(animated: false))
        readerLog.notice("turn moved=\(moved, privacy: .public)")
        guard moved, weakModel != nil else {
            curl.reset()
            isTurning = false
            // Past the last page there is no page: there is the end leaf.
            if forward, let model = weakModel { model.reachedEnd() } else {
                UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.4)
            }
            return false
        }
        // Wait until the destination has painted and stopped changing (a spread lays out two
        // columns; caught halfway it ghosts).
        curl.beneath = await renderedSnapshot(afterChange: true)
        #if DEBUG
        if ProcessInfo.processInfo.environment["GATEFOLD_DUMP_SNAPSHOTS"] != nil || UserDefaults.standard.bool(forKey: "GatefoldDumpSnapshots") {
            let dir = URL.temporaryDirectory
            let stamp = Int(Date().timeIntervalSince1970 * 1000)
            try? top.pngData()?.write(to: dir.appending(path: "snap-\(stamp)-top.png"))
            try? curl.beneath?.pngData()?.write(to: dir.appending(path: "snap-\(stamp)-beneath.png"))
        }
        #endif
        return true
    }

    private func finish(complete: Bool, velocity: CGFloat) async {
        let duration = complete ? 0.48 : 0.3
        if curl.style == .fade {
            withAnimation(.easeInOut(duration: 0.22)) { curl.fade = complete ? 1 : 0 }
            try? await Task.sleep(for: .milliseconds(240))
        } else {
            let target = complete ? turnedTarget() : curl.corner
            withAnimation(.timingCurve(0.3, 0.1, 0.25, 1, duration: duration)) { curl.finger = target }
            try? await Task.sleep(for: .seconds(duration + 0.02))
        }
        if !complete {
            // Put the navigator back where it was before lifting the overlay.
            _ = curl.mirrored
                ? await navigator.goForward(options: .init(animated: false))
                : await navigator.goBackward(options: .init(animated: false))
            try? await Task.sleep(for: .milliseconds(120))
        }
        curl.reset()
        isTurning = false
        // Record the place once the turn has landed, not while the overlay hid it. A turn that sprang
        // back is no move: just take the anchor again from the page that's showing.
        if complete {
            weakModel?.userTurnedPage()
        } else if let model = weakModel {
            Task { await model.captureAnchor() }
        }
    }

    private func turnedTarget() -> CGPoint {
        let t = curl.turnedFinger
        return curl.mirrored ? CGPoint(x: curl.size.width - t.x, y: t.y) : t
    }

    // MARK: Pan

    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        guard let model = weakModel else { return }
        guard model.pageTurn == .curl || model.pageTurn == .fade else { return }
        let point = pan.location(in: view)
        switch pan.state {
        case .began:
            let v = pan.velocity(in: view)
            panForward = v.x < 0
            panStart = point
            if model.chromeVisible { model.setChrome(false) }
            panEnded = nil
            Task {
                guard await prepareTurn(forward: panForward, startingAt: point) else { return }
                updateFinger(pan.location(in: view))
                // The finger lifted while the destination was still being prepared.
                if let ended = panEnded { await finish(complete: ended, velocity: 0) }
            }
        case .changed:
            updateFinger(point)
        case .ended, .cancelled:
            let v = pan.velocity(in: view).x
            let dx = point.x - panStart.x
            let width = view.bounds.width
            let complete: Bool
            if pan.state == .cancelled {
                complete = false
            } else if panForward {
                complete = v < -250 || (v < 250 && dx < -width * 0.25)
            } else {
                complete = v > 250 || (v > -250 && dx > width * 0.25)
            }
            guard curl.isActive, curl.top != nil, curl.beneath != nil else {
                panEnded = complete
                return
            }
            Task { await finish(complete: complete, velocity: v) }
        default:
            break
        }
    }

    private func updateFinger(_ point: CGPoint) {
        guard curl.isActive, curl.style == .curl else {
            if curl.isActive, curl.style == .fade {
                curl.fade = min(1, abs(point.x - panStart.x) / max(1, view.bounds.width * 0.5))
            }
            return
        }
        let delta = CGPoint(x: point.x - panStart.x, y: point.y - panStart.y)
        // The corner follows the finger; a little vertical travel tilts the fold like paper.
        curl.finger = CGPoint(x: curl.corner.x + delta.x, y: curl.corner.y + delta.y * 0.6 - (curl.corner.y > 0 ? min(40, abs(delta.x) * 0.08) : -min(40, abs(delta.x) * 0.08)))
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer is TouchNoticer { return true }
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        guard model.pageTurn == .curl || model.pageTurn == .fade, !isTurning else { return false }
        let v = pan.velocity(in: view)
        return abs(v.x) > abs(v.y) * 1.2
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // A curl owns the swipe: a scroll view moving the page at the same time shifts what lifts.
        if gestureRecognizer is UIPanGestureRecognizer, other.view is UIScrollView,
           let model = weakModel, model.pageTurn == .curl || model.pageTurn == .fade {
            return false
        }
        return true
    }

    /// In curl and fade modes the page must not also slide under the finger.
    func disablePanningIfNeeded() {
        let ownsSwipes = model.pageTurn == .curl || model.pageTurn == .fade
        func walk(_ v: UIView) {
            if let scroll = v as? UIScrollView {
                scroll.panGestureRecognizer.isEnabled = !ownsSwipes
            }
            v.subviews.forEach(walk)
        }
        walk(navigator.view)
    }

    // MARK: Jumps

    @discardableResult
    func go(to locator: Locator) async -> Bool {
        await navigator.go(to: locator, options: .init(animated: false))
    }

    func go(to link: ReadiumShared.Link) async {
        _ = await navigator.go(to: link, options: .init(animated: false))
    }

    // MARK: Jumps

    private var veil: UIView?

    /// Runs a jump with the old page left on screen, dimmed to 60 %, until the new page has painted;
    /// then the old page cross-fades away over 0.2 s (no blank page, no spinner). With `riffle`, a few
    /// leaves flick past first.
    func veiledJump(riffle: Bool, forward: Bool, _ body: @escaping () async -> Void) async {
        guard veil == nil, !isTurning, view.window != nil else { return await body() }
        let old = await renderedSnapshot(afterChange: false)
        // The old page, opaque, with a wash of paper over it: it reads as dimmed to 60 %, and nothing
        // of the new page shows through until the cross-fade.
        let cover = UIView(frame: navigator.view.frame)
        cover.isUserInteractionEnabled = false
        let image = UIImageView(image: old)
        image.frame = cover.bounds
        image.backgroundColor = weakModel?.theme.uiBackground
        let wash = UIView(frame: cover.bounds)
        wash.backgroundColor = weakModel?.theme.uiBackground
        wash.alpha = 0
        cover.addSubview(image)
        cover.addSubview(wash)
        view.insertSubview(cover, belowSubview: curlHost.view)
        veil = cover
        if riffle {
            // The thumb starts riffling at once and keeps going while the far chapter loads, so the
            // wait is the riffle, never a dimmed page.
            var arrived = false
            let travel = Task { @MainActor in
                await body()
                arrived = true
            }
            await riffleLeaves(from: old, forward: forward, arrived: { arrived }) { [weak self] in
                await travel.value
                return await self?.renderedSnapshot(afterChange: true) ?? old
            }
            cover.removeFromSuperview()
            veil = nil
            return
        }
        let dim = UIViewPropertyAnimator(duration: 0.15, curve: .easeOut) { wash.alpha = 0.4 }
        dim.startAnimation()
        await body()
        _ = await renderedSnapshot(afterChange: true)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) {
                cover.alpha = 0
            } completion: { _ in done.resume() }
        }
        cover.removeFromSuperview()
        veil = nil
    }

    /// Fast leaves curl away, like a thumb riffling to a place: at least three, more while the far
    /// page is still on its way, and the last one uncovers it.
    private func riffleLeaves(from old: UIImage, forward: Bool, arrived: @escaping () -> Bool, fresh: @escaping () async -> UIImage) async {
        guard let model = weakModel else { return }
        isTurning = true
        defer { isTurning = false }
        let size = navigator.view.bounds.size
        curl.size = size
        curl.style = .curl
        curl.isSpread = model.layout.posture == .spread
        curl.mirrored = !forward
        curl.paper = model.theme.background
        curl.ink = model.theme.text
        curl.isDark = model.theme.palette.isDark
        var i = 0
        // Leaves of the old page over itself until the new one is ready (a riffle through pages
        // in between); capped so a lost load still ends.
        while i < 3 || (!arrived() && i < 40) {
            await leaf(top: old, beneath: old, index: i, size: size, forward: forward, duration: 0.12)
            i += 1
        }
        let page = await fresh()
        await leaf(top: old, beneath: page, index: i, size: size, forward: forward, duration: 0.28)
        veil?.alpha = 0
        curl.reset()
    }

    private func leaf(top: UIImage, beneath: UIImage, index: Int, size: CGSize, forward: Bool, duration: Double) async {
        curl.top = top
        curl.beneath = beneath
        let y = size.height * (0.92 - CGFloat(index % 5) * 0.06)
        let corner = CGPoint(x: forward ? size.width : 0, y: size.height)
        let leafWidth = curl.isSpread ? size.width / 2 : size.width
        // The leaf lifts from its corner on a diagonal, then turns. Starting with the finger straight
        // above the corner put the fold line flat across the page: a full-width grey band over a line.
        // The jump back to the corner is never animated (an interpolated jump drew that band too).
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            curl.corner = corner
            curl.finger = corner
            curl.isActive = true
        }
        await nextFrame()
        let lift = CGPoint(x: forward ? corner.x - leafWidth * 0.45 : corner.x + leafWidth * 0.45, y: y)
        withAnimation(.easeIn(duration: duration * 0.4)) { curl.finger = lift }
        try? await Task.sleep(for: .seconds(duration * 0.4))
        withAnimation(.linear(duration: duration * 0.6)) { curl.finger = turnedTarget() }
        try? await Task.sleep(for: .seconds(duration * 0.6 + 0.02))
        // Turned away: nothing drawn until the next leaf lifts, so no in-between frame shows a band.
        withTransaction(still) { curl.isActive = false }
    }

    /// Underlines the other device's words with the ribbon colour: drawn in over 0.6 s, gone after 2.
    func underline(_ locator: Locator, color: UInt32) {
        guard let quote = locator.text.highlight, !quote.isEmpty else { return }
        // The mark ends where a word does, not where the quote's character count did.
        let edge = WordEdge.complete(highlight: quote, after: locator.text.after)
        let locator = locator.copy(text: { $0.highlight = edge.highlight; $0.after = edge.after })
        let decoration = Decoration(id: "sync", locator: locator, style: .init(id: .gatefoldSync, config: ThemePalette.hexString(color)))
        navigator.apply(decorations: [decoration], in: "gatefold-sync")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.navigator.apply(decorations: [], in: "gatefold-sync")
        }
    }

    // MARK: Helpers

    /// The page's typography as WebKit set it: its language (hyphenation needs one), whether it
    /// hyphenates, and about how many characters a line holds. Logged once per open, for evidence.
    func logTypography() async {
        let js = """
        (function(){var p=[].slice.call(document.querySelectorAll('p')).find(function(e){return (e.innerText||'').length>200});
        if(!p)return 'no paragraph';var cs=getComputedStyle(p);var c=document.createElement('canvas').getContext('2d');
        c.font=cs.fontStyle+' '+cs.fontWeight+' '+cs.fontSize+' '+cs.fontFamily;var t=p.innerText;var avg=c.measureText(t).width/t.length;
        var w=Math.min.apply(null,[].slice.call(p.getClientRects()).map(function(r){return r.width}));
        return 'lang='+(document.documentElement.getAttribute('lang')||document.documentElement.getAttribute('xml:lang')||'-')+
          ' hyphens='+(cs.webkitHyphens||cs.hyphens)+' align='+cs.textAlign+' width='+Math.round(w)+' charsPerLine='+Math.round(w/avg);})()
        """
        let line = (try? await navigator.evaluateJavaScript(js).get()) as? String ?? "nil"
        readerLog.notice("typography columns=\(self.columns) \(line, privacy: .public)")
    }

    /// The top (in window points) of the highest line of text on screen that reaches into `band` (window
    /// points), so paper laid over the page's foot can end in the gap above it rather than across it.
    func lineTop(crossing band: ClosedRange<CGFloat>) async -> CGFloat? {
        let host = navigator.view!
        var best: CGFloat?
        func walk(_ v: UIView) {
            if let web = v as? WKWebView {
                if !web.isHidden, web.alpha > 0.01, web.convert(web.bounds, to: host).intersects(host.bounds) { webs.append(web) }
                return
            }
            v.subviews.forEach(walk)
        }
        var webs: [WKWebView] = []
        walk(host)
        for web in webs {
            guard let window = web.window else { continue }
            // Through the web view's own conversion both ways: the page steps back (scaled 0.96) while
            // the controls are up, and a line's offset inside it shrinks with it.
            let y0 = web.convert(CGPoint(x: 0, y: band.lowerBound), from: window).y
            let y1 = web.convert(CGPoint(x: 0, y: band.upperBound), from: window).y
            let js = """
            (function(y0,y1){var w=window.innerWidth,best=-1,n,r=document.createRange();
            var tw=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);
            while((n=tw.nextNode())){if(!n.textContent.trim())continue;r.selectNodeContents(n);var rs=r.getClientRects();
            for(var i=0;i<rs.length;i++){var q=rs[i];if(q.width<1||q.right<=0||q.left>=w)continue;
            if(q.bottom>y0&&q.top<y1&&(best<0||q.top<best))best=q.top;}}return best;})(\(y0),\(y1))
            """
            guard let top = (try? await web.evaluateJavaScript(js)) as? Double, top >= 0 else { continue }
            let y = web.convert(CGPoint(x: 0, y: CGFloat(top)), to: window).y
            best = min(best ?? y, y)
        }
        return best
    }

    /// Readium's own loading spinner is showing: the page in view hasn't loaded yet.
    var isLoadingPage: Bool {
        let host = navigator.view!
        func spinning(_ v: UIView) -> Bool {
            guard !v.isHidden, v.alpha > 0.01 else { return false }
            if let a = v as? UIActivityIndicatorView {
                return a.isAnimating && a.convert(a.bounds, to: host).intersects(host.bounds)
            }
            return v.subviews.contains(where: spinning)
        }
        return spinning(host)
    }

    /// The page as the web views draw it. `drawHierarchy` misplaces a paginated web view's content
    /// (it drew the page shifted by about a column, with the next one peeking in, and a spread
    /// black), so each visible web view is asked for its own snapshot and laid out where it sits.
    func snapshot() async -> UIImage {
        let host = navigator.view!
        let bounds = host.bounds
        var webs: [(WKWebView, CGRect)] = []
        func walk(_ v: UIView) {
            if let w = v as? WKWebView {
                let frame = w.convert(w.bounds, to: host)
                if !w.isHidden, w.alpha > 0.01, frame.intersects(bounds) { webs.append((w, frame)) }
                return
            }
            v.subviews.forEach(walk)
        }
        walk(host)
        var parts: [(UIImage, CGRect)] = []
        for (web, frame) in webs {
            let config = WKSnapshotConfiguration()
            config.afterScreenUpdates = false
            if let image = try? await web.takeSnapshot(configuration: config) { parts.append((image, frame)) }
        }
        let paper = weakModel?.theme.uiBackground ?? .systemBackground
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = true
        return UIGraphicsImageRenderer(bounds: bounds, format: format).image { ctx in
            paper.setFill()
            ctx.fill(bounds)
            if parts.isEmpty {
                host.drawHierarchy(in: bounds, afterScreenUpdates: false)
            } else {
                for (image, frame) in parts { image.draw(in: frame) }
            }
        }
    }

    /// A snapshot that shows the page: not black, not bare paper, and (after a change) the same
    /// twice running, so the layout has settled. Gives up after about 0.7 s with the best it has.
    func renderedSnapshot(afterChange: Bool) async -> UIImage {
        let paper = PageSignature.rgb(weakModel?.theme.uiBackground ?? .white)
        var last: (UIImage, PageSignature)?
        // A turn into a chapter still loading holds the old page until it has: as long as Readium's
        // spinner is up (up to 8 s), else up to 2 s for a page that is still bare.
        for attempt in 0..<160 {
            if afterChange || attempt > 0 { try? await Task.sleep(for: .milliseconds(attempt == 0 ? 60 : 50)) }
            if isLoadingPage { last = nil; continue }
            if attempt >= 40 { break }
            let image = await snapshot()
            guard let signature = PageSignature(image) else { return image }
            let usable = !signature.isBlack(paper: paper) && !signature.isBare(paper: paper)
            if usable, !afterChange { return image }
            if usable, let (_, previous) = last, previous.matches(signature) { return image }
            if usable { last = (image, signature) }
            if !usable { readerLog.notice("snapshot \(attempt) unusable: black=\(signature.isBlack(paper: paper)) bare=\(signature.isBare(paper: paper))") }
        }
        if let last { return last.0 }
        return await snapshot()
    }

    private func nextFrame() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { c.resume() }
        }
    }
}

/// A 24×32 greyscale thumbnail of a snapshot, to tell a painted page from a black or bare one and
/// a settled page from one still laying out.
struct PageSignature {
    var pixels: [UInt8]

    init?(_ image: UIImage) {
        guard let cg = image.cgImage else { return nil }
        let w = 24, h = 32
        var buffer = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &buffer, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        pixels = buffer
    }

    static func rgb(_ color: UIColor) -> UInt8 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return UInt8(max(0, min(255, (0.299 * r + 0.587 * g + 0.114 * b) * 255)))
    }

    var mean: Double { Double(pixels.reduce(0) { $0 + Int($1) }) / Double(pixels.count) }

    /// Nearly black on a theme whose paper is not.
    func isBlack(paper: UInt8) -> Bool { paper > 40 && mean < 12 }

    /// Paper with nothing on it: no pixel strays more than a little from the paper's grey.
    func isBare(paper: UInt8) -> Bool {
        if pixels.filter({ abs(Int($0) - Int(paper)) > 10 }).count < 3 { return true }
        // Or a page of any one colour (a chapter still loading shows a white page and a spinner).
        let sorted = pixels.sorted()
        let median = Int(sorted[sorted.count / 2])
        return pixels.filter { abs(Int($0) - median) > 10 }.count < 6
    }

    func matches(_ other: PageSignature) -> Bool {
        guard other.pixels.count == pixels.count else { return false }
        let diff = zip(pixels, other.pixels).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        return Double(diff) / Double(pixels.count) < 1.5
    }
}

struct ReaderHostView: UIViewControllerRepresentable {
    let controller: ReaderHostController

    func makeUIViewController(context: Context) -> ReaderHostController { controller }
    func updateUIViewController(_ controller: ReaderHostController, context: Context) {}
}

/// Reports that a touch began, then steps aside without claiming it.
private final class TouchNoticer: UIGestureRecognizer {
    private let onTouch: () -> Void

    init(onTouch: @escaping () -> Void) {
        self.onTouch = onTouch
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        onTouch()
        state = .failed
    }
}

extension Decoration.Style.Id {
    static var gatefoldSync: Self { "gatefoldSync" }
}

extension HTMLDecorationTemplate {
    /// A ribbon-coloured underline that draws itself in from the left, then fades.
    static func gatefoldSync() -> HTMLDecorationTemplate { HTMLDecorationTemplate(
        layout: .boxes,
        element: { decoration in
            let tint = (decoration.style.config as? String) ?? "#9A3B26"
            return "<div class=\"gatefold-sync\" style=\"--gf-tint: \(tint);\"/>"
        },
        stylesheet: """
        .gatefold-sync {
            box-sizing: border-box;
            border-bottom: 2px solid var(--gf-tint);
            clip-path: inset(0 100% 0 0);
            animation: gatefold-draw 0.6s ease-out forwards, gatefold-fade 2s ease-in 0.6s forwards;
        }
        @media (prefers-reduced-motion: reduce) {
            .gatefold-sync { clip-path: none; animation: gatefold-fade 2s ease-in 0.6s forwards; }
        }
        @keyframes gatefold-draw { to { clip-path: inset(0 0 0 0); } }
        @keyframes gatefold-fade { from { opacity: 1; } to { opacity: 0; } }
        """
    ) }
}
