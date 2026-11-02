import GatefoldCore
import ReadiumShared
import SwiftUI
import WebKit

@main
struct GatefoldApp: App {
    @State private var app = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .task { await app.start() }
                .task { LaunchClock.firstFrame(); await WebWarmup.startUnlessABookWarms() }
                #if DEBUG
                .task { LaunchMarkRenderer.renderIfAsked() }
                #endif
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task { await app.didBecomeActive() }
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
    /// A book opening behind the shelf starts WebKit itself, and sooner; the warm-up would only hold
    /// the main thread for it (a second on the first launch after an install).
    static var bookIsWarming = false

    /// Starts WebKit a moment after the first frame, unless Reading Now's first book has already begun to.
    static func startUnlessABookWarms() async {
        try? await Task.sleep(for: .milliseconds(600))
        if bookIsWarming {
            readerLog.notice("launch: web warm-up skipped; a book is opening behind the shelf")
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

    var body: some View {
        ZStack {
            if app.hasOnboarded {
                LibraryView(namespace: covers) { book in open(book) }
                    .transition(.opacity)
            } else {
                WelcomeView()
                    .transition(.opacity)
            }
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
            .navigationTransition(.zoom(sourceID: model.bookID, in: covers))
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

    private func closeReader(_ model: ReaderModel) {
        // Stop any landing or settle first, so the place sent below is the last one.
        model.close()
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
    private static var tappedSinceLaunch = false

    private var warmKeys: [String] {
        guard app.hasOnboarded, reader == nil, !opening, !LaunchOptions.noWarm else { return [] }
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
        var previous: ReaderModel?
        for id in keys where !warm.contains(where: { $0.bookID == id }) {
            if let previous {
                var waited = 0
                while !previous.pageReady, !previous.isClosed, !Task.isCancelled, waited < 80 {
                    try? await Task.sleep(for: .milliseconds(100))
                    waited += 1
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
            guard !Task.isCancelled, warmKeys == keys, let book = app.library.book(id), let url = app.library.fileURL(of: book),
                  let publication = try? await BookOpener.shared.open(url), !Task.isCancelled, warmKeys == keys else { return }
            let model = ReaderModel(book: book, publication: publication, app: app)
            model.warmKey = id
            WebWarmup.bookIsWarming = true
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
        Task {
            defer { opening = false }
            do {
                let publication = try await BookOpener.shared.open(url)
                readerLog.notice("open: parsed after \(Date().timeIntervalSince(asked), privacy: .public) s")
                let model = ReaderModel(book: book, publication: publication, app: app)
                model.askedAt = asked
                reader = model
                app.activeReader = model
                app.openBookID = book.id
            } catch {
                openError = error.localizedDescription
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
