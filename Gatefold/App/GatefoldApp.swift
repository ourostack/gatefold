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
            if phase != .active { app.library.flushPushes() }
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
            }
            .navigationTransition(.zoom(sourceID: model.bookID, in: covers))
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
                reader = ReaderModel(book: book, publication: publication, app: app)
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
