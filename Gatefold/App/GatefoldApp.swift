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
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var covers
    @State private var reader: ReaderModel?
    @State private var openError: String?
    @State private var opening = false

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

    private func open(_ book: LibraryBook) {
        guard !opening, let url = app.library.fileURL(of: book) else { return }
        opening = true
        Task {
            defer { opening = false }
            do {
                let publication = try await BookOpener.shared.open(url)
                let model = ReaderModel(book: book, publication: publication, app: app)
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
