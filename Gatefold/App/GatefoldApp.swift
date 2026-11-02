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
                .task { WebWarmup.start() }
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

/// Starts WebKit's page process while the shelf is up, so the first book opens on a warm engine
/// instead of paying for the process launch behind the cover.
@MainActor
enum WebWarmup {
    private static var view: WKWebView?

    static func start() {
        guard view == nil else { return }
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
    /// The book most likely to be opened next, already open behind the shelf.
    @State private var warm: ReaderModel?

    var body: some View {
        ZStack {
            if let warm, reader == nil {
                // Under the shelf's own paper: never seen, but laid out and painted like the real page.
                WarmPage(model: warm)
            }
            if app.hasOnboarded {
                LibraryView(namespace: covers) { book in open(book) }
                    .transition(.opacity)
            } else {
                WelcomeView()
                    .transition(.opacity)
            }
        }
        .animation(Motion.open, value: app.hasOnboarded)
        .task(id: warmKey) { await warmUp() }
        .fullScreenCover(item: $reader) { model in
            ReaderScreen(model: model) {
                // Stop any landing or settle first, so the place sent below is the last one.
                model.close()
                reader = nil
                app.openBookID = nil
                app.activeReader = nil
                Task { await app.sendPlaceNow() }
            }
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

    /// What to open ahead of a tap: the first book on Reading Now, at its current place.
    private var warmKey: String? {
        guard app.hasOnboarded, reader == nil, !opening, !LaunchOptions.noWarm,
              let book = app.library.readingNow.first(where: \.isOnDevice) else { return nil }
        // The book only: the warm reader keeps its own place (a landing moves it), and closing the
        // reader clears the key, so the next warm one opens where reading stopped.
        return book.id
    }

    private func warmUp() async {
        guard let key = warmKey, case let id = key else { return }
        if let warm, warm.warmKey == key { return }
        warm?.close()
        warm = nil
        // Let the shelf arrive first; the warm open is the next thing the main thread does, not the first.
        try? await Task.sleep(for: .milliseconds(700))
        guard !Task.isCancelled, let book = app.library.book(id), let url = app.library.fileURL(of: book),
              let publication = try? await BookOpener.shared.open(url), !Task.isCancelled, warmKey == key else { return }
        let model = ReaderModel(book: book, publication: publication, app: app)
        model.warmKey = key
        model.warm()
        warm = model
    }

    private func open(_ book: LibraryBook) {
        guard !opening, let url = app.library.fileURL(of: book) else { return }
        let asked = Date()
        if let ready = warm, ready.bookID == book.id, !ready.isClosed {
            warm = nil
            reader = ready
            app.activeReader = ready
            app.openBookID = book.id
            ready.activate()
            return
        }
        warm?.close()
        warm = nil
        opening = true
        Task {
            defer { opening = false }
            do {
                let publication = try await BookOpener.shared.open(url)
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
