import GatefoldCore
import ReadiumShared
import SwiftUI
import WebKit

@main
struct GatefoldApp: App {
    @State private var app: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Until the first frame, iOS shows the launch screen in the system's appearance, not the book's
        // paper: a Midnight reopen in light mode flashes light paper. The app can't theme that screen;
        // it can only reach its own first (already Midnight) frame sooner, so the time is logged.
        let entered = LaunchClock.sinceLaunch
        #if DEBUG
        MainThreadWatch.startIfUITest()
        #endif
        _app = State(initialValue: AppModel())
        readerLog.notice("launch: app entered \(entered, privacy: .public) s after the process started; model ready at \(LaunchClock.sinceLaunch, privacy: .public) s")
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .task { await app.start() }
                .task { LaunchClock.firstFrame(); await WebWarmup.startUnlessABookOpens() }
                #if DEBUG
                .task { LaunchMarkRenderer.renderIfAsked() }
                .task { await SystemInsetInjector.runIfAsked() }
                #endif
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                ReopenSnapshot.setAside()
                Task { await app.didBecomeActive() }
            case .inactive:
                // He may be leaving: a move a reflow still owes is kept now, in case that reflow never
                // ends (gatefold#96); the push below waits for it.
                let owed = app.activeReader?.owedPlaceOnLeaving()
                // His last turn, its write still on its way, is written now: iOS may end Gatefold before
                // that write lands (gatefold#301).
                if owed == nil { app.activeReader?.keepTurnNow() }
                if let reader = app.activeReader, let owed {
                    // The page a stalled restore left him is written now, before any wait (gatefold#133).
                    reader.keepShownPageNow(owed)
                    Task {
                        await reader.keepOwedPlace(owed)
                        app.library.flushPushes()
                    }
                }
                // Picture the page while it can still be drawn, for a reopen: tagged with the place
                // being kept, not the one before the move.
                if let reader = app.activeReader, !reader.isWarming {
                    ReopenSnapshot.keep(model: reader, place: owed.flatMap { try? $0.jsonString() } ?? app.library.book(reader.bookID)?.locatorJSON)
                } else {
                    readerLog.notice("reopen: leaving with no reader open (\(app.activeReader == nil ? "none" : "a warm one", privacy: .public))")
                }
                app.library.flushPushes()
            case .background:
                // Finish sending the place even if the app is suspended mid-request.
                // iOS ends the grace period if the network hangs; whichever comes first ends the task once.
                let finish = BackgroundTaskEnd()
                let task = UIApplication.shared.beginBackgroundTask(withName: "Send reading place") { finish.end() }
                finish.task = task
                Task {
                    await app.sendPlaceNow()
                    finish.end()
                }
            default:
                app.library.flushPushes()
            }
        }
    }
}

/// How long the app took from its process starting to its first frame, in the log for measuring launches.
@MainActor
enum LaunchClock {
    private static var logged = false
    /// When this process started, from the kernel.
    static let processStarted: Date? = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }()

    /// Seconds since the process started, for the log.
    static var sinceLaunch: Double { processStarted.map { Date().timeIntervalSince($0) } ?? -1 }

    static func firstFrame() {
        guard !logged else { return }
        logged = true
        guard let started = processStarted else { return }
        readerLog.notice("launch: first frame \(Date().timeIntervalSince(started), privacy: .public) s after the process started")
    }
}

/// Starts WebKit's page process while the shelf is up, so the first book opens on a warm engine
/// instead of paying for the process launch behind the cover.
@MainActor
enum WebWarmup {
    private static var view: WKWebView?
    /// A book opening (behind the shelf, or the reader's own at launch) starts WebKit itself, and
    /// sooner; the warm-up would only hold the main thread and start a second page process beside it.
    static var bookIsOpening = false

    /// Starts WebKit a moment after the first frame, unless a book has already begun to or `GatefoldNoWarm` is set.
    static func startUnlessABookOpens() async {
        if LaunchOptions.noWarm { return }
        try? await Task.sleep(for: .milliseconds(600))
        if bookIsOpening {
            readerLog.notice("launch: web warm-up skipped; a book is already opening")
            return
        }
        start()
    }

    static func start() {
        guard view == nil else { return }
        let began = Date()
        defer { readerLog.notice("launch: web warm-up took \(Date().timeIntervalSince(began), privacy: .public) s on the main thread") }
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        web.loadHTMLString("<html><body style='font-family:serif'>Gatefold</body></html>", baseURL: nil)
        view = web
        // A web view's first trip into a window loads WebKit's window-side services (Screen Time's page
        // controller among them) on the main thread; pay that here, under the launch mark, not on the
        // first open.
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        web.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        web.alpha = 0.01
        web.isUserInteractionEnabled = false
        window?.insertSubview(web, at: 0)
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var covers
    @State private var reader: ReaderModel?
    @State private var openError: String?
    @State private var opening = false
    /// The books most likely to be opened next (Reading Now's first few), already open behind the shelf.
    @State private var warm: [ReaderModel] = []
    /// Reopening at launch: the page as he left it, up from the first frame until the reader is.
    @State private var reopenPicture: ReopenSnapshot.Picture?
    @State private var reopenLooked = false
    /// Reopening, the first frame is his page's picture, not the shelf beneath it: the shelf is built
    /// just after, so the app's own first frame (in the book's paper) replaces iOS's launch screen sooner.
    @State private var shelfShown = false

    var body: some View {
        ZStack {
            if app.hasOnboarded, let id = app.reopenBookID, !shelfShown {
                // The book's paper until the shelf is built (under the picture, or alone if it has none).
                app.preferences.effective(for: id).resolvedTheme(systemIsDark: colorScheme == .dark).background
                    .ignoresSafeArea()
                    .task {
                        await Task.yield()
                        shelfShown = true
                        readerLog.notice("launch: shelf built behind the reopen picture at \(LaunchClock.sinceLaunch, privacy: .public) s")
                    }
            } else if app.hasOnboarded {
                LibraryView(namespace: covers) { book in open(book) }
                    .transition(.opacity)
            } else {
                WelcomeView()
                    .transition(.opacity)
            }
        }
        .overlay {
            if let picture = reopenPicture, reader?.reopenPicture != nil || reader == nil {
                ReopenPictureView(image: picture.image, leaf: picture.meta.navigatorFrame, isSpread: picture.meta.columns == 2,
                                  theme: ReaderTheme(rawValue: picture.meta.theme) ?? .vellum, curl: app.reopenCurl) { app.queueReopenTurn(forward: $0) }
                    .onAppear {
                        readerLog.notice("reopen: his page on screen at \(LaunchClock.sinceLaunch, privacy: .public) s after launch (saved \(picture.meta.savedAt.formatted(.iso8601), privacy: .public))")
                    }
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in lookForReopenPicture(size: size) }
        // The status bar's room while the shelf or welcome shows it: slips in the reader keep below it
        // once the reader hides the bar and a Dynamic Island leaves the safe area.
        .onGeometryChange(for: [CGFloat].self) { [$0.safeAreaInsets.top, $0.size.width, $0.size.height] } action: { v in
            ReaderChrome.StatusRoom.note(EdgeInsets(top: v[0], leading: 0, bottom: 0, trailing: 0), size: CGSize(width: v[1], height: v[2]))
        }
        .animation(Motion.open, value: app.hasOnboarded)
        // Under the shelf's own paper: never seen, but laid out and painted like the real page. A
        // background, so its arrival can't resize the shelf's stack (it ignores the safe area).
        .background {
            if reader == nil {
                ZStack { ForEach(warm, id: \.bookID) { WarmPage(model: $0) } }
            }
        }
        .task(id: warmKeys) { await warmUp() }
        .task {
            if let tour = LaunchOptions.openTour { await openTour(tour) }
        }
        .fullScreenCover(item: $reader) { model in
            ReaderScreen(model: model) { closeReader(model) }
            // Zooms from its cover, except when reopening onto his page's picture: a zoom there drew a
            // shrunken second copy of the page over the picture for a few frames. Decided once per
            // reader: switching it when the picture went rebuilt the reader and blanked its page.
            .modifier(ZoomFromCover(enabled: !model.reopened, id: model.bookID, namespace: covers))
            // The zoom opens onto the page's own colour, never white or black.
            .presentationBackground(model.preferences.resolvedTheme(systemIsDark: colorScheme == .dark).background)
            // The zoom's swipe-to-dismiss would take edge drags meant for turning back a page.
            .interactiveDismissDisabled()
        }
        .onChange(of: app.library.books.filter(\.isOnDevice).count, initial: true) { _, _ in
            if reader == nil, !opening, let id = app.openBookID, let book = app.library.book(id), book.isOnDevice {
                open(book)
            }
        }
        .alert("Couldn't Open Book", isPresented: .constant(openError != nil)) {
            Button("OK") { openError = nil }
        } message: {
            Text(openError ?? "")
        }
    }

    /// The first layout: if a book is being reopened, find its picture for this window and theme.
    private func lookForReopenPicture(size: CGSize) {
        guard !reopenLooked else { return }
        reopenLooked = true
        guard let id = app.reopenBookID else { return }
        // The window's own size, safe area and all, as the picture was taken.
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow ?? ($0 as? UIWindowScene)?.windows.first }.first
        let full = window?.bounds.size ?? size
        let theme = app.preferences.effective(for: id).resolvedTheme(systemIsDark: colorScheme == .dark)
        reopenPicture = ReopenSnapshot.load(book: id, size: full, theme: theme, place: app.library.book(id)?.locatorJSON)
        readerLog.notice("reopen: \(id, privacy: .public) at \(Int(full.width), privacy: .public)x\(Int(full.height), privacy: .public), picture \(reopenPicture != nil, privacy: .public), at \(LaunchClock.sinceLaunch, privacy: .public) s after launch")
    }

    private func closeReader(_ model: ReaderModel) {
        // Stop any landing or settle first, so the place sent below is the last one.
        model.close()
        reopenPicture = nil
        reader = nil
        app.openBookID = nil
        app.activeReader = nil
        Task { await app.sendPlaceNow() }
    }

    /// Measuring opens without UI automation (which turns on accessibility, and so loads WebKit's
    /// accessibility bundle into every page process): opens each listed book as a tap would, then closes it.
    private func openTour(_ ids: [String]) async {
        try? await Task.sleep(for: .seconds(LaunchOptions.tourDelay))
        for id in ids {
            guard let book = app.library.book(id) else { readerLog.notice("tour: no \(id, privacy: .public)"); continue }
            let asked = Date()
            open(book)
            var ready = false
            for _ in 0..<300 {
                try? await Task.sleep(for: .milliseconds(20))
                if let reader, reader.bookID == id, reader.pageReady { ready = true; break }
            }
            readerLog.notice("tour: \(id, privacy: .public) ready=\(ready, privacy: .public) after \(Date().timeIntervalSince(asked), privacy: .public) s (\(LaunchClock.processStarted.map { asked.timeIntervalSince($0) } ?? -1, privacy: .public) s after launch)")
            try? await Task.sleep(for: .seconds(2))
            if let reader { closeReader(reader) }
            try? await Task.sleep(for: .seconds(LaunchOptions.tourRest))
        }
        readerLog.notice("tour: done")
    }

    /// What to open ahead of a tap: the first book on Reading Now, at its current place.
    /// How many of Reading Now's books wait open behind the shelf. Each new page needs its own WebKit
    /// process, whose start-up is most of an open; a few books ready covers what is likely tapped.
    private static let warmCount = 3
    /// How long a warm open waits, in tenths of a second, for the one before it to show its page.
    private static let warmWait = 600
    private static var tappedSinceLaunch = false

    private var warmKeys: [String] {
        // A book asked for by name (a link, a test's launch) opens first: warming others on the way
        // took the CPU from it (on CI's Duo three warm pages held the asked-for book off for minutes,
        // and the app stopped answering).
        guard app.hasOnboarded, reader == nil, !opening, app.openBookID == nil, !LaunchOptions.noWarm else { return [] }
        // The book only: a warm reader keeps its own place (a landing moves it), and closing the
        // reader clears the keys, so the next warm ones open where reading stopped.
        return Array(app.library.readingNow.filter(\.isOnDevice).prefix(Self.warmCount).map(\.id))
    }

    private func warmUp() async {
        let keys = warmKeys
        readerLog.notice("warm: \(keys.joined(separator: ","), privacy: .public)")
        for model in warm where !keys.contains(model.bookID) { model.close() }
        warm.removeAll { !keys.contains($0.bookID) }
        // The most likely book starts as soon as the shelf has its first data; each next one only once
        // the one before has its page, so the first never shares the CPU with the others (three pages
        // loading at once made each take three times as long, and the first tap waited on all three).
        // A warm page isn't forced into view, so the wait has a bound: a minute, since a slow host took
        // 14 to 67 s for one page and the 8 s this was before let three web views load at once (gatefold#113).
        var previous: ReaderModel?
        for id in keys where !warm.contains(where: { $0.bookID == id }) {
            if let previous {
                var waited = 0
                while !previous.pageReady, !previous.isClosed, !Task.isCancelled, waited < Self.warmWait {
                    try? await Task.sleep(for: .milliseconds(100))
                    waited += 1
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
            guard !Task.isCancelled, warmKeys == keys, let book = app.library.book(id), let url = app.library.fileURL(of: book),
                  let publication = try? await BookOpener.shared.open(url), !Task.isCancelled, warmKeys == keys else { return }
            let model = ReaderModel(book: book, publication: publication, app: app)
            model.warmKey = id
            WebWarmup.bookIsOpening = true
            readerLog.notice("warm: opening \(id, privacy: .public) at \(LaunchClock.processStarted.map { Date().timeIntervalSince($0) } ?? -1, privacy: .public) s after launch")
            model.warm()
            warm.append(model)
            previous = model
        }
    }

    private func open(_ book: LibraryBook) {
        guard !opening, let url = app.library.fileURL(of: book) else {
            readerLog.notice("open: \(book.id, privacy: .public) refused (opening \(opening, privacy: .public))")
            return
        }
        let asked = Date()
        if !Self.tappedSinceLaunch {
            Self.tappedSinceLaunch = true
            let ready = warm.first(where: { $0.bookID == book.id && !$0.isClosed })
            // Release-visible: what the first tap after launch found (`log show --predicate 'subsystem == "bot.ouro.gatefold"'`).
            readerLog.notice("first tap after launch: \(book.id, privacy: .public) at \(LaunchClock.processStarted.map { Date().timeIntervalSince($0) } ?? -1, privacy: .public) s after launch; warm \(ready != nil, privacy: .public), page ready \(ready?.pageReady ?? false, privacy: .public); warm set \(warm.map(\.bookID).joined(separator: ","), privacy: .public)")
        }
        if let ready = warm.first(where: { $0.bookID == book.id }), !ready.isClosed {
            warm.removeAll { $0 === ready }
            reader = ready
            app.activeReader = ready
            app.openBookID = book.id
            ready.activate()
            return
        }
        opening = true
        WebWarmup.bookIsOpening = true
        Task {
            defer { opening = false }
            do {
                let publication = try await BookOpener.shared.open(url)
                readerLog.notice("open: parsed after \(Date().timeIntervalSince(asked), privacy: .public) s")
                let model = ReaderModel(book: book, publication: publication, app: app)
                model.askedAt = asked
                if book.id == app.reopenBookID {
                    // Reopening: no zoom from the shelf; the reader comes up over his page's picture.
                    app.reopenBookID = nil
                    model.reopenPicture = reopenPicture?.image
                    model.reopenPageFrame = reopenPicture?.meta.pageFrame
                    model.reopenLeaf = reopenPicture?.meta.navigatorFrame
                    model.reopenSpread = reopenPicture?.meta.columns == 2
                    model.reopenAdapted = reopenPicture?.adapted ?? false
                    // A transaction without animation still slid the cover up over the picture: UIKit
                    // presents it, so UIKit's animations are held off until it is up.
                    var still = Transaction()
                    still.disablesAnimations = true
                    UIView.setAnimationsEnabled(false)
                    withTransaction(still) { reader = model }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(100))
                        UIView.setAnimationsEnabled(true)
                    }
                } else {
                    reader = model
                }
                app.activeReader = model
                app.openBookID = book.id
            } catch {
                openError = FriendlyError.message(for: error)
            }
        }
    }
}

extension ReaderModel: Identifiable {
    nonisolated var id: String { bookID }
}

/// Ends a background task exactly once, from the expiration handler or the finished work.
@MainActor
private final class BackgroundTaskEnd {
    var task: UIBackgroundTaskIdentifier = .invalid
    func end() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
}

#if DEBUG
/// Draws the launch screen's mark from the welcome's own closed gatefold, so the hand-off is seamless:
/// `-GatefoldRenderLaunchMark YES` writes LaunchMark.png and LaunchMark-dark.png to the app's tmp.
@MainActor
enum LaunchMarkRenderer {
    static func renderIfAsked() {
        guard UserDefaults.standard.bool(forKey: "GatefoldRenderLaunchMark") else { return }
        for dark in [false, true] {
            let view = GatefoldMark(opened: false)
                .frame(width: GatefoldMark.size.width, height: GatefoldMark.size.height)
                .padding(30)
                .environment(\.colorScheme, dark ? .dark : .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 3
            var traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
            traits = traits.modifyingTraits { $0.displayScale = 3 }
            traits.performAsCurrent {
                if let data = renderer.uiImage?.pngData() {
                    try? data.write(to: URL.temporaryDirectory.appending(path: dark ? "LaunchMark-dark.png" : "LaunchMark.png"))
                }
            }
        }
    }
}
#endif

/// The reader's zoom from its cover on the shelf, or no transition at all.
private struct ZoomFromCover: ViewModifier {
    let enabled: Bool
    let id: String
    let namespace: Namespace.ID

    @ViewBuilder func body(content: _ViewModifier_Content<Self>) -> some View {
        if enabled {
            content.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            content
        }
    }
}

#if DEBUG
/// Tests only: `-GatefoldSystemInsets "top,leading,bottom,trailing"` (points) makes the screen report at
/// least these insets, the way a device's own do, through `additionalSafeAreaInsets` on every
/// controller on screen, so the simulator can stand in for a device whose status column or camera
/// sits at a side edge. It stands in for the screen's own insets, never adds to them: the Duo
/// simulator's cover screen already reports its 84 pt status column, and build 14's injector stacked
/// 81 on top, so the shelf reserved 165 pt that no device has.
@MainActor
enum SystemInsetInjector {
    static var asked: UIEdgeInsets? {
        guard let raw = UserDefaults.standard.string(forKey: "GatefoldSystemInsets") else { return nil }
        let v = raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard v.count == 4 else { return nil }
        return UIEdgeInsets(top: v[0], left: v[1], bottom: v[2], right: v[3])
    }

    static func runIfAsked() async {
        guard let insets = asked else { return }
        readerLog.notice("insets: injecting system insets \(String(describing: insets), privacy: .public)")
        // Presented screens (the reader, sheets) arrive later: keep every controller on screen covered.
        while !Task.isCancelled {
            for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
                for window in scene.windows {
                    // The screen's own insets: the window's, which no controller's additions reach.
                    let own = window.safeAreaInsets
                    let add = UIEdgeInsets(top: max(0, insets.top - own.top), left: max(0, insets.left - own.left),
                                           bottom: max(0, insets.bottom - own.bottom), right: max(0, insets.right - own.right))
                    var vc = window.rootViewController
                    while let c = vc {
                        if c.additionalSafeAreaInsets != add {
                            c.additionalSafeAreaInsets = add
                        }
                        vc = c.presentedViewController
                    }
                }
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }
}
#endif
