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
final class ReaderHostController: UIViewController, EPUBNavigatorDelegate, UIGestureRecognizerDelegate {
    let navigator: EPUBNavigatorViewController
    private weak var weakModel: ReaderModel?
    /// The reader outlives this controller in every path but a mid-turn close; callers in tasks guard `weakModel`.
    private var model: ReaderModel { weakModel! }
    private let curl = CurlModel()
    private lazy var curlHost = UIHostingController(rootView: CurlOverlay(model: curl))
    private var observers: [Any] = []

    private var lastSize: CGSize = .zero
    private var reflowTask: Task<Void, Never>?
    private var reflowGeneration = 0
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
                contentInset: [.compact: (top: 28, bottom: 28), .regular: (top: 44, bottom: 44)],
                preloadPreviousPositionCount: 2,
                preloadNextPositionCount: 4
            )
        )
        super.init(nibName: nil, bundle: nil)
        navigator.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.clipsToBounds = true
        addChild(navigator)
        navigator.view.frame = view.bounds
        navigator.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(navigator.view)
        navigator.didMove(toParent: self)

        // Any touch on the page means the next location is the reader's own (slide and scroll swipes
        // belong to Readium, so they're noticed here rather than in the pan handler).
        let noticer = TouchNoticer { [weak self] in self?.weakModel?.noteInteraction() }
        noticer.delegate = self
        navigator.view.addGestureRecognizer(noticer)

        addChild(curlHost)
        curlHost.view.backgroundColor = .clear
        curlHost.view.frame = view.bounds
        curlHost.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        curlHost.view.isUserInteractionEnabled = false
        curlHost.sizingOptions = []
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
        Task { _ = await navigator.evaluateJavaScript(ReaderJS.setColumns(columns)) }
    }

    // MARK: Reflow and the reading anchor

    private func beginReflow(_ reason: ReflowReason) {
        readerLog.notice("reflow begins: \(String(describing: reason), privacy: .public)")
        model.keeper.reflowWillBegin(reason)
        model.reflowDidBegin()
        if !curl.isActive {
            UIView.animate(withDuration: 0.12) { self.navigator.view.alpha = 0 }
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
        // A slow device may still be paginating: judge the page only once it shows text.
        let visible = await laidOutRange()
        guard current() else { return }
        var after = visible
        if let visible,
           case let .jump(anchor) = model.keeper.reflowDidSettle(visible: visible),
           let locator = model.locator(for: anchor) {
            // A jump made while the book is still settling can land on an empty column; try again.
            for _ in 0..<3 {
                _ = await navigator.go(to: locator, options: .init(animated: false))
                try? await Task.sleep(for: .milliseconds(160))
                guard current() else { return }
                after = await laidOutRange()
                guard current() else { return }
                if after?.text != nil { break }
            }
        }
        model.keeper.restoreDidComplete()
        model.reflowDidFinish(visible: after)
        disablePanningIfNeeded()
        UIView.animate(withDuration: 0.25) { self.navigator.view.alpha = 1 }
    }

    /// The visible range once the page shows text, waiting up to about 3 seconds for layout.
    private func laidOutRange() async -> VisibleRange? {
        var range = await visibleRange()
        for _ in 0..<12 where range != nil && range?.text == nil {
            try? await Task.sleep(for: .milliseconds(250))
            range = await visibleRange()
        }
        return range
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

    /// The first words on the page the reader is on.
    func currentAnchor() async -> (ReadingAnchor, Locator)? {
        guard let location = navigator.currentLocation else { return nil }
        _ = await navigator.evaluateJavaScript(ReaderJS.install)
        let json = (try? await navigator.evaluateJavaScript(ReaderJS.anchor(column: 0)).get()) as? String
        struct Found: Decodable { var highlight: String; var before: String?; var heading: String? }
        let found = json.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(Found.self, from: $0) }
        weakModel?.heading = found?.heading.map(ReaderJS.tidyHeading)
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

    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        guard let model = weakModel else { return }
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
                if moved { weakModel?.userTurnedPage() }
            }
        case .curl, .fade:
            Task { await animatedTurn(forward: forward, from: nil) }
        }
        return true
    }

    /// A whole turn without a finger: lift from the lower corner and sweep across.
    private func animatedTurn(forward: Bool, from finger: CGPoint?) async {
        guard await prepareTurn(forward: forward, startingAt: finger ?? CGPoint(x: view.bounds.width, y: view.bounds.height * 0.86)) else { return }
        await finish(complete: true, velocity: 0)
    }

    /// Snapshots the current page, moves the navigator underneath the overlay and snapshots the
    /// destination. Returns false at the start or end of the book.
    private func prepareTurn(forward: Bool, startingAt point: CGPoint) async -> Bool {
        guard !isTurning, weakModel != nil else { return false }
        isTurning = true
        let size = navigator.view.bounds.size
        let top = snapshot()
        curl.size = size
        curl.style = model.pageTurn == .fade ? .fade : .curl
        curl.isSpread = model.layout.posture == .spread
        curl.mirrored = !forward
        curl.paper = model.theme.background
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
            UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.4)
            return false
        }
        try? await Task.sleep(for: .milliseconds(140))
        curl.beneath = snapshot()
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
        true
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

    // MARK: Helpers

    private func snapshot() -> UIImage {
        let bounds = navigator.view.bounds
        let paper = weakModel?.theme.uiBackground ?? .systemBackground
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = true
        return UIGraphicsImageRenderer(bounds: bounds, format: format).image { ctx in
            paper.setFill()
            ctx.fill(bounds)
            navigator.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
    }

    private func nextFrame() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { c.resume() }
        }
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
