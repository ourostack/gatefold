import GatefoldCore
import SwiftUI
import UniformTypeIdentifiers

/// The shelf: Reading Now across the top, then everything.
struct LibraryView: View {
    @Environment(AppModel.self) private var app
    var namespace: Namespace.ID
    var onOpen: (LibraryBook) -> Void

    @State private var importing = false
    @State private var importedCount = 0
    @State private var confirmSignOut = false

    var body: some View {
        let library = app.library
        NavigationStack {
            ScrollView {
                if library.books.isEmpty {
                    EmptyShelf(signedIn: app.account != nil, isRefreshing: library.isRefreshing) { importing = true }
                        .padding(.top, 60)
                } else {
                    VStack(alignment: .leading, spacing: 34) {
                        let now = library.readingNow
                        if !now.isEmpty {
                            section("Reading Now") {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    LazyHStack(alignment: .bottom, spacing: 22) {
                                        ForEach(now) { book in
                                            BookTile(book: book, size: .large, namespace: namespace, onOpen: onOpen)
                                        }
                                    }
                                    .padding(.horizontal, 20)
                                    .scrollTargetLayout()
                                }
                                .scrollTargetBehavior(.viewAligned)
                                .accessibilityIdentifier("library.readingNow")
                            }
                        }
                        section("All Books") {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 150), spacing: 20, alignment: .bottom)], spacing: 28) {
                                ForEach(library.allBooks) { book in
                                    BookTile(book: book, size: .grid, namespace: namespace, onOpen: onOpen)
                                }
                            }
                            .padding(.horizontal, 20)
                            .accessibilityIdentifier("library.grid")
                        }
                    }
                    .padding(.vertical, 12)
                }
            }
            .background(Color.paper)
            .navigationTitle("Library")
            .toolbarTitleDisplayMode(.inlineLarge)
            .refreshable { await library.refresh() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        importing = true
                    } label: {
                        Label("Add Books", systemImage: "plus")
                    }
                    .accessibilityIdentifier("library.import")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if let account = app.account {
                            Section(account.email) {
                                Text(account.store.name)
                                Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                                    confirmSignOut = true
                                }
                            }
                        } else {
                            Button("Connect PocketBook Cloud", systemImage: "icloud") {
                                app.hasOnboarded = false
                            }
                        }
                    } label: {
                        Label("Account", systemImage: app.account == nil ? "person.crop.circle" : "person.crop.circle.fill")
                    }
                    .accessibilityIdentifier("library.account")
                }
            }
            .confirmationDialog("Sign out of PocketBook Cloud?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) { Task { await app.signOut() } }
            } message: {
                Text("Books you've downloaded and your place in them stay on this device.")
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "epub") ?? .data], allowsMultipleSelection: true) { result in
                guard case let .success(urls) = result else { return }
                Task {
                    let added = await library.importBooks(from: urls)
                    importedCount += added.count
                }
            }
            .sensoryFeedback(.success, trigger: importedCount)
            .alert("Couldn't Add That", isPresented: .constant(library.lastError != nil)) {
                Button("OK") { library.lastError = nil }
            } message: {
                Text(library.lastError ?? "")
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.display(.title2, weight: .bold))
                .foregroundStyle(Color.ink)
                .padding(.horizontal, 20)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }
}

/// A cover on the shelf, with progress beneath it. No frame around it: the cover is the object.
struct BookTile: View {
    enum Size { case large, grid }

    @Environment(AppModel.self) private var app
    let book: LibraryBook
    let size: Size
    var namespace: Namespace.ID
    var onOpen: (LibraryBook) -> Void

    var body: some View {
        let state = app.library.state(of: book)
        let width: CGFloat = size == .large ? 150 : 110
        Button {
            switch state {
            case .onDevice: onOpen(book)
            case .cloudOnly, .failed: Task { await app.library.download(book) }
            case .downloading: break
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                CoverView(book: book, image: app.library.cover(for: book))
                    .frame(width: width, height: width * 1.5)
                    .overlay(alignment: .bottomTrailing) { badge(state) }
                    .matchedTransitionSource(id: book.id, in: namespace)
                VStack(alignment: .leading, spacing: 3) {
                    if size == .large {
                        Text(book.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.ink)
                            .lineLimit(1)
                    }
                    footer(state)
                }
                .frame(width: width, alignment: .leading)
            }
        }
        .buttonStyle(PressScale())
        .contextMenu {
            if state == .onDevice {
                Button("Read", systemImage: "book") { onOpen(book) }
            }
            Button("Remove from This iPhone", systemImage: "trash", role: .destructive) { app.library.remove(book) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(book.title), \(book.author)")
        .accessibilityValue(accessibilityValue(state))
        .accessibilityHint(state == .onDevice ? "Opens the book" : "Downloads the book")
        .accessibilityIdentifier("book.\(book.id)")
    }

    @ViewBuilder
    private func badge(_ state: DownloadState) -> some View {
        switch state {
        case .cloudOnly:
            Image(systemName: "icloud.and.arrow.down")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .padding(7)
                .background(.black.opacity(0.45), in: .circle)
                .padding(6)
        case .downloading:
            ProgressView()
                .tint(.white)
                .padding(8)
                .background(.black.opacity(0.45), in: .circle)
                .padding(6)
        case .failed:
            Image(systemName: "exclamationmark.arrow.trianglehead.counterclockwise")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .padding(7)
                .background(.red.opacity(0.8), in: .circle)
                .padding(6)
        case .onDevice:
            EmptyView()
        }
    }

    @ViewBuilder
    private func footer(_ state: DownloadState) -> some View {
        let p = book.displayProgression
        if book.isFinished {
            Text("Finished").font(.caption).foregroundStyle(.secondary)
        } else if p > 0.001 {
            HStack(spacing: 6) {
                ProgressView(value: p)
                    .tint(.ribbon)
                    .frame(maxWidth: 60)
                Text("\(Int((p * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(state == .onDevice ? (book.origin == .imported ? "Imported" : "New") : "In Cloud")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func accessibilityValue(_ state: DownloadState) -> String {
        var parts: [String] = []
        if book.displayProgression > 0.001 { parts.append("\(Int((book.displayProgression * 100).rounded())) percent read") }
        switch state {
        case .cloudOnly: parts.append("in PocketBook Cloud")
        case .downloading: parts.append("downloading")
        case .failed: parts.append("download failed")
        case .onDevice: break
        }
        return parts.joined(separator: ", ")
    }
}

struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.3), value: configuration.isPressed)
    }
}

/// A cover with a soft page edge and spine highlight; a typeset cover when the book has none.
struct CoverView: View {
    let book: LibraryBook
    let image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                GeneratedCover(title: book.title, author: book.author)
            }
            // The spine: light catches the hinge of a real cover.
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.28), location: 0),
                    .init(color: .white.opacity(0.16), location: 0.025),
                    .init(color: .clear, location: 0.06),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        .clipShape(.rect(topLeadingRadius: 3, bottomLeadingRadius: 3, bottomTrailingRadius: 6, topTrailingRadius: 6))
        .shadow(color: .black.opacity(0.22), radius: 8, x: 0, y: 6)
    }
}

private struct GeneratedCover: View {
    let title: String
    let author: String

    var body: some View {
        let palette = [0x7A2E22, 0x2E4A5E, 0x3E5A34, 0x5B3A6B, 0x6B5326] as [UInt32]
        let hue = palette[abs(title.hashValue) % palette.count]
        ZStack {
            Color(hex: hue)
            VStack(spacing: 10) {
                Rectangle().fill(.white.opacity(0.5)).frame(width: 30, height: 1)
                Text(title)
                    .font(.system(.headline, design: .serif))
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.6)
                Text(author.uppercased())
                    .font(.system(size: 9, weight: .medium))
                    .tracking(1.2)
                    .opacity(0.8)
                Rectangle().fill(.white.opacity(0.5)).frame(width: 30, height: 1)
            }
            .foregroundStyle(.white)
            .padding(12)
        }
    }
}

private struct EmptyShelf: View {
    let signedIn: Bool
    let isRefreshing: Bool
    var onImport: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            if isRefreshing {
                ProgressView().controlSize(.large)
                Text("Fetching your books…").font(.display(.title3)).foregroundStyle(Color.ink)
            } else {
                Image(systemName: "books.vertical")
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(Color.ribbon)
                    .symbolEffect(.wiggle, options: .nonRepeating)
                Text("An Empty Shelf")
                    .font(.display(.title2, weight: .bold))
                    .foregroundStyle(Color.ink)
                Text(signedIn
                     ? "Books you add to PocketBook Cloud appear here. You can also add EPUBs from Files."
                     : "Add EPUBs from Files, or connect PocketBook Cloud to bring your InkPad's books.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 320)
                Button("Add Books from Files", systemImage: "folder", action: onImport)
                    .buttonStyle(.glassProminent)
                    .tint(.ribbon)
                    .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }
}
