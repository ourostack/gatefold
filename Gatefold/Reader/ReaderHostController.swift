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
    private(set) var navigator: EPUBNavigatorViewController
    private let publication: Publication
    private var preferences: EPUBPreferences
    /// The Cloud place's page, loading behind this one while the catch-up slip is up, so the tap
    /// finds it ready instead of waiting seconds for a new web view (`prepareStandby`).
    private var standby: (navigator: EPUBNavigatorViewController, locator: Locator, ready: Task<Void, Never>)?
    private var noticer: TouchNoticer?
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
    private(set) var isTurning = false {
        didSet {
            guard oldValue != isTurning else { return }
            if LaunchOptions.isUITest {
                if isTurning { frames.start() } else { frames.stop(counting: counter != nil) }
            }
            // A chapter still loading behind the page shares its web process with the turn: stop the count
            // for the turn (what's counted is kept) and take it up again once turns go quiet.
            if isTurning, counter != nil {
                stopCounting()
                countPausedForTurns = true
            } else if !isTurning, countPausedForTurns {
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(1500))
                    guard let self, !self.isTurning, self.countPausedForTurns,
                          self.lastTurnEnded.map({ ContinuousClock.now - $0 >= .milliseconds(1400) }) ?? true else { return }
                    self.countPausedForTurns = false
                    await self.weakModel?.refreshScreenNumbers(recount: true)
                }
            }
        }
        willSet { if isTurning, !newValue { lastTurnEnded = .now } }
    }
    private var lastTurnEnded: ContinuousClock.Instant?
    /// Turns that pictured the page beneath (the turn-wait probe's count).
    private var turnsPictured = 0
    /// A count stopped for a turn, to take up again once turns go quiet.
    private var countPausedForTurns = false
    /// Under test, each turn's frames: whether a count behind the page costs the turn any.
    private let frames = FrameWatch()
    private var panStart: CGPoint = .zero
    private var panForward = true
    /// Set when the pan ends before the turn is ready; the preparing task finishes with it.
    private var panEnded: Bool?
    private var columns = 1

    init(model: ReaderModel, publication: Publication, initialLocation: Locator?, preferences: EPUBPreferences) throws {
        self.weakModel = model
        self.publication = publication
        self.preferences = preferences
        navigator = try Self.makeNavigator(publication: publication, at: initialLocation, preferences: preferences)
        super.init(nibName: nil, bundle: nil)
        navigator.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func makeNavigator(publication: Publication, at location: Locator?, preferences: EPUBPreferences) throws -> EPUBNavigatorViewController {
        try EPUBNavigatorViewController(
            publication: publication,
            initialLocation: location,
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
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if let model = weakModel { readerLog.notice("open: host loads after \(Date().timeIntervalSince(model.openedAt), privacy: .public) s") }
        if LaunchOptions.isUITest || LaunchOptions.openTour != nil { traceWebViews() }
        if LaunchOptions.isUITest, let looks = LaunchOptions.holdOpeningLoadLooks, looks > 0 { holdLoadForTest(looks: looks) }
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
        self.noticer = noticer

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

        let pan = CurlPan(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)

        wire(navigator)
        model.host = self
    }

    /// Taps, keys and touches on the page in view come here.
    private func wire(_ navigator: EPUBNavigatorViewController) {
        navigator.delegate = self
        if let noticer { navigator.view.addGestureRecognizer(noticer) }
        observers = [
            navigator.addObserver(.tap { [weak self] event in self?.handleTap(at: event.location) ?? false }),
            navigator.addObserver(.key(.arrowRight) { [weak self] in self?.turn(forward: true) ?? false }),
            navigator.addObserver(.key(.arrowLeft) { [weak self] in self?.turn(forward: false) ?? false }),
            navigator.addObserver(.key(.space) { [weak self] in self?.turn(forward: true) ?? false }),
        ]
    }

    private func unwire(_ navigator: EPUBNavigatorViewController) {
        if let noticer { navigator.view.removeGestureRecognizer(noticer) }
        for case let token as InputObservableToken in observers { navigator.removeObserver(token) }
        observers = []
        navigator.delegate = nil
    }

    // MARK: The standby page

    /// Starts loading `locator`'s page in a second navigator behind this one. A new chapter needs a
    /// new web view, and a new web view took two to three seconds to load; loaded while the slip is
    /// up, the catch-up tap only has to swap it in.
    func prepareStandby(at locator: Locator) {
        if let standby, standby.locator == locator { return }
        dropStandby()
        guard !closed, isViewLoaded, let next = try? Self.makeNavigator(publication: publication, at: locator, preferences: preferences) else { return }
        let started = ContinuousClock.now
        // The page's own bands (`navigatorContentInset`), as the counters have them, before its view loads.
        // Without them it laid out for a taller page, and once swapped in Readium asked for the bands and
        // laid it out again under him: the landing's words ended a page on (#46, the web view 944 pt, then 758).
        let insets = CountingInsets { [weak self] in
            guard let self else { return nil }
            return self.navigatorContentInset(self.navigator)
        }
        standbyInsets = insets
        next.delegate = insets
        addChild(next)
        next.view.frame = navigator.view.frame
        next.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        next.view.isUserInteractionEnabled = false
        // Out of sight and out of VoiceOver's reach until it is the page.
        next.view.accessibilityElementsHidden = true
        view.insertSubview(next.view, belowSubview: navigator.view)
        next.didMove(toParent: self)
        let columns = columns
        let ready = Task { @MainActor in
            // Readium answers JavaScript once the spread has loaded, and fails at once before it has a spread.
            for _ in 0..<100 where !Task.isCancelled {
                if case .success = await next.evaluateJavaScript(ReaderJS.install) { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            _ = await ReaderHostController.onSpread { try await next.answer(ReaderJS.setColumns(columns)) }
            // Readium places the page by progression; turn to the page the words are on, as `settle` does.
            if let words = locator.text.highlight.map(ReaderJS.normalize), words.count >= 8 {
                let probe = String(words.prefix(24))
                for _ in 0..<3 where !Task.isCancelled {
                    let shown = ((try? await next.evaluateJavaScript(ReaderJS.visibleText).get()) as? String).map(ReaderJS.normalize) ?? ""
                    if shown.contains(probe) { break }
                    guard let exact = (try? await next.evaluateJavaScript(ReaderJS.progressionOf(words)).get()) as? Double else { break }
                    _ = await next.go(to: locator.copy(locations: { $0.progression = exact }, text: { $0 = Locator.Text() }), options: .init(animated: false))
                    try? await Task.sleep(for: .milliseconds(150))
                }
            }
            readerLog.notice("standby: the Cloud place's page loaded \(ReaderModel.ms(since: started), privacy: .public) ms after the slip")
        }
        standby = (next, locator, ready)
        readerLog.notice("standby: loading the Cloud place's page behind this one")
    }

    /// For tests: the standby page and its load, while one is behind the page.
    var standbyPage: (navigator: EPUBNavigatorViewController, ready: Task<Void, Never>)? {
        standby.map { ($0.navigator, $0.ready) }
    }

    /// A book opened ahead of a tap that won't be shown: stop its pages loading, so a book the reader
    /// did tap gets the whole CPU (an abandoned warm page went on loading for seconds behind a cold open).
    func halt() {
        func stop(_ view: UIView) {
            if let web = view as? WKWebView { web.stopLoading() }
            view.subviews.forEach(stop)
        }
        stopCounting()
        // Only a view already loaded: reading `view` would load it, and start Readium, off screen.
        if let view = navigator.viewIfLoaded { stop(view) }
        readerLog.notice("warm: stopped loading \(self.weakModel?.bookID ?? "?", privacy: .public)")
    }

    /// Set by `close()`: the book is closed, and nothing starts a page again.
    private var closed = false

    /// The still picture `close()` put in the page's place, while the reader leaves the screen.
    private(set) weak var closePicture: UIView?

    /// The book closed (#109): retire the page's own navigator as well as its counters and standby, so its
    /// web views go, here and now, not on a view lifecycle call that may come late or not at all. On screen,
    /// a still picture of the page takes its place, so the reader stays drawn as it leaves.
    func close() {
        closed = true
        stopCounting()
        dropStandby()
        if let view = viewIfLoaded, view.window != nil, let page = navigator.viewIfLoaded,
           let picture = page.snapshotView(afterScreenUpdates: false) {
            picture.frame = page.frame
            picture.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            // A picture, not the page: VoiceOver has nothing to find on it while it leaves.
            picture.accessibilityElementsHidden = true
            view.addSubview(picture)
            closePicture = picture
        }
        Self.retire(navigator)
    }

    func dropStandby() {
        guard let old = standby else { return }
        standby = nil
        standbyInsets = nil
        old.ready.cancel()
        Self.retire(old.navigator)
    }

    /// Puts the standby page in front when it is `locator`'s, waiting for it to finish loading if it
    /// hasn't. False when there is none, and the caller jumps as usual.
    func promoteStandby(for locator: Locator) async -> Bool {
        guard let next = standby, next.locator == locator else { return false }
        // A page that hasn't loaded in 1.5 s may never load: the plain jump is no slower than waiting on.
        let ready = next.ready
        let loaded = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await ready.value; return true }
            group.addTask { try? await Task.sleep(for: .milliseconds(1500)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        guard loaded else {
            readerLog.notice("standby: not loaded 1.5 s after the tap; jumping the plain way")
            dropStandby()
            return false
        }
        guard standby?.navigator === next.navigator else { return false }
        // The swap is the landing: nothing queued for the old page may move the new one.
        reflowTask?.cancel()
        reflowGeneration += 1
        let t0 = ContinuousClock.now
        defer { readerLog.notice("standby: swapped in, \(ReaderModel.ms(since: t0), privacy: .public) ms on the main thread") }
        standby = nil
        let old = navigator
        unwire(old)
        next.navigator.view.frame = old.view.frame
        next.navigator.view.isUserInteractionEnabled = true
        next.navigator.view.accessibilityElementsHidden = false
        navigator = next.navigator
        wire(navigator)
        standbyInsets = nil
        Self.retire(old)
        weakModel?.highlights.navigatorChanged()
        if let here = navigator.currentLocation { self.navigator(navigator, locationDidChange: here) }
        return true
    }

    // MARK: Screen pages

    /// The page laying chapters out out of sight to count their pages (`countPages`).
    private var counter: (navigators: [EPUBNavigatorViewController], task: Task<Void, Never>)?
    /// The counters' delegate, held here (a navigator holds its delegate weakly).
    private var countingInsets: CountingInsets?
    /// The standby page's delegate until it is the page (a navigator holds its delegate weakly).
    private var standbyInsets: CountingInsets?

    func screenGeometry() async -> (href: String, geometry: ScreenPageGeometry)? {
        await Self.geometry(of: navigator, columns: columns)
    }

    private static func geometry(of navigator: EPUBNavigatorViewController, columns: Int) async -> (href: String, geometry: ScreenPageGeometry)? {
        await onSpread { try await measure(navigator, columns: columns) }
    }

    private static func measure(_ navigator: EPUBNavigatorViewController, columns: Int) async throws -> (href: String, geometry: ScreenPageGeometry)? {
        // The place read once the spread has answered: read first, it could name the spread this one replaced.
        _ = try await navigator.answer(ReaderJS.install)
        guard let location = navigator.currentLocation else { return nil }
        guard let json = try await navigator.answer(ReaderJS.geometry) as? String,
              let data = json.data(using: .utf8) else { return nil }
        struct Found: Decodable { var w: Double; var l: Double; var v: Double; var verso: Bool; var pinned: Bool; var doc: String? }
        guard let found = try? JSONDecoder().decode(Found.self, from: data) else { return nil }
        let href = location.href.string.split(separator: "#", maxSplits: 1).first.map(String.init) ?? location.href.string
        // Measured in the chapter it names, or not at all: a counter's location moves to the next chapter
        // while the previous one's web view is still current, and its columns would be counted as the next's.
        if let doc = found.doc, !ScreenPageGeometry.document(doc, isChapter: href) {
            readerLog.debug("pages: a look named \(href, privacy: .public) measured \(doc, privacy: .public)")
            return nil
        }
        return (href, ScreenPageGeometry(scrollWidth: found.w, scrollLeft: found.l, viewportWidth: found.v,
                                         columnsPerScreen: columns, verso: found.verso, pinned: found.pinned))
    }

    /// Counts each chapter in a second navigator behind this one, laid out as this one is (no verso,
    /// no pin), so the numbers are a clean layout's. It waits out turns, so a turn never shares the CPU.
    func countPages(_ hrefs: [String], record: @escaping @MainActor (String, Int) -> Void, finished: @escaping @MainActor () -> Void) {
        stopCounting()
        // Every way out says so, or the slot keeps promising a number.
        guard !closed, isViewLoaded, preferences.scroll != true, !hrefs.isEmpty else { finished(); return }
        let links = hrefs.compactMap { href in publication.readingOrder.first { $0.url().removingFragment().string == href } }
        // A chapter's cost is its web view loading (about 3 s each, one after another, in build 17), not
        // its measuring: several counters behind the page take chapters from one queue at once.
        let workers = (0..<min(LaunchOptions.counters ?? Self.counters, links.count)).compactMap { _ in
            try? Self.makeNavigator(publication: publication, at: nil, preferences: preferences)
        }
        guard !workers.isEmpty else { finished(); return }
        // The page's own bands (`navigatorContentInset`): without them a tablet counter laid its words out
        // 276 pt taller than the page and counted about a fifth too few columns.
        let insets = CountingInsets { [weak self] in
            guard let self else { return nil }
            return self.navigatorContentInset(self.navigator)
        }
        countingInsets = insets
        for counting in workers {
            counting.delegate = insets
            addChild(counting)
            // The same size as the page, laid out beside it, past the clipped edge. Behind the page, its
            // chapter came out in the reopen picture drawn from this view, laid over his page. A reflow
            // stops the count, so it never needs to follow the page's size.
            counting.view.frame = navigator.view.frame.offsetBy(dx: view.bounds.width + 64, dy: 0)
            counting.view.isUserInteractionEnabled = false
            counting.view.accessibilityElementsHidden = true
            view.insertSubview(counting.view, at: 0)
            counting.didMove(toParent: self)
        }
        let columns = columns
        let started = ContinuousClock.now
        let queue = CountQueue(links)
        let task = Task { @MainActor [weak self] in
            let running = workers.map { counting in
                Task { @MainActor [weak self] in
                    while !Task.isCancelled, let link = queue.next() {
                        // A chapter laid out mid-burst costs the next turn frames: wait for 1.5 s without a turn.
                        while let host = self, host.isTurning || host.lastTurnEnded.map({ ContinuousClock.now - $0 < .milliseconds(1500) }) == true, !Task.isCancelled {
                            try? await Task.sleep(for: .milliseconds(250))
                        }
                        guard !Task.isCancelled else { return }
                        if await Self.count(link, in: counting, columns: columns, record: record) {
                            queue.counted += 1
                        } else if !Task.isCancelled {
                            // A chapter that never settled (its web view still loading under the others)
                            // goes to the back of the queue: a book with one uncounted chapter has no numbers.
                            queue.retry(link)
                        }
                    }
                }
            }
            await withTaskCancellationHandler {
                for worker in running { await worker.value }
            } onCancel: {
                for worker in running { worker.cancel() }
            }
            let counted = queue.counted
            guard !Task.isCancelled else { return }
            readerLog.notice("pages: counted \(counted, privacy: .public) of \(links.count, privacy: .public) chapters with \(workers.count, privacy: .public) counters in \(ReaderModel.ms(since: started), privacy: .public) ms")
            if self?.counter?.navigators.first === workers.first { self?.stopCounting() }
            finished()
        }
        counter = (workers, task)
        readerLog.notice("pages: counting \(links.count, privacy: .public) chapters behind the page with \(workers.count, privacy: .public) counters")
    }

    /// The chapters still to count, shared by the counters.
    @MainActor private final class CountQueue {
        private var links: ArraySlice<ReadiumShared.Link>
        var counted = 0
        init(_ links: [ReadiumShared.Link]) { self.links = links[...] }
        private var tries: [String: Int] = [:]
        func next() -> ReadiumShared.Link? { links.popFirst() }
        func retry(_ link: ReadiumShared.Link) {
            let href = link.url().removingFragment().string
            tries[href, default: 0] += 1
            // At the front: the chapters are counted in reading order, and each number waits on those before it.
            if tries[href]! <= 2 { links.insert(link, at: links.startIndex) } else { readerLog.notice("pages: \(href, privacy: .public) never settled") }
        }
    }

    /// How many chapters are counted at once.
    private static let counters = 6

    /// Lays `link` out in `counting` and records its columns once two looks 150 ms apart agree (a web
    /// view still laying out, or still loading a font, reads short). False if it never settled.
    private static func count(_ link: ReadiumShared.Link, in counting: EPUBNavigatorViewController, columns: Int,
                              record: @MainActor (String, Int) -> Void) async -> Bool {
        // A counter made a moment ago can refuse a go while its first chapter is still loading: ask again
        // in place, since every number after this chapter waits for it.
        var went = await counting.go(to: link, options: .init(animated: false))
        for _ in 0..<20 where !went && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(150))
            went = await counting.go(to: link, options: .init(animated: false))
        }
        let href = link.url().removingFragment().string
        readerLog.debug("pages: \(href, privacy: .public) go \(went, privacy: .public)")
        var last: Int?
        for _ in 0..<40 where !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(150))
            let lookStart = ContinuousClock.now
            let look = await geometry(of: counting, columns: columns)
            readerLog.debug("pages: look \(href, privacy: .public) took \(ReaderModel.ms(since: lookStart), privacy: .public) ms")
            guard let (here, geometry) = look, here == href, geometry.columns > 0 else { continue }
            if geometry.columns == last { record(href, geometry.columns); return true }
            last = geometry.columns
        }
        return false
    }

    /// Takes a navigator that is done (a counter, a standby page, the page a swap replaced) out of the reader,
    /// and lets go of its web views (#109). Readium clears its pages (stops them loading, resumes whatever
    /// waits on them) only when its pagination view leaves its superview, and UIKit tells only the view that
    /// left, so the pagination view comes out first. A page stopped mid-load held its web view, and its web
    /// content process, for good while a script waited on it: 187 of them after one Fine-Tune test.
    static func retire(_ navigator: EPUBNavigatorViewController) {
        navigator.willMove(toParent: nil)
        if let view = navigator.viewIfLoaded {
            view.subviews.forEach { $0.removeFromSuperview() }
            view.removeFromSuperview()
        }
        navigator.removeFromParent()
    }

    func stopCounting() {
        guard let old = counter else { return }
        counter = nil
        old.task.cancel()
        // Its web view shares the page's web process: a chapter still loading there would hold up a
        // reflow's looks at the page past their budgets.
        func stop(_ view: UIView) {
            if let web = view as? WKWebView { web.stopLoading() }
            view.subviews.forEach(stop)
        }
        for counting in old.navigators {
            stop(counting.view)
            Self.retire(counting)
        }
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
        // A closed reader's page is retired: new preferences would only load pages nobody sees (#109).
        guard !closed else { return }
        // One page becoming two is the unfold: the right page swings open once it has laid out.
        unfolding = reflow && self.columns == 1 && columns == 2
        self.columns = columns
        self.preferences = preferences
        // A page laid out in the old type would be the wrong page, and its counts the wrong counts.
        dropStandby()
        stopCounting()
        if reflow { beginReflow(model.consumeReflowReason() ?? .typography) }
        navigator.submitPreferences(preferences)
        if reflow { settleReflowSoon() }
        Task {
            _ = await Self.onSpread { () async throws -> Void? in
                let navigator = self.navigator // the one on screen now, on each try
                guard self.columns == columns else { return nil } // a newer apply owns the columns now
                if columns == 1 { _ = try await navigator.answer(ReaderJS.removeVerso) }
                _ = try await navigator.answer(ReaderJS.setColumns(columns))
                return ()
            }
            if reflow, model.pageReady {
                try? await Task.sleep(for: .seconds(1))
                await logTypography()
            }
        }
    }

    // MARK: Reflow and the reading anchor

    private func beginReflow(_ reason: ReflowReason) {
        readerLog.notice("reflow begins: \(String(describing: reason), privacy: .public)")
        // A late correction's picture is the spread he was reading (the page beneath may be half moved):
        // it becomes the reflow's cover.
        if let picture = settlePicture {
            settlePicture = nil
            if reflowCover == nil { reflowCover = picture } else { picture.removeFromSuperview() }
        }
        dropStandby()
        stopCounting()
        model.keeper.reflowWillBegin(reason, move: model.hisMoves)
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
            // The unfold plays on a page he can see: behind the opening cover (a relaunch turning on its
            // side as it opens) a rising leaf only showed through the cover as it faded (#59).
            // An unfold that begins covered stays a plain reflow even if the cover lifts before it lands:
            // a swing then would play on a still picture of the old page.
            if unfolding, !pageShown { unfolding = false }
            if unfolding { liftLeaf() }
        }
        settleReflowSoon()
    }

    /// The page is on screen for him: no opening cover or reopen picture over it.
    private var pageShown: Bool {
        guard let model = weakModel else { return false }
        return model.pageReady && model.reopenPicture == nil
    }

    /// The leaf that starts rising from the spine at the bell, while the spread lays out behind.
    private var leaf: (view: UIView, shade: CAGradientLayer, lift: UIViewPropertyAnimator, through: CALayer?)?

    /// The unfold starts at the bell: the right leaf rises slowly from the spine, edge-on at first, so
    /// the reader sees the book opening while the spread is laid out, not a page standing still.
    /// `swingOpen` gives it the real page and lays it flat from wherever it has got to.
    private func liftLeaf() {
        guard leaf == nil, !(weakModel?.reduceMotion ?? true), let container = navigator.view.superview else { return }
        let frame = navigator.view.frame
        let spine = spineOffset(in: frame)
        let view = UIView(frame: CGRect(x: frame.minX + spine, y: frame.minY, width: frame.width - spine, height: frame.height))
        view.backgroundColor = weakModel?.theme.uiBackground ?? .systemBackground
        view.isUserInteractionEnabled = false
        let dark = weakModel?.theme.palette.isDark ?? false
        // Until the new page is on it, the leaf is the back of a printed page, as in the riffle: the old
        // page's words showing through faintly, mirrored about the spine (where the leaf lay closed).
        let through = showThrough(size: view.bounds.size, spine: frame.minX + spine, page: frame, dark: dark)
        if let through { view.layer.addSublayer(through) }
        let shade = Self.leafShade(bounds: view.bounds, dark: dark)
        view.layer.addSublayer(shade)
        view.layer.anchorPoint = CGPoint(x: 0, y: 0.5)
        view.layer.position = CGPoint(x: frame.minX + spine, y: frame.midY)
        view.layer.transform = Self.leafAngle(-.pi * 0.495, width: frame.width)
        container.insertSubview(view, aboveSubview: reflowCover ?? navigator.view)
        // A long ease-out: it is still moving, if slowly, whenever the spread is ready.
        let lift = UIViewPropertyAnimator(duration: 2.6, controlPoint1: CGPoint(x: 0.2, y: 0.6), controlPoint2: CGPoint(x: 0.35, y: 1))
        lift.addAnimations { view.layer.transform = Self.leafAngle(-.pi * 0.30, width: frame.width) }
        lift.startAnimation()
        leaf = (view, shade, lift, through)
        readerLog.notice("unfold: the leaf starts to lift at the bell (old words through it \(through != nil, privacy: .public))")
    }

    /// The old page's words, mirrored about the spine and faint, as a page's back shows its front's
    /// print; nil without a fresh picture of the old page.
    private func showThrough(size: CGSize, spine: CGFloat, page: CGRect, dark: Bool) -> CALayer? {
        guard let model = weakModel, let picture = model.heldPicture,
              UnfoldCover.choose(held: model.heldPage, liveAvailable: false, book: model.bookID, now: Date()) == .held else { return nil }
        let layer = CALayer()
        layer.frame = CGRect(origin: .zero, size: size)
        layer.masksToBounds = true
        layer.backgroundColor = UIColor(model.theme.text).withAlphaComponent(dark ? 0.05 : 0.10).cgColor
        let words = CALayer()
        // Where the picture sat over the closed book, seen from the leaf's side: the strip left of the
        // spine, flipped so the spine stays the spine.
        let held = UnfoldCover.heldFrame(picture: picture.size, in: page)
        words.frame = CGRect(x: held.minX - (spine - size.width), y: held.minY - page.minY, width: held.width, height: held.height)
        words.contents = picture.cgImage
        words.contentsScale = picture.scale
        words.contentsGravity = .resize
        words.opacity = dark ? 0.28 : 0.15
        layer.addSublayer(words)
        layer.sublayerTransform = CATransform3DMakeAffineTransform(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: size.width, ty: 0))
        return layer
    }

    private func dropLeaf() {
        guard let leaf else { return }
        leaf.lift.stopAnimation(true)
        leaf.view.removeFromSuperview()
        self.leaf = nil
    }

    private func spineOffset(in frame: CGRect) -> CGFloat {
        guard let model = weakModel, let gutter = model.layout.gutter else { return frame.width / 2 }
        return min(frame.width, max(0, gutter.midX - model.layout.pageFrame.minX))
    }

    private static func leafAngle(_ angle: CGFloat, width: CGFloat) -> CATransform3D {
        var t = CATransform3DIdentity
        t.m34 = -1 / max(600, width * 1.2)
        return CATransform3DRotate(t, angle, 0, 1, 0)
    }

    /// The leaf's shade: deepest at the spine while it stands up, gone once it lies flat.
    private static func leafShade(bounds: CGRect, dark: Bool) -> CAGradientLayer {
        let shade = CAGradientLayer()
        shade.frame = bounds
        shade.startPoint = CGPoint(x: 0, y: 0.5)
        shade.endPoint = CGPoint(x: 1, y: 0.5)
        shade.colors = [UIColor.black.withAlphaComponent(dark ? 0.55 : 0.30).cgColor, UIColor.black.withAlphaComponent(dark ? 0.25 : 0.08).cgColor]
        return shade
    }

    private func settleReflowSoon() {
        reflowTask?.cancel()
        reflowGeneration += 1
        let generation = reflowGeneration
        reflowTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(550))
            guard !Task.isCancelled, let self, self.weakModel != nil else { return }
            await self.restoreAnchor(generation: generation)
            if generation == self.reflowGeneration { self.settledGeneration = generation; self.reflowRetries = 0 }
        }
        // Begun before the book's web view had loaded (a spread opened cold): its first script can wait
        // forever, and counting waits on the reflow. Once the web view has loaded, give it a second to
        // settle by itself, then start it again (build 18 waited out the 12 s below: a fresh open on
        // the iPad's side counted from 11 s after the page showed).
        if Self.firstWebView(in: navigator.view).map({ $0.isLoading }) ?? true {
            Task { @MainActor [weak self] in
                @MainActor func stalled() -> Bool {
                    guard let self else { return false }
                    // Stalled is its first script never coming back; a restore past that is only slow.
                    // Counting waits on the keeper's reflow: once that's over, nothing is stalled.
                    return generation == self.reflowGeneration && self.settledGeneration != generation
                        && self.firstScriptBack < generation && self.weakModel?.keeper.reflowing != nil
                }
                let deadline = ContinuousClock.now + .seconds(10)
                var loaded = false
                while ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(200))
                    guard stalled(), let self else { return }
                    if let web = Self.firstWebView(in: self.navigator.view), !web.isLoading { loaded = true; break }
                }
                // Still loading after 10 s: the 12 s watchdog's business, not this.
                guard loaded else { return }
                try? await Task.sleep(for: .seconds(1))
                guard stalled(), let self, self.reflowRetries < 3 else { return }
                self.reflowRetries += 1
                readerLog.notice("reflow: begun before the page loaded, its first script still out a second after the load; starting it again (\(self.reflowRetries, privacy: .public)) at \(self.weakModel.map { Date().timeIntervalSince($0.openedAt) } ?? -1, privacy: .public) s")
                self.settleReflowSoon()
            }
        }
        // A reflow that begins before the book's web view has loaded (a spread opened straight onto a
        // place, cold) can wait forever on its first script; the page then stays covered. If this one
        // hasn't settled well past its own budgets (3 s to lay out, 4 s to jump), start it again: the stalled one is no longer current and
        // gives way as soon as it wakes.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            // A restore placing his words on the left page is not stalled: it is measuring, within its
            // own read budget. Starting it again threw that work away and began it once more (CI's cold
            // iPad: three restarts, a 91 s open, and a place job run out of time).
            while let self, self.placingGeneration == generation, generation == self.reflowGeneration {
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard let self, generation == self.reflowGeneration, self.settledGeneration != generation,
                  self.weakModel != nil else { return }
            // Twelve seconds is already too long to look at a picture of the old page: show the page as
            // it is now, then try the settle again behind nothing. A page still loading isn't shown:
            // that would be a blank page and a spinner.
            await self.waitWhileLoading()
            guard generation == self.reflowGeneration, self.settledGeneration != generation else { return }
            // He moved while it hung: no restore of the old place to start again.
            if let model = self.weakModel, model.keeper.reflowing != nil, !model.keeper.restoreMayMove(move: model.hisMoves) {
                self.giveWayIfHeMoved(generation: generation)
                return
            }
            self.uncoverUnsettled()
            guard self.reflowRetries < 3 else { return }
            self.reflowRetries += 1
            readerLog.notice("reflow: no settle after 12 s; starting it again (\(self.reflowRetries, privacy: .public))")
            self.settleReflowSoon()
        }
    }
    /// A restore he overtook (he turned or jumped while it ran, the 12 s watchdog's retry on a page it had
    /// shown him among them): it ends where his move left the page, never bringing the old place back, and
    /// his page becomes the anchor again.
    private func giveWayIfHeMoved(generation: Int) {
        // Closing is not a move to give way to: the restore just stops, and nothing is shown or taken after.
        guard generation == reflowGeneration, let model = weakModel, !model.isClosed, model.keeper.reflowing != nil,
              !model.keeper.restoreMayMove(move: model.hisMoves) else { return }
        readerLog.notice("reflow: he moved while the restore ran; it gives way to his move")
        model.keeper.restoreGaveWay()
        settledGeneration = generation
        reflowRetries = 0
        showPageAsItIs()
        // His move's own report took his place, or reflowDidFinish's owed-place path does now (with its guards
        // for a landing and a launch jump in flight): no capture of whatever the page shows here.
        model.reflowDidFinish(visible: nil)
    }

    /// A reflow that hasn't settled in 12 s: the page as it is, never a picture of the old one under a
    /// leaf that stopped rising (a cold iPad turned on its side kept that up past 14 s in build 19).
    private func uncoverUnsettled() {
        guard reflowCover != nil || leaf != nil || navigator.view.alpha < 1 else { return }
        readerLog.error("reflow: no settle after 12 s; showing the page as it is")
        showPageAsItIs()
    }

    private func showPageAsItIs() {
        guard reflowCover != nil || leaf != nil || navigator.view.alpha < 1 else { return }
        unfolding = false
        dropLeaf()
        let cover = reflowCover
        reflowCover = nil
        UIView.animate(withDuration: 0.25) {
            self.navigator.view.alpha = 1
            cover?.alpha = 0
        } completion: { _ in cover?.removeFromSuperview() }
    }
    private var settledGeneration = -1
    /// The reflow whose restore is placing his words on the left page right now.
    private var placingGeneration = -1
    /// The newest reflow whose restore has had its first script back from the page.
    private var firstScriptBack = -1
    private var reflowRetries = 0

    private func restoreAnchor(generation: Int) async {
        // A newer reflow may begin during any await below; it owns the restore from then on.
        // His move (a turn, a jump, a landing) since the reflow began also ends it: the page is his again.
        func current() -> Bool {
            guard generation == reflowGeneration, let model = weakModel else { return false }
            return model.keeper.restoreMayMove(move: model.hisMoves)
        }
        defer { giveWayIfHeMoved(generation: generation) }
        // Back from the page itself: a script whose spread the reflow replaced comes back at once with
        // no page behind it (gatefold#109), and runs again on the spread that replaced it.
        _ = await Self.onSpread { () async throws -> Void? in
            let navigator = self.navigator // the one on screen now, on each try
            guard current() else { return nil }
            _ = try await navigator.answer(ReaderJS.install)
            self.firstScriptBack = max(self.firstScriptBack, generation)
            _ = try await navigator.answer(ReaderJS.setColumns(self.columns))
            return ()
        }
        guard current() else { return }
        if LaunchOptions.stallReflow, reflowCover != nil || leaf != nil {
            readerLog.notice("reflow: held for the test (GatefoldStallReflow)")
            while current(), !Task.isCancelled { try? await Task.sleep(for: .milliseconds(250)) }
            return
        }
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
        // A restore run again on a page with nothing over it (the 12 s watchdog showed the page): its jump
        // and its moves are held behind a picture of the page and shown as one change (gatefold#108).
        var restorePicture: UIView?
        // Overtaken (a newer reflow, his move, the close): this restore's picture goes at once, never a newer one's.
        defer { if let restorePicture, settlePicture === restorePicture { dropSettlePicture() } }
        if case .jump = action, !pageCovered, settlePicture == nil {
            if holdSettlePicture() { restorePicture = settlePicture } else { noteVisibleMove("restore jump") }
        }
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
        if columns == 2, let target {
            placingGeneration = generation
            let moved = await keepOnLeft(target, purpose: .restore, current: current)
            if placingGeneration == generation { placingGeneration = -1 }
            if let moved { after = moved }
        }
        guard current() else { return }
        if let picture = restorePicture {
            if settlePicture === picture { await releaseSettlePicture() }
            restorePicture = nil
        }
        guard current() else { return }
        model.keeper.restoreDidComplete()
        model.reflowDidFinish(visible: after)
        // Settled now, not when the swing below has played: the 12 s watchdog took a slow, finished
        // restore whose swing was still running for a stalled one and started it again.
        settledGeneration = generation
        reflowRetries = 0
        disablePanningIfNeeded()
        var cover = reflowCover
        reflowCover = nil
        if unfolding, columns == 2, !pageShown {
            // Still behind the opening cover: the spread is simply there when the cover lifts.
            readerLog.notice("unfold: behind a cover (the opening one or a reopen picture); no swing")
            unfolding = false
            model.heldPicture = nil
            model.heldPage = nil
        }
        if unfolding, columns == 2 {
            unfolding = false
            // The swing starts from the page the reader was on, whichever screen it was drawn on.
            let choice = UnfoldCover.choose(held: model.heldPage, liveAvailable: cover != nil, book: model.bookID, now: Date())
            if choice == .held, cover?.tag != Self.heldTag, let container = navigator.view.superview,
               let held = heldCover(frame: navigator.view.frame) {
                container.insertSubview(held, aboveSubview: cover ?? navigator.view)
                cover?.removeFromSuperview()
                cover = held
                if let leaf { container.bringSubviewToFront(leaf.view) }
            }
            if choice == .none { cover?.removeFromSuperview(); cover = nil }
            model.heldPicture = nil
            model.heldPage = nil
            readerLog.notice("unfold: from \(choice == .held ? "the picture held as the hinge moved" : choice == .live ? "the live page" : "nothing (a plain reflow)", privacy: .public)")
            await swingOpen(cover: cover)
            return
        }
        unfolding = false
        dropLeaf()
        UIView.animate(withDuration: 0.25) {
            self.navigator.view.alpha = 1
            cover?.alpha = 0
        } completion: { _ in cover?.removeFromSuperview() }
    }

    /// Moves the spread so `anchor`'s words start its left page: a blank verso before the file's first
    /// page shifts every page one side over. Returns what's on screen after a move, nil when none was needed.
    /// The moves are `SpreadSettler`'s: each is judged by measuring the page again once it stands still.
    private func keepOnLeft(_ anchor: ReadingAnchor, purpose: SpreadSettler.Purpose,
                            current: () -> Bool) async -> VisibleRange? {
        guard let text = anchor.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let surface = WebSpread(host: self, anchor: anchor, text: text)
        guard await SpreadSettler.keepOnLeft(surface, current: current, purpose: purpose) == true, current() else { return nil }
        let visible = await visibleRange()
        // The settler also ends here when its passes run out with the words still off the left page.
        readerLog.notice("spread: words placed on the left page; \(surface.moves, privacy: .public) moves (last read side \(surface.lastSide.map { String($0.rawValue) } ?? "nil", privacy: .public))")
        return visible
    }

    func keepWordsOnLeft(_ anchor: ReadingAnchor, stillWanted: @escaping @MainActor () -> Bool) async {
        // A restore placing his words, or another late look, is already moving this page: the report
        // its moves brought is not a new reason to move it.
        guard columns == 2, stillWanted(), !lateSettling, placingGeneration == -1 else { return }
        lateSettling = true
        defer { lateSettling = false }
        if await keepOnLeft(anchor, purpose: .recheck, current: stillWanted) != nil {
            readerLog.notice("spread: a late layout had moved his words; put back on the left page")
        }
    }

    /// A jump to a place with words (the Cloud's, his own offered back) lands where Readium puts its
    /// progression, which can leave the words mid-column or on the right page; a reopen of the place it
    /// keeps restores them to the top of a left page. Settled here the way that restore will, so the
    /// spread he lands on is the one every reopen shows. Behind the jump's veil when it is still up;
    /// after it lifted (`abandonVeil`), each move is held behind a picture (`SpreadSettler.keepOnLeft`).
    func settleLanding(_ anchor: ReadingAnchor, stillWanted: @escaping @MainActor () -> Bool) async {
        guard columns == 2 else { return }
        guard stillWanted() else {
            readerLog.notice("spread: a landing left unsettled (overtaken before it began)")
            return
        }
        guard !lateSettling, placingGeneration == -1 else {
            readerLog.notice("spread: a landing left unsettled (a late look \(self.lateSettling, privacy: .public), a restore placing \(self.placingGeneration != -1, privacy: .public))")
            return
        }
        lateSettling = true
        defer { lateSettling = false }
        if await keepOnLeft(anchor, purpose: .restore, current: stillWanted) != nil {
            readerLog.notice("spread: a landing settled the way a reopen of its place will (veil \(self.veil != nil, privacy: .public))")
        }
    }

    /// The reader's page as `SpreadSettler` moves it.
    private final class WebSpread: SpreadSurface {
        private unowned let host: ReaderHostController
        private let anchor: ReadingAnchor
        private let text: String
        private(set) var moves = 0
        /// Where the words were at the last look.
        private(set) var lastSide: WordsSide?

        init(host: ReaderHostController, anchor: ReadingAnchor, text: String) {
            self.host = host
            self.anchor = anchor
            self.text = text
        }

        private func number(_ script: String) async -> Int? {
            await ReaderHostController.onSpread { (try await self.host.navigator.answer(script) as? NSNumber)?.intValue }
        }

        func wordsSide() async -> WordsSide? {
            let side = await number(ReaderJS.sideOf(text)).flatMap(WordsSide.init(rawValue:))
            readerLog.notice("spread: the sentence starts on side \(side.map { String($0.rawValue) } ?? "nil", privacy: .public)")
            lastSide = side
            return side
        }

        /// A move made on a page nothing covers is one he watches: counted, so a test can say there was none.
        private func moving(_ kind: String) {
            moves += 1
            guard !isCovered, host.settlePicture == nil else { return }
            host.noteVisibleMove(kind)
        }

        func pinWords() async -> Bool {
            let visible = !isCovered && host.settlePicture == nil
            // A move: never run again on a spread that replaced this one, where a newer restore owns the page.
            let pinned = ((try? await host.navigator.answer(ReaderJS.pinToTop(text))) as? NSNumber)?.intValue == 1
            if pinned {
                moves += 1
                if visible { host.noteVisibleMove("column break") }
            }
            return pinned
        }

        func toggleVerso() async {
            moving("verso")
            _ = await host.navigator.evaluateJavaScript(ReaderJS.toggleVerso)
        }

        func goToSavedPlace() async {
            guard let locator = host.model.locator(for: anchor) else { return }
            moving("saved place")
            _ = await host.navigator.go(to: locator, options: .init(animated: false))
        }

        func goToWords() async {
            guard let saved = host.model.locator(for: anchor) else { return }
            // Where the words are in the page as it is laid out now, not where the place was saved.
            let progression = await host.progression(of: text) ?? saved.locations.progression
            moving("to his words")
            _ = await host.navigator.go(to: saved.copy(locations: { $0.progression = progression }), options: .init(animated: false))
        }

        func stepSpread(forward: Bool) async {
            moving("a spread")
            _ = forward ? await host.navigator.goForward(options: .init(animated: false))
                        : await host.navigator.goBackward(options: .init(animated: false))
        }

        func stillness() async -> String? {
            let geometry = await ReaderHostController.onSpread { try await self.host.navigator.answer(ReaderJS.geometry) as? String } ?? "-"
            let at = host.navigator.currentLocation?.locations.progression ?? -1
            return "\(geometry)@\(at)"
        }

        func beat() async { try? await Task.sleep(for: .milliseconds(120)) }

        var isCovered: Bool { host.pageCovered }

        func hold() async -> Bool { host.holdSettlePicture() }

        func release(landed: Bool) async {
            // Overtaken by his move, a reflow or the close: nothing may stand over his page.
            guard landed else { host.dropSettlePicture(); return }
            await host.releaseSettlePicture()
        }
    }

    /// Something stands over the page (a reflow's cover, a jump's veil, the reopen picture), so a move is not seen.
    fileprivate var pageCovered: Bool {
        reflowCover != nil || veil != nil || navigator.view.alpha < 0.5 || weakModel?.reopenPicture != nil
    }

    /// Puts a picture of the page as it is over it; false when one is already up or none could be taken.
    fileprivate func holdSettlePicture() -> Bool {
        let page = navigator.view!
        guard settlePicture == nil, let container = page.superview,
              let cover = page.snapshotView(afterScreenUpdates: false) else { return false }
        cover.frame = page.frame
        cover.isUserInteractionEnabled = false
        container.insertSubview(cover, aboveSubview: page)
        settlePicture = cover
        readerLog.notice("spread: held a picture over the page he is reading while his words are put back")
        return true
    }

    /// Fades the held picture onto the page as the moves left it, once that has painted: one change.
    fileprivate func releaseSettlePicture() async {
        guard let cover = settlePicture else { return }
        _ = await renderedSnapshot(afterChange: true)
        guard settlePicture === cover else { return }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseInOut]) {
                cover.alpha = 0
            } completion: { _ in done.resume() }
        }
        if settlePicture === cover { dropSettlePicture() }
    }

    /// The picture a correction on a spread he is reading holds over the page (`WebSpread.hold`).
    private var settlePicture: UIView?
    /// UI tests: up once a settle moved a page nothing covered, so a test can say every move was hidden.
    private var visibleMoveMarker: UIView?

    fileprivate func noteVisibleMove(_ kind: String) {
        readerLog.error("spread: moved a page he can see (\(kind, privacy: .public))")
        guard LaunchOptions.isUITest, visibleMoveMarker == nil else { return }
        let marker = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        marker.isAccessibilityElement = true
        marker.accessibilityIdentifier = "reader.visibleSettleMove"
        view.addSubview(marker)
        visibleMoveMarker = marker
    }
    /// A late look for his words is running: one at a time, so two never stack pictures or undo each
    /// other's verso.
    private var lateSettling = false

    private func dropSettlePicture() {
        settlePicture?.removeFromSuperview()
        settlePicture = nil
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
            dropLeaf()
            return
        }
        let frame = page.frame
        let spine = spineOffset(in: frame)
        if let delay = LaunchOptions.unfoldPaintDelay {
            var webs: [WKWebView] = []
            func walk(_ v: UIView) { if let w = v as? WKWebView { webs.append(w) } else { v.subviews.forEach(walk) } }
            walk(page)
            webs.forEach { $0.isHidden = true }
            readerLog.notice("unfold: the spread kept unpainted for \(delay, privacy: .public) s (film)")
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                webs.forEach { $0.isHidden = false }
            }
        }
        // The old page stays up until the spread has painted both its pages: swung from a picture
        // taken too soon (a busy device), the left page showed bare paper, then the words snapped in.
        var image = await snapshot()
        let paperLevel = PageSignature.rgb(weakModel?.theme.uiBackground ?? .white)
        let waitStart = ContinuousClock.now
        var waits = 0
        var previous: PageSignature?
        var loadingLooks = 0
        while waits < 60 {
            let halves = Self.paintedHalves(image, spine: spine / max(1, frame.width), paper: paperLevel)
            let signature = PageSignature(image)
            // A chapter can end on the left page: a bare right page counts once it holds still.
            let settled = signature.map { s in previous.map { s.matches($0) } ?? false } ?? true
            if halves.left && (halves.right || settled) { break }
            previous = halves.left ? signature : nil
            try? await Task.sleep(for: .milliseconds(50))
            if isLoadingPage { await unveilPlacedPages() }
            // A chapter still loading holds the old page on its own allowance, not the 60 looks for
            // painting (#38).
            if isLoadingPage, loadingLooks < Self.loadingLooks { loadingLooks += 1; previous = nil; continue }
            waits += 1
            image = await snapshot()
        }
        if waits > 0 {
            readerLog.notice("unfold: held the old page \(ReaderModel.ms(since: waitStart), privacy: .public) ms until the spread had painted (\(waits, privacy: .public) looks)")
        }
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
        let dark = weakModel?.theme.palette.isDark ?? false
        let reduce = weakModel?.reduceMotion ?? false
        // The leaf already rising since the bell carries on from where it is, now with the real page on it.
        let lifted = reduce ? nil : leaf
        if lifted == nil { dropLeaf() }
        let right: UIView
        let shade: CAGradientLayer
        if let lifted {
            leaf = nil
            lifted.lift.stopAnimation(true)
            right = lifted.view
            shade = lifted.shade
            right.layer.transform = right.layer.presentation()?.transform ?? right.layer.transform
            right.layer.bounds = CGRect(x: 0, y: 0, width: frame.width - spine, height: frame.height)
            right.layer.position = CGPoint(x: frame.minX + spine, y: frame.midY)
            shade.frame = right.bounds
            let words = CALayer()
            words.frame = right.bounds
            words.contents = image.cgImage
            words.contentsScale = image.scale
            words.contentsRect = CGRect(x: spine / frame.width, y: 0, width: (frame.width - spine) / frame.width, height: 1)
            right.layer.insertSublayer(words, below: shade)
            let show = CABasicAnimation(keyPath: "opacity")
            show.fromValue = 0
            show.toValue = 1
            show.duration = 0.18
            words.add(show, forKey: "show")
            if let through = lifted.through {
                through.opacity = 0
                let hide = CABasicAnimation(keyPath: "opacity")
                hide.fromValue = 1
                hide.toValue = 0
                hide.duration = 0.18
                through.add(hide, forKey: "hide")
            }
        } else {
            right = half(spine, frame.width - spine)
            shade = Self.leafShade(bounds: right.bounds, dark: dark)
            right.layer.addSublayer(shade)
        }
        left.alpha = 0
        if lifted != nil {
            container.insertSubview(left, belowSubview: cover ?? right)
        } else if let cover {
            // The left page comes up through the old one; the leaf rises over it from the spine, so the
            // old page giving way and the leaf opening read as one gesture, with no bare half between.
            container.insertSubview(left, belowSubview: cover)
            container.insertSubview(right, aboveSubview: cover)
        } else {
            container.insertSubview(left, aboveSubview: page)
            container.insertSubview(right, aboveSubview: page)
        }
        readerLog.notice("unfold: the right page swings open (reduce motion \(reduce, privacy: .public), lifted at the bell \(lifted != nil, privacy: .public))")
        // The old page gives way to the new left page through paper, never through each other: the new
        // one starts only once the old has gone (an overlap showed both layouts at half strength).
        let out = UIViewPropertyAnimator(duration: 0.12, curve: .easeIn) { cover?.alpha = 0 }
        let into = UIViewPropertyAnimator(duration: 0.16, curve: .easeOut) { left.alpha = 1 }
        out.addCompletion { _ in
            cover?.removeFromSuperview()
            into.startAnimation()
        }
        out.startAnimation()
        if reduce {
            right.alpha = 0
            shade.opacity = 0
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                UIView.animate(withDuration: 0.25, delay: 0.1, options: .curveEaseOut) { right.alpha = 1 } completion: { _ in c.resume() }
            }
        } else {
            if lifted == nil {
                right.layer.anchorPoint = CGPoint(x: 0, y: 0.5)
                right.layer.position = CGPoint(x: frame.minX + spine, y: frame.midY)
                right.layer.transform = Self.leafAngle(-.pi * 0.47, width: frame.width)
            }
            let flat = Self.leafAngle(0, width: frame.width)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = 0.8
            fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
            fade.fillMode = .both
            fade.isRemovedOnCompletion = false
            // Edge-on at first, the leaf rises as the old page starts to go.
            if lifted == nil {
                right.isHidden = true
                try? await Task.sleep(for: .milliseconds(60))
                right.isHidden = false
            }
            fade.beginTime = CACurrentMediaTime()
            shade.add(fade, forKey: "lift")
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                // A curve that lands, not a spring that settles: a spring's long tail left the words on
                // the leaf visibly keystoned (tilted) for a third of a second on the tall iPad page.
                let timing = UICubicTimingParameters(controlPoint1: CGPoint(x: 0.3, y: 0.55), controlPoint2: CGPoint(x: 0.45, y: 1))
                let swing = UIViewPropertyAnimator(duration: 0.5, timingParameters: timing)
                swing.addAnimations { right.layer.transform = flat }
                swing.addCompletion { _ in c.resume() }
                swing.startAnimation()
            }
        }
        page.alpha = 1
        left.removeFromSuperview()
        right.removeFromSuperview()
        cover?.removeFromSuperview()
    }

    /// The page on screen, start and end from one live read of the web view, in the document it names;
    /// nil while that document is still loading or isn't the navigator's.
    func pageRange() async -> VisibleRange? {
        return await Self.onSpread {
            let navigator = self.navigator // the one on screen now, on each try
            _ = try await navigator.answer(ReaderJS.install)
            guard let location = navigator.currentLocation else { return nil }
            guard let json = try await navigator.answer(ReaderJS.pageRange) as? String,
                  let data = json.data(using: .utf8) else { return nil }
            struct Found: Decodable { var s: Double; var e: Double; var doc: String }
            guard let found = try? JSONDecoder().decode(Found.self, from: data),
                  ScreenPageGeometry.document(found.doc, isChapter: location.href.string) else { return nil }
            return VisibleRange(href: location.href.string, start: found.s, end: max(found.s, found.e))
        }
    }

    /// What's on screen now: the resource, its progression range and the visible text.
    func visibleRange() async -> VisibleRange? {
        return await Self.onSpread {
            let navigator = self.navigator // the one on screen now, on each try
            _ = try await navigator.answer(ReaderJS.install)
            guard let location = navigator.currentLocation else { return nil }
            let text = try await navigator.answer(ReaderJS.visibleText) as? String
            let start = location.locations.progression ?? 0
            let end = try await navigator.answer(ReaderJS.pageEnd) as? Double
            return VisibleRange(href: location.href.string, start: start, end: max(start, min(1, end ?? start + 0.0001)), text: text)
        }
    }

    /// Where `quote` is in the resource on screen, as a progression; nil when it isn't there.
    func progression(of quote: String) async -> Double? {
        return await Self.onSpread {
            let navigator = self.navigator // the one on screen now, on each try
            _ = try await navigator.answer(ReaderJS.install)
            return try await navigator.answer(ReaderJS.progressionOf(quote)) as? Double
        }
    }

    /// The first words on the page the reader is on.
    func currentAnchor() async -> (ReadingAnchor, Locator)? {
        await Self.onSpread { try await self.readAnchor() }
    }

    private func readAnchor() async throws -> (ReadingAnchor, Locator)? {
        _ = try await navigator.answer(ReaderJS.install)
        guard let location = navigator.currentLocation else { return nil }
        let anchors = weakModel?.contents.fragments(in: location.href.string) ?? []
        let json = try await navigator.answer(ReaderJS.anchor(column: 0, contentsAnchors: anchors)) as? String
        struct Found: Decodable { var highlight: String; var before: String?; var heading: String?; var contents: String? }
        let found = json.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(Found.self, from: $0) }
        weakModel?.heading = found?.heading.map(ReaderJS.tidyHeading)
        weakModel?.contentsFragment = found?.contents
        readerLog.notice("anchor: heading \(found?.heading ?? "none", privacy: .public) contents \(found?.contents ?? "none", privacy: .public) in \(location.href.string, privacy: .public)")
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

    /// Runs `body`'s scripts on the spread on screen. A script whose spread was replaced while it waited
    /// (a reflow, a jump), or that found no spread at all, throws `SpreadChanged` (gatefold#109): it never
    /// ran, and an answer taken from the next script, on another spread, would mix two pages. So `body` runs
    /// again from its start, on the spread that replaced it. Readium makes that spread on its next turn and
    /// each script waits for it to load, so the retry waits on the page, not on a clock. At most `attempts`
    /// runs: nil if the spread changed under every one.
    static func onSpread<T>(_ attempts: Int = 8, _ body: () async throws -> T?) async -> T? {
        for _ in 0..<attempts {
            do {
                return try await body()
            } catch is SpreadChanged {
                await Task.yield()
            } catch {
                return nil
            }
        }
        readerLog.notice("script: no spread answered in \(attempts, privacy: .public) runs (it changed each time, or there is none)")
        return nil
    }

    // MARK: EPUBNavigatorDelegate

    /// A tablet page takes Apple Books' bands above and below the words (`TabletPage`); a phone keeps
    /// Readium's own (the configured insets, or the notch's).
    func navigatorContentInset(_ navigator: VisualNavigator) -> UIEdgeInsets? {
        let traits = self.navigator.view.traitCollection
        guard traits.horizontalSizeClass == .regular, traits.verticalSizeClass == .regular,
              let bands = TabletPage.bands(pageHeight: self.navigator.view.bounds.height) else {
            if weakModel?.tabletBands != nil { weakModel?.tabletBands = nil }
            return nil
        }
        if weakModel?.tabletBands != bands { weakModel?.tabletBands = bands }
        return UIEdgeInsets(top: bands.top, left: 0, bottom: bands.bottom, right: 0)
    }

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
        publishTextBand()
        Task { await model.locationDidChange(locator, duringTurn: isTurning) }
    }

    func navigator(_ navigator: Navigator, presentError error: NavigatorError) {
        model.errorMessage = "This page got itself in a tangle. Try turning again?"
    }

    func navigator(_ navigator: Navigator, didFailToLoadResourceAt href: RelativeURL, withError error: ReadError) {
        model.errorMessage = "Part of this book couldn't be loaded."
    }

    // MARK: Taps

    private func handleTap(at point: CGPoint) -> Bool {
        let width = navigator.view.bounds.width
        // While a jump's veil is up the page beneath is on its way somewhere: a tap then would turn
        // from wherever the jump has got to, and the place he chose is lost.
        guard veil == nil, !jumpStarting else { return true }
        let edge = TapZones.edge(viewWidth: width, spread: model.layout.columns == .two)
        let zone = point.x < edge ? "back" : point.x > width - edge ? "forward" : "middle"
        readerLog.notice("tap: \(zone, privacy: .public) at x \(Int(point.x), privacy: .public) of \(Int(width), privacy: .public), controls \(self.model.chromeVisible, privacy: .public)")
        if model.chromeVisible {
            model.controlsTapped(visible: false)
            return true
        }
        if model.pageTurn == .scroll {
            model.controlsTapped(visible: true)
            return true
        }
        if point.x < edge {
            turn(forward: false)
        } else if point.x > width - edge {
            turn(forward: true)
        } else {
            model.controlsTapped(visible: true)
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
                if moved, Self.probesLanding { let drawn = liveWebFrames(); Task { await reportLanding(drawn: drawn) } }
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
        let t0 = ContinuousClock.now
        let size = navigator.view.bounds.size
        // The page on screen now; a black or bare capture (seen in spreads) is retried.
        let top = await renderedSnapshot(afterChange: false)
        readerLog.notice("turn: \(forward ? "forward" : "back", privacy: .public) page pictured at \(ReaderModel.ms(since: t0), privacy: .public) ms")
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

        let chapterBefore = navigator.currentLocation?.href.string.split(separator: "#").first
        // Where the turn starts, read live from the page (Readium's own location trails a turn by a debounce,
        // so straight after one it can still name the page before): a spring back returns here (#110).
        let live = await pageRange()
        turnFrom = live.flatMap { live in
            navigator.currentLocation?.copy(locations: { $0.progression = CurlRelease.jumpTarget(start: live.start, end: live.end) })
        }
        if let live, let target = turnFrom?.locations.progression {
            readerLog.notice("turn: starts on \(live.href, privacy: .public) read live @\(live.start, privacy: .public)...\(live.end, privacy: .public), target @\(target, privacy: .public)")
        } else {
            readerLog.notice("turn: starts where the page couldn't be read live")
        }
        let moved = forward
            ? await navigator.goForward(options: .init(animated: false))
            : await navigator.goBackward(options: .init(animated: false))
        readerLog.notice("turn moved=\(moved, privacy: .public) at \(ReaderModel.ms(since: t0), privacy: .public) ms")
        guard moved, weakModel != nil else {
            curl.reset()
            isTurning = false
            turnFrom = nil
            // Past the last page there is no page: there is the end leaf.
            if forward, let model = weakModel { model.reachedEnd() } else {
                UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.4)
            }
            return false
        }
        // Wait until the destination has painted and stopped changing (a spread lays out two
        // columns; caught halfway it ghosts).
        curl.beneath = await renderedSnapshot(afterChange: true)
        beneathFrames = lastSnapshotFrames
        // Counted from the tap, not after it: a test's tap waits for the app to go idle, which hides the wait.
        // Judged once the page beneath has painted, when the navigator reports the chapter it shows.
        let crossed = navigator.currentLocation?.href.string.split(separator: "#").first != chapterBefore
        turnsPictured += 1
        readerLog.notice("turn: \(self.turnsPictured, privacy: .public) waited \(self.lastSnapshotLooks, privacy: .public) looks for the page beneath, \(crossed ? "into another chapter" : "within the chapter", privacy: .public)")
        if LaunchOptions.isUITest { weakModel?.turnWaitProbe = "\(turnsPictured) \(lastSnapshotLooks) \(crossed ? 1 : 0)" }
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
        let landing = CurlTiming.landing(isSpread: curl.isSpread)
        let duration = complete ? landing.duration : 0.3
        let settle = complete && curl.isSpread && curl.style == .curl && Self.probesLanding ? watchSettle(forward: !curl.mirrored) : nil
        if curl.style == .fade {
            withAnimation(.easeInOut(duration: 0.22)) { curl.fade = complete ? 1 : 0 }
            try? await Task.sleep(for: .milliseconds(240))
        } else {
            let target = complete ? turnedTarget() : curl.corner
            // The overlay lifts when the leaf has landed, not on a timer: on a busy device a timer
            // can end the turn with the leaf still beside the page, and the page then snaps in.
            // A timer a little past the curve's end backs it up, in case the completion never comes
            // (the book closed or the view left the window mid-turn); whichever is first resumes.
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                var resumed = false
                let resume = { if !resumed { resumed = true; c.resume() } }
                withAnimation(complete ? landing.animation : .timingCurve(0.3, 0.1, 0.25, 1, duration: duration), completionCriteria: .removed) {
                    curl.finger = target
                } completion: { resume() }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(duration + 0.25))
                    resume()
                }
            }
        }
        if !complete {
            // Put the navigator back where it was before lifting the overlay.
            let navigator = navigator
            await CurlRelease.springBack(to: turnFrom, mirrored: curl.mirrored,
                                         go: { await navigator.go(to: $0, options: .init(animated: false)) },
                                         step: { $0 ? await navigator.goForward(options: .init(animated: false))
                                                    : await navigator.goBackward(options: .init(animated: false)) })
            try? await Task.sleep(for: .milliseconds(120))
            await confirmSpringBack()
        }
        turnFrom = nil
        let uncovered = curl.beneath
        curl.reset()
        isTurning = false
        if complete, Self.probesLanding { let drawn = beneathFrames; Task { await reportLanding(drawn: drawn, image: uncovered) } }
        settle?.landed = .now
        // Record the place once the turn has landed, not while the overlay hid it. A turn that sprang
        // back is no move: just take the anchor again from the page that's showing.
        if complete {
            weakModel?.userTurnedPage()
        } else if let model = weakModel {
            Task { await model.captureAnchor() }
        }
    }

    /// Lands a turn whose leaf was lifted on the reopen picture: the live page moves on beneath the
    /// picture, the leaf's underside becomes that page, and the leaf turns away over it. Returns false
    /// (the leaf laid back down) at the start or end of the book.
    func landLiftedTurn(forward: Bool, curl lifted: CurlModel) async -> Bool {
        guard !isTurning else { return false }
        isTurning = true
        defer { isTurning = false }
        lifted.holding = false
        let moved = forward
            ? await navigator.goForward(options: .init(animated: false))
            : await navigator.goBackward(options: .init(animated: false))
        guard moved else {
            withAnimation(.easeOut(duration: 0.25)) { lifted.finger = lifted.corner }
            try? await Task.sleep(for: .milliseconds(270))
            if forward { weakModel?.reachedEnd() }
            return false
        }
        lifted.beneath = await renderedSnapshot(afterChange: true)
        let t = lifted.turnedFinger
        let target = lifted.mirrored ? CGPoint(x: lifted.size.width - t.x, y: t.y) : t
        let landing = CurlTiming.landing(isSpread: lifted.isSpread)
        let flight = lifted.isSpread ? landing.duration : 0.42
        withAnimation(lifted.isSpread ? landing.animation : .timingCurve(0.3, 0.1, 0.25, 1, duration: 0.42)) { lifted.finger = target }
        try? await Task.sleep(for: .seconds(flight + 0.02))
        return true
    }

    /// The page a spring back left on screen, read live, against where the turn started; one more jump if it's
    /// elsewhere. Logged either way, as the walk's evidence (#110).
    private func confirmSpringBack() async {
        guard let start = turnFrom, let p = start.locations.progression else {
            readerLog.notice("turn: sprang back by a step (the start wasn't read)")
            return
        }
        func here() async -> ClosedRange<Double>? {
            _ = await navigator.evaluateJavaScript(ReaderJS.install)
            guard let json = (try? await navigator.evaluateJavaScript(ReaderJS.pageRange).get()) as? String,
                  let data = json.data(using: .utf8) else { return nil }
            struct Found: Decodable { var s: Double; var e: Double; var doc: String }
            guard let found = try? JSONDecoder().decode(Found.self, from: data),
                  ScreenPageGeometry.document(found.doc, isChapter: start.href.string) else { return nil }
            return found.s...max(found.s, found.e)
        }
        var now = await here()
        var again = false
        if !(now.map { CurlRelease.isOn(p, page: $0) } ?? false) {
            again = true
            _ = await navigator.go(to: start, options: .init(animated: false))
            try? await Task.sleep(for: .milliseconds(120))
            now = await here()
        }
        let ok = now.map { CurlRelease.isOn(p, page: $0) } ?? false
        readerLog.notice("turn: sprang back to \(start.href.string, privacy: .public) landed @\(now?.lowerBound ?? -1, privacy: .public)...\(now?.upperBound ?? -1, privacy: .public) (target @\(p, privacy: .public))\(again ? " after a second jump" : "", privacy: .public) -> \(ok ? "same page" : "elsewhere", privacy: .public)")
    }

    private var beneathFrames: [CGRect] = []
    /// Where a curl turn started, to put the page back if it springs back.
    private var turnFrom: Locator?

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
            // Timed by the touches themselves, never by when the main thread got round to them (#110).
            let still = (pan as? CurlPan)?.stillBeforeLift ?? 0
            let complete = pan.state != .cancelled
                && CurlRelease.completes(forward: panForward, dx: dx, width: view.bounds.width, velocity: v, stillFor: still)
            readerLog.notice("turn: let go v \(Int(v), privacy: .public) dx \(Int(dx), privacy: .public) of \(Int(self.view.bounds.width), privacy: .public) still \(Int(still * 1000), privacy: .public) ms -> \(complete ? "turns" : "springs back", privacy: .public)")
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
        guard model.pageTurn == .curl || model.pageTurn == .fade, !isTurning, veil == nil, !jumpStarting else { return false }
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
    /// A jump has begun (its old page is being pictured for the veil): no tap or swipe turns meanwhile.
    private var jumpStarting = false

    /// Runs a jump with the old page left on screen, dimmed to 60 %, until the new page has painted;
    /// then the old page cross-fades away over 0.2 s (no blank page, no spinner). With `riffle`, a few
    /// leaves flick past first.
    func veiledJump(riffle: Bool, forward: Bool, jump: Int, _ body: @escaping () async -> Void) async {
        guard veil == nil, !jumpStarting, !isTurning, view.window != nil else { return await body() }
        jumpStarting = true
        veilJump = jump
        let jumpTapped = ContinuousClock.now
        // UI tests: the old page reads as still loading (spinner up, page bare) while it is pictured.
        let heldBefore = heldLoadLooks
        if LaunchOptions.isUITest, let looks = LaunchOptions.holdOldPageLoadLooks, looks > 0 {
            heldLoadLooks = max(heldLoadLooks, looks)
            if oldPageHeldMarker == nil {
                let marker = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
                marker.isAccessibilityElement = true
                marker.accessibilityIdentifier = "reader.oldPageHeld"
                view.addSubview(marker)
                oldPageHeldMarker = marker
            }
        }
        // The jump he chose starts now: the old page is pictured as it is, never waited on while it
        // loads (its spinner held the jump back up to 60 s, and the page never moved: gatefold#73).
        let old = await renderedSnapshot(afterChange: false, waitsForLoad: false)
        if LaunchOptions.isUITest, LaunchOptions.holdOldPageLoadLooks != nil { heldLoadLooks = heldBefore }
        jumpStarting = false
        readerLog.notice("veil: jump \(jump, privacy: .public) pictured the old page in \(ReaderModel.ms(since: jumpTapped), privacy: .public) ms, \(self.lastSnapshotLooks, privacy: .public) looks")
        // Let go of while its old page was being pictured (`abandonVeil`): no cover goes up.
        guard veilJump == jump else { return await body() }
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
        if LaunchOptions.isUITest {
            cover.isAccessibilityElement = true
            cover.accessibilityIdentifier = "reader.veil"
            holdChapterLoadForTest()
        }
        // The running head stays with the page on screen: it changes chapter as the new page is revealed.
        // Let go only while the cover is still this jump's: an abandoned one leaves a newer jump's head.
        weakModel?.heldRunningHead = .some(weakModel?.chapterTitle)
        if riffle {
            // The thumb starts riffling at once and keeps going while the far chapter loads, so the
            // wait is the riffle, never a dimmed page.
            var arrived = false
            let travel = Task { @MainActor in
                await body()
                arrived = true
                readerLog.notice("veil: jump \(jump, privacy: .public) arrived \(ReaderModel.ms(since: jumpTapped), privacy: .public) ms after it began (riffle)")
            }
            await riffleLeaves(from: old, cover: cover, forward: forward, arrived: { arrived }) { [weak self] in
                await travel.value
                let page = await self?.renderedSnapshot(afterChange: true) ?? old
                readerLog.notice("veil: jump \(jump, privacy: .public) pictured its page \(ReaderModel.ms(since: jumpTapped), privacy: .public) ms after it began, \(self?.lastSnapshotLooks ?? -1, privacy: .public) looks")
                return page
            }
            readerLog.notice("veil: jump \(jump, privacy: .public) lifted \(ReaderModel.ms(since: jumpTapped), privacy: .public) ms after it began")
            cover.removeFromSuperview()
            if veil === cover { veil = nil; veilJump = nil }
            return
        }
        let dim = UIViewPropertyAnimator(duration: 0.15, curve: .easeOut) { wash.alpha = 0.4 }
        dim.startAnimation()
        await body()
        readerLog.notice("veil: jump \(jump, privacy: .public) arrived \(ReaderModel.ms(since: jumpTapped), privacy: .public) ms after it began")
        _ = await renderedSnapshot(afterChange: true)
        readerLog.notice("veil: jump \(jump, privacy: .public) pictured its page \(ReaderModel.ms(since: jumpTapped), privacy: .public) ms after it began, \(self.lastSnapshotLooks, privacy: .public) looks")
        // The head changes chapter with the page, cross-fading as the veil lifts.
        if veil === cover { withAnimation(.easeInOut(duration: 0.2)) { weakModel?.heldRunningHead = nil } }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) {
                cover.alpha = 0
            } completion: { _ in done.resume() }
        }
        cover.removeFromSuperview()
        readerLog.notice("veil: jump \(jump, privacy: .public) lifted \(ReaderModel.ms(since: jumpTapped), privacy: .public) ms after it began")
        // Its own cover only: one abandoned meanwhile (`abandonVeil`) may have made way for a newer one.
        if veil === cover { veil = nil; veilJump = nil }
    }
    /// The jump whose veil is up, or whose old page is being pictured for one.
    private var veilJump: Int?

    /// Lifts the veil of a jump that never came back (a Back freed by its count): the reader gets the
    /// page and his taps back, and the next jump puts up a veil of its own. The hung jump, if it ever
    /// returns, takes down only its own cover.
    /// Only `jump`'s own veil: a jump that ran unveiled under another's leaves that one alone.
    func abandonVeil(jump: Int) {
        guard veilJump == jump else { return }
        veilJump = nil
        guard let cover = veil else {
            readerLog.notice("veil: a jump that never came back puts up no cover")
            return
        }
        readerLog.notice("veil: a jump that never came back lets go of the page")
        veil = nil
        withAnimation(.easeInOut(duration: 0.2)) { weakModel?.heldRunningHead = nil }
        UIView.animate(withDuration: 0.2, animations: { cover.alpha = 0 }, completion: { _ in cover.removeFromSuperview() })
    }

    /// Fast leaves curl away, like a thumb riffling to a place: at least three, more while the far
    /// page is still on its way, and the last one uncovers it.
    private func riffleLeaves(from old: UIImage, cover: UIView, forward: Bool, arrived: @escaping () -> Bool, fresh: @escaping () async -> UIImage) async {
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
        // Leaves of the old page over itself until the new one is ready and pictured (a riffle through
        // pages in between); capped so a lost load still ends. The picture is taken while the leaves
        // keep turning, so the thumb never stops on the bare old page waiting for it: one sweep.
        let t0 = ContinuousClock.now
        var page: UIImage?
        let picturing = Task { @MainActor in page = await fresh() }
        while i < 3 || (page == nil && i < 40) {
            await leaf(top: old, beneath: old, index: i, size: size, forward: forward, duration: 0.12)
            i += 1
        }
        await picturing.value
        readerLog.notice("riffle: \(i, privacy: .public) leaves, new page pictured at \(ReaderModel.ms(since: t0), privacy: .public) ms")
        // The last leaf uncovers the new page, and its chapter comes up in the head as it does:
        // the head cross-fades while the leaf turns away, not after.
        let last = 0.28
        let head = Task { @MainActor in
            try? await Task.sleep(for: .seconds(last * 0.4))
            guard self.veil === cover else { return }
            withAnimation(.easeInOut(duration: last * 0.6)) { model.heldRunningHead = nil }
        }
        await leaf(top: old, beneath: page ?? old, index: i, size: size, forward: forward, duration: last)
        await head.value
        cover.alpha = 0
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

    private var underlineTask: Task<Void, Never>?

    /// Underlines the other device's words with the ribbon colour: drawn in over 0.6 s, held while the
    /// Back pill is up (8 s), then faded. A page turn takes it away sooner (`clearUnderline`).
    func underline(_ locator: Locator, color: UInt32) {
        guard let quote = locator.text.highlight, !quote.isEmpty else { return }
        // The mark ends where a word does, not where the quote's character count did.
        let edge = WordEdge.complete(highlight: quote, after: locator.text.after)
        let locator = locator.copy(text: { $0.highlight = edge.highlight; $0.after = edge.after })
        let decoration = Decoration(id: "sync", locator: locator, style: .init(id: .gatefoldSync, config: ThemePalette.hexString(color)))
        navigator.apply(decorations: [decoration], in: "gatefold-sync")
        underlineTask?.cancel()
        underlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(9))
            guard !Task.isCancelled else { return }
            self?.clearUnderline()
        }
    }

    func clearUnderline() {
        underlineTask?.cancel()
        underlineTask = nil
        navigator.apply(decorations: [], in: "gatefold-sync")
    }

    /// For UI tests: how many underline boxes are on screen and drawn (opaque).
    func underlineProbe() async -> Int {
        let js = """
        (() => { const vw = window.innerWidth, vh = window.innerHeight;
          return Array.from(document.querySelectorAll('.gatefold-sync')).filter((e) => {
            const r = e.getBoundingClientRect();
            return r.width > 0 && r.right > 0 && r.left < vw && r.bottom > 0 && r.top < vh && parseFloat(getComputedStyle(e).opacity) > 0.5;
          }).length; })()
        """
        var count = 0
        func walk(_ v: UIView) -> [WKWebView] {
            if let w = v as? WKWebView { return w.isHidden || w.alpha < 0.01 ? [] : [w] }
            return v.subviews.flatMap(walk)
        }
        for web in walk(navigator.view) {
            if let n = (try? await web.evaluateJavaScript(js)) as? Int { count += n }
        }
        return count
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

    /// Where paper laid over the page's foot may end (window points): in the gap above the highest line
    /// of text that reaches into `band`, below the last line kept whole, so its descenders are never cut.
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
            if(q.bottom>y0&&q.top<y1&&(best<0||q.top<best))best=q.top;}}
            if(best<0)return -1;var above=-1;tw=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);
            while((n=tw.nextNode())){if(!n.textContent.trim())continue;r.selectNodeContents(n);var rs=r.getClientRects();
            for(var i=0;i<rs.length;i++){var q=rs[i];if(q.width<1||q.right<=0||q.left>=w)continue;
            if(q.top<best-1&&q.bottom>above)above=q.bottom;}}
            if(above<0)return best-3;var gap=best-above;return gap>=2?above+Math.min(1.5,gap/2):(above+best)/2;})(\(y0),\(y1))
            """
            guard let top = (try? await web.evaluateJavaScript(js)) as? Double, top >= 0 else { continue }
            let y = web.convert(CGPoint(x: 0, y: CGFloat(top)), to: window).y
            best = min(best ?? y, y)
        }
        return best
    }

    /// A page that opens partway into its file is kept hidden by Readium, spinner up, for a fixed
    /// 0.3 s after it has scrolled there ("the rendering is sometimes very slow"), on top of 0.2 s
    /// before it scrolls. That 0.3 s was most of a warm book's open. Instead, each hidden page in view
    /// is shown as soon as it has scrolled to its place and painted a frame there.
    func unveilPlacedPages() async {
        guard let host = navigator.view else { return }
        var hidden: [WKWebView] = []
        func walk(_ v: UIView) {
            if let w = v as? WKWebView {
                if w.scrollView.alpha < 0.01, !w.isLoading, w.window != nil,
                   w.convert(w.bounds, to: host).intersects(host.bounds) { hidden.append(w) }
                return
            }
            v.subviews.forEach(walk)
        }
        walk(host)
        for web in hidden {
            // Scrolled off the file's first page: Readium has been to the place (before, the view
            // is still at its start). Then two frames, so the words at the place are painted.
            let placed = try? await web.callAsyncJavaScript(
                """
                if (!(window.readium && window.readium.link) || window.scrollX === 0) { return 0; }
                await Promise.race([
                    new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))),
                    new Promise(r => setTimeout(r, 80))
                ]);
                return window.scrollX === 0 ? 0 : 1;
                """, contentWorld: .page)
            guard (placed as? NSNumber)?.intValue == 1, web.scrollView.alpha < 0.01 else { continue }
            web.scrollView.alpha = 1
            func stopSpinner(_ v: UIView) {
                if let a = v as? UIActivityIndicatorView { a.stopAnimating(); return }
                v.subviews.forEach(stopSpinner)
            }
            if let spread = web.superview { stopSpinner(spread) }
            readerLog.notice("open: page shown once placed and painted, not after Readium's fixed wait")
        }
    }

    /// Which pages of a spread picture carry words: left of `spine` (a fraction of the width), and right.
    private static func paintedHalves(_ image: UIImage, spine: CGFloat, paper: UInt8) -> (left: Bool, right: Bool) {
        func painted(_ cg: CGImage?) -> Bool {
            guard let cg, let signature = PageSignature(UIImage(cgImage: cg)) else { return true }
            return !signature.isBare(paper: paper) && !signature.isBlack(paper: paper)
        }
        guard let cg = image.cgImage else { return (true, true) }
        let split = Int((CGFloat(cg.width) * spine).rounded())
        guard split > 8, split < cg.width - 8 else { let whole = painted(cg); return (whole, whole) }
        return (painted(cg.cropping(to: CGRect(x: 0, y: 0, width: split, height: cg.height))),
                painted(cg.cropping(to: CGRect(x: split, y: 0, width: cg.width - split, height: cg.height))))
    }

    /// Looks left in a load held open for a test (`-GatefoldHoldChapterLoad`), and its marker.
    private var heldLoadLooks = 0
    private var heldLoadMarker: UIView?
    /// UI tests: up once a jump's old page has been held as loading, so a test knows the hold armed.
    private var oldPageHeldMarker: UIView?

    private func holdChapterLoadForTest() {
        guard let looks = LaunchOptions.holdChapterLoadLooks, looks > 0 else { return }
        holdLoadForTest(looks: looks)
    }

    private func holdLoadForTest(looks: Int) {
        heldLoadMarker?.removeFromSuperview()
        heldLoadLooks = max(heldLoadLooks, looks)
        let marker = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        marker.isAccessibilityElement = true
        marker.accessibilityIdentifier = "reader.loadingHeld"
        view.addSubview(marker)
        heldLoadMarker = marker
    }

    /// Readium's own loading spinner is showing: the page in view hasn't loaded yet.
    var isLoadingPage: Bool {
        if heldLoadLooks > 0 {
            heldLoadLooks -= 1
            if heldLoadLooks == 0 { heldLoadMarker?.removeFromSuperview(); heldLoadMarker = nil }
            return true
        }
        return readiumSpinner != nil
    }

    /// Readium's spinner in view, if one is up, and where: the frame in the navigator's view.
    private var readiumSpinner: CGRect? {
        let host = navigator.view!
        func spinning(_ v: UIView) -> CGRect? {
            guard !v.isHidden, v.alpha > 0.01 else { return nil }
            if let a = v as? UIActivityIndicatorView {
                let frame = a.convert(a.bounds, to: host)
                return a.isAnimating && frame.intersects(host.bounds) ? frame : nil
            }
            for sub in v.subviews { if let f = spinning(sub) { return f } }
            return nil
        }
        return spinning(host)
    }

    /// Where Readium's spinner is and what the page is, for a log line: no words, only geometry and
    /// the chapter's file. Which web view it sits in (one per spread) says what is loading.
    private func spinnerReport() -> String {
        let host = navigator.view!
        let at = readiumSpinner.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "gone"
        var webs: [String] = []
        func walk(_ v: UIView) {
            if let w = v as? WKWebView {
                let f = w.convert(w.bounds, to: host)
                if f.intersects(host.bounds) { webs.append("\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)) loading \(w.isLoading)") }
                return
            }
            v.subviews.forEach(walk)
        }
        walk(host)
        let file = navigator.currentLocation?.href.string.split(separator: "/").last.map(String.init) ?? "none"
        return "spinner at \(at) of \(Int(host.bounds.width))x\(Int(host.bounds.height)); web views in view [\(webs.joined(separator: "; "))]; at \(file) @\(navigator.currentLocation?.locations.progression ?? -1)"
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
        lastSnapshotFrames = webs.map(\.1)
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
    /// Returns once the page on screen has painted and stopped changing.
    func waitForSettledPage() async {
        _ = await renderedSnapshot(afterChange: true)
    }

    /// Where the web views sat in the host for the last snapshot: the turn's leaf and the page beneath
    /// are drawn from them, so the live page must be at the same place when the overlay lifts.
    private(set) var lastSnapshotFrames: [CGRect] = []
    /// How many looks (about 50 ms each, counted, not timed) the last `renderedSnapshot` took.
    private(set) var lastSnapshotLooks = 0
    private var landedTurns = 0

    /// The visible web views' frames in the host now.
    private func liveWebFrames() -> [CGRect] {
        let host = navigator.view!
        var out: [CGRect] = []
        func walk(_ v: UIView) {
            if let w = v as? WKWebView {
                let frame = w.convert(w.bounds, to: host)
                if !w.isHidden, w.alpha > 0.01, frame.intersects(host.bounds) { out.append(frame) }
                return
            }
            v.subviews.forEach(walk)
        }
        walk(host)
        return out
    }

    /// After a turn: did the page beneath the overlay (as drawn) and the live page agree, and did the
    /// live page stay put once the overlay lifted? Logged always; published for UI tests.
    /// Where the words begin and end on the page, from the web views themselves.
    private func publishTextBand() {
        let frames = liveWebFrames()
        guard let first = frames.first else { return }
        let text = frames.dropFirst().reduce(first) { $0.union($1) }
        let band = (top: max(0, text.minY), bottom: max(0, navigator.view.bounds.height - text.maxY))
        if let model = weakModel, model.textBand != band {
            model.textBand = band
        }
    }

    /// The landing probe only runs in debug builds and UI tests: it costs a snapshot per turn.
    private static let probesLanding: Bool = {
        #if DEBUG
        true
        #else
        ProcessInfo.processInfo.arguments.contains("-GatefoldUITest")
        #endif
    }()

    /// One spread turn's settle watch: the outer page's text edge in each frame drawn. `landed` is
    /// set when the leaf lands; the watch then runs on for at least `samplesAfterLanding` samples and
    /// no less than half a second, so a slow device still gets enough frames to judge (#52).
    private final class SettleWatch { var landed: ContinuousClock.Instant? }
    private static let samplesAfterLanding = 6
    private var settledTurns = 0

    /// Debug builds and UI tests: watches the outer page of a spread (the left one turning forward,
    /// the right one turning back) in every frame it can draw, from the turn's last leg until at
    /// least six samples and 0.5 s after the leaf has landed, and reports how far its words ever
    /// started from where they rest.
    /// The landing report measures only once the overlay has lifted, so it can't see a leaf that
    /// lands beside the page and is then replaced by the live one (build 14 on the iPad spread).
    private func watchSettle(forward: Bool) -> SettleWatch {
        let watch = SettleWatch()
        let paper = PageSignature.rgb(weakModel?.theme.uiBackground ?? .white)
        let dump = UserDefaults.standard.bool(forKey: "GatefoldDumpSettle")
        let turn = settledTurns + 1
        settledTurns = turn
        Task { [weak self] in
            var edges: [CGFloat] = []
            var frame = 0
            var afterLanding = 0
            while let self {
                if let landed = watch.landed {
                    let since = ContinuousClock.now - landed
                    if afterLanding >= Self.samplesAfterLanding, since >= .milliseconds(500) { break }
                    // The page left the window (no samples can be drawn): stop rather than spin.
                    if since >= .seconds(5) { break }
                }
                if let (image, edge) = self.settleSample(forward: forward, paper: paper) {
                    if let edge { edges.append(edge) }
                    if dump {
                        let url = URL.temporaryDirectory.appending(path: "settle-\(turn)-\(String(format: "%03d", frame)).png")
                        try? image.pngData()?.write(to: url)
                    }
                    frame += 1
                    if watch.landed != nil { afterLanding += 1 }
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
            guard let self, let rest = edges.last else { return }
            // Positive: the words started further out than where they rest (toward the outer edge).
            let worst = edges.map { forward ? rest - $0 : $0 - rest }.max() ?? 0
            let line = "settle \(turn) frames \(frame) worst \(Int(worst.rounded())) pt"
            readerLog.notice("turn: \(line, privacy: .public) edges \(edges.map { Int($0) }, privacy: .public)")
            self.weakModel?.turnSettle = line
        }
        return watch
    }

    /// The page as on screen now (overlay included), and where the outer page's words begin: the
    /// leftmost ink on the left page, or the rightmost on the right page, in window points.
    private func settleSample(forward: Bool, paper: UInt8) -> (UIImage, CGFloat?)? {
        guard let window = view.window else { return nil }
        let page = navigator.view.convert(navigator.view.bounds, to: window)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: page.size, format: format).image { _ in
            window.drawHierarchy(in: CGRect(origin: CGPoint(x: -page.minX, y: -page.minY), size: window.bounds.size), afterScreenUpdates: false)
        }
        guard let cg = image.cgImage else { return (image, nil) }
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return (image, nil) }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let paperLuma = Double(paper) / 255
        // The body of the outer page only: past the running head and page number.
        let columns = forward ? Array(0..<(w / 2)) : Array((w / 2..<w).reversed())
        let rows = stride(from: h / 5, to: h * 4 / 5, by: 2)
        for x in columns {
            var ink = 0
            for y in rows {
                let i = (y * w + x) * 4
                let luma = (0.299 * Double(px[i]) + 0.587 * Double(px[i + 1]) + 0.114 * Double(px[i + 2])) / 255
                if abs(luma - paperLuma) > 0.3 { ink += 1 }
            }
            if ink >= 3 { return (image, page.minX + CGFloat(x)) }
        }
        return (image, nil)
    }

    private func reportLanding(drawn: [CGRect], image: UIImage? = nil) async {
        let overlay = curlHost.view.convert(curlHost.view.bounds, to: nil)
        let page = navigator.view.convert(navigator.view.bounds, to: nil)
        let atLift = liveWebFrames()
        try? await Task.sleep(for: .milliseconds(500))
        let rest = liveWebFrames()
        func close(_ a: [CGRect], _ b: [CGRect]) -> Bool {
            a.count == b.count && zip(a.sorted { $0.minX < $1.minX }, b.sorted { $0.minX < $1.minX }).allSatisfy {
                abs($0.minX - $1.minX) < 0.5 && abs($0.minY - $1.minY) < 0.5 && abs($0.width - $1.width) < 0.5
            }
        }
        let overlayOK = abs(overlay.minX - page.minX) < 0.5 && abs(overlay.width - page.width) < 0.5
        // The words too: the picture the leaf uncovered and the live page, a moment later, are one page.
        var sameWords = true
        if let image, let before = PageSignature(image), let after = PageSignature(await snapshot()) {
            sameWords = before.matches(after)
        }
        let inPlace = overlayOK && close(drawn, atLift) && close(atLift, rest) && sameWords
        landedTurns += 1
        func list(_ r: [CGRect]) -> String { r.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" }.joined(separator: "; ") }
        let line = "landed \(landedTurns) overlay \(Int(overlay.minX)) page \(Int(page.minX)) drawn [\(list(drawn))] lift [\(list(atLift))] rest [\(list(rest))] words \(sameWords ? "same" : "differ") " + (inPlace ? "in place" : "moved")
        readerLog.notice("turn: \(line, privacy: .public)")
        weakModel?.turnPlacement = line
    }

    /// With `waitsForLoad` false the page is pictured as it is, a few tries at most, however long
    /// Readium's spinner stays up: a jump's old page.
    func renderedSnapshot(afterChange: Bool, waitsForLoad: Bool = true) async -> UIImage {
        let paper = PageSignature.rgb(weakModel?.theme.uiBackground ?? .white)
        var last: (UIImage, PageSignature)?
        // A turn or a jump into a chapter still loading holds the old page until it has: as long as
        // Readium's spinner is up (its own allowance of looks), else up to 40 looks for a page that is
        // still bare. The spinner's allowance was 8 s in all: on CI's iPad a Contents jump's chapter
        // took over 25 s, and the veil lifted onto a blank page and a spinner.
        var loadingLooks = 0
        var attempt = 0
        defer { lastSnapshotLooks = loadingLooks + attempt }
        let attempts = waitsForLoad ? 40 : 10
        while attempt < attempts {
            if afterChange || attempt > 0 || loadingLooks > 0 { try? await Task.sleep(for: .milliseconds(attempt == 0 && loadingLooks == 0 ? 60 : 50)) }
            if attempt == 0, loadingLooks == 0, heldLoadLooks == 0, readiumSpinner != nil {
                readerLog.notice("snapshot: Readium's spinner is up \(afterChange ? "on the page beneath" : "on the page in view", privacy: .public): \(self.spinnerReport(), privacy: .public)")
            }
            if waitsForLoad, isLoadingPage {
                await unveilPlacedPages()
                if isLoadingPage, loadingLooks < Self.loadingLooks { loadingLooks += 1; last = nil; continue }
            }
            defer { attempt += 1 }
            let image = await snapshot()
            guard let signature = PageSignature(image) else { return image }
            // A test's held load (`holdOldPageLoadLooks`) pictures the old page as a bare one, the
            // way a page still loading looks, so the few tries and the fallback below are what run.
            let heldBare = !waitsForLoad && !afterChange && heldLoadLooks > 0
            let usable = !heldBare && !signature.isBlack(paper: paper) && !signature.isBare(paper: paper)
            if usable, !afterChange { return image }
            if usable, let (_, previous) = last, previous.matches(signature) { return image }
            if usable { last = (image, signature) }
            if !usable { readerLog.notice("snapshot \(attempt) unusable: black=\(signature.isBlack(paper: paper)) bare=\(signature.isBare(paper: paper))") }
        }
        if loadingLooks > 0 { readerLog.notice("veil: held the old page \(loadingLooks, privacy: .public) looks while the chapter loaded") }
        if let last { return last.0 }
        let final = await snapshot()
        // A page pictured as it is never shows black under a jump's veil: an empty picture lets the
        // veil's paper show instead.
        if !waitsForLoad, let signature = PageSignature(final), signature.isBlack(paper: paper) {
            let color = weakModel?.theme.uiBackground ?? .white
            return UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            }
        }
        return final
    }

    /// How many looks (about 50 ms each) the old page is held while Readium's spinner is up.
    static let loadingLooks = 1200

    /// Waits while Readium's spinner is up, showing a page that has scrolled into place as soon as it
    /// has painted; returns the looks it took. Nothing that covers the page (the opening cover, the
    /// reopen picture, a reflow's cover, a jump's veil) lifts onto the spinner: it waits here first,
    /// counted in looks, not seconds (#38).
    @discardableResult
    func waitWhileLoading() async -> Int {
        var looks = 0
        while isLoadingPage, looks < Self.loadingLooks {
            await unveilPlacedPages()
            guard isLoadingPage else { break }
            looks += 1
            try? await Task.sleep(for: .milliseconds(50))
        }
        if looks > 0 { readerLog.notice("veil: waited \(looks, privacy: .public) looks for the chapter to load") }
        return looks
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
    /// A ribbon-coloured underline that draws itself in from the left, holds with the Back pill, then fades.
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
            animation: gatefold-draw 0.6s ease-out forwards, gatefold-fade 1s ease-in 7.6s forwards;
        }
        @media (prefers-reduced-motion: reduce) {
            .gatefold-sync { clip-path: none; animation: gatefold-fade 1s ease-in 7.6s forwards; }
        }
        @keyframes gatefold-draw { to { clip-path: inset(0 0 0 0); } }
        @keyframes gatefold-fade { from { opacity: 1; } to { opacity: 0; } }
        """
    ) }
}

/// Counts a turn's frames and the ones that came late (more than half a frame past due), for the log.
@MainActor
final class FrameWatch: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var frames = 0, late = 0
    private var worst: CFTimeInterval = 0

    func start() {
        link?.invalidate()
        frames = 0; late = 0; worst = 0; last = 0
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        defer { last = link.timestamp }
        guard last > 0 else { return }
        frames += 1
        let gap = link.timestamp - last
        let due = link.targetTimestamp - link.timestamp
        worst = max(worst, gap)
        if due > 0, gap > due * 1.5 { late += 1 }
    }

    func stop(counting: Bool) {
        guard let link else { return }
        link.invalidate()
        self.link = nil
        readerLog.notice("turn frames: \(self.frames, privacy: .public) frames, \(self.late, privacy: .public) late, worst \(Int(self.worst * 1000), privacy: .public) ms, counting \(counting, privacy: .public)")
    }
}

/// A counter's only delegate: it lays the chapter out in the page's bands and answers nothing else, so
/// its moves never reach the reader (`ReaderHostController.countPages`).
@MainActor
private final class CountingInsets: NSObject, EPUBNavigatorDelegate {
    private let inset: () -> UIEdgeInsets?
    init(_ inset: @escaping () -> UIEdgeInsets?) { self.inset = inset }
    func navigatorContentInset(_ navigator: VisualNavigator) -> UIEdgeInsets? { inset() }
    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {}
    func navigator(_ navigator: Navigator, presentError error: NavigatorError) {}
}

/// A script found no spread to run on, or its spread was replaced while it waited (gatefold#109).
struct SpreadChanged: Error {}

extension EPUBNavigatorViewController {
    /// A script's answer on the spread on screen, nil if it ran and failed there. Throws `SpreadChanged`
    /// when it never ran: Readium's `spreadNotLoaded`, for no spread yet or one cleared while it waited.
    func answer(_ script: String) async throws -> Any? {
        switch await evaluateJavaScript(script) {
        case let .success(value):
            return value
        case let .failure(error):
            if let error = error as? EPUBNavigatorViewController.EPUBError, case .spreadNotLoaded = error { throw SpreadChanged() }
            return nil
        }
    }
}
