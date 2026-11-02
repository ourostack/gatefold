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
        self.columns = columns
        if reflow { beginReflow(model.consumeReflowReason() ?? .typography) }
        navigator.submitPreferences(preferences)
        if reflow { settleReflowSoon() }
        Task {
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
        if let visible,
           case let .jump(anchor) = model.keeper.reflowDidSettle(visible: visible),
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
        model.keeper.restoreDidComplete()
        model.reflowDidFinish(visible: after)
        disablePanningIfNeeded()
        let cover = reflowCover
        reflowCover = nil
        UIView.animate(withDuration: 0.25) {
            self.navigator.view.alpha = 1
            cover?.alpha = 0
        } completion: { _ in cover?.removeFromSuperview() }
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
        curl.corner = CGPoint(x: forward ? size.width : 0, y: size.height)
        curl.finger = CGPoint(x: forward ? size.width : 0, y: y)
        curl.isActive = true
        await nextFrame()
        withAnimation(.easeIn(duration: duration)) { curl.finger = turnedTarget() }
        try? await Task.sleep(for: .seconds(duration))
    }

    /// Underlines the other device's words with the ribbon colour: drawn in over 0.6 s, gone after 2.
    func underline(_ locator: Locator, color: UInt32) {
        guard locator.text.highlight?.isEmpty == false else { return }
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
