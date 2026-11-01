import GatefoldCore
import ReadiumShared
import SwiftUI

@main
struct GatefoldApp: App {
    @State private var app = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .task { await app.start() }
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

struct RootView: View {
    @Environment(AppModel.self) private var app
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
                reader = nil
                app.openBookID = nil
                app.activeReader = nil
                Task { await app.sendPlaceNow() }
            }
            .navigationTransition(.zoom(sourceID: model.bookID, in: covers))
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
