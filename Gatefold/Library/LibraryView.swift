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
    @State private var reconnecting = false

    var body: some View {
        let library = app.library
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    SyncStatusLine()
                        .padding(.horizontal, 20)
                        .padding(.bottom, 6)
                    if library.books.isEmpty {
                        EmptyShelf(signedIn: app.account != nil, isRefreshing: library.isRefreshing) { importing = true }
                            .padding(.top, 48)
                    } else {
                        shelves
                    }
                }
            }
            .background(Color.paper)
            // The title and buttons live in the page, so nothing floats over the covers in any posture
            // (on the Duo's cover screen the system would move bar buttons to the side edge, over the shelf).
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await app.refresh() }
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
            .sheet(isPresented: $reconnecting) {
                NavigationStack { SignInFlow(prefilledEmail: app.needsReconnect, onDone: { reconnecting = false }) }
            }
        }
    }

    /// "Library", with Add and the account beside it, like Books' Home.
    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Library")
                .font(.display(.largeTitle, weight: .bold))
                .foregroundStyle(Color.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Button {
                importing = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Add Books from Files")
            .accessibilityIdentifier("library.import")
            accountMenu
        }
        .tint(Color.ink)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private var accountMenu: some View {
        Menu {
            if let account = app.account {
                Section(account.email) {
                    Text(account.store.name)
                    if app.needsReconnect != nil {
                        Button("Sign In Again", systemImage: "key") { reconnecting = true }
                    }
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
            AccountBadge(email: app.account?.email, needsAttention: app.needsReconnect != nil)
        }
        .accessibilityLabel(app.account.map { "Account, \($0.email)" } ?? "Account")
        .accessibilityIdentifier("library.account")
    }

    @ViewBuilder
    private var shelves: some View {
        let library = app.library
        VStack(alignment: .leading, spacing: 30) {
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
                        .padding(.vertical, 10)
                        .scrollTargetLayout()
                    }
                    // Covers cast shadows; let them fall outside the row instead of being sliced off.
                    .scrollClipDisabled()
                    .scrollTargetBehavior(.viewAligned)
                    .accessibilityIdentifier("library.readingNow")
                }
            }
            section("All Books") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12, alignment: .bottomLeading)], spacing: 28) {
                    ForEach(library.allBooks) { book in
                        BookTile(book: book, size: .grid, namespace: namespace, onOpen: onOpen)
                    }
                }
                .padding(.horizontal, 20)
                .accessibilityIdentifier("library.grid")
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 28)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.display(.title2, weight: .bold))
                .foregroundStyle(Color.ink)
                .padding(.horizontal, 20)
                .padding(.bottom, -4)
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
        let width: CGFloat = size == .large ? 150 : 100
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
                        Text(BookTitle.short(book.title))
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
                Text("\(book.displayPercent)%")
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
        if book.displayProgression > 0.001 { parts.append("\(book.displayPercent) percent read") }
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

/// The account button: the reader's initial on the ribbon colour, a plain silhouette when signed out,
/// and a small dot when the Cloud wants them to sign in again.
private struct AccountBadge: View {
    let email: String?
    let needsAttention: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let initial = email?.first.map({ String($0).uppercased() }) {
                Text(initial)
                    .font(.system(.headline, design: .serif, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.ribbon.gradient, in: .circle)
            } else {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(Color.ink)
            }
            if needsAttention {
                Circle().fill(.orange).frame(width: 11, height: 11)
                    .overlay(Circle().stroke(Color.paper, lineWidth: 2))
                    .offset(x: 2, y: -2)
            }
        }
        .frame(width: 44, height: 44)
        .contentShape(.circle)
    }
}

/// One quiet line under the title about the Cloud: checking, offline, or asking to sign in again.
/// Nothing at all when everything is fine.
private struct SyncStatusLine: View {
    @Environment(AppModel.self) private var app
    @State private var reconnecting = false

    var body: some View {
        Group {
            if let email = app.needsReconnect {
                HStack(spacing: 8) {
                    Image(systemName: "key.fill").foregroundStyle(.orange)
                    Text("PocketBook Cloud wants you to sign in again.")
                        .foregroundStyle(.secondary)
                    Button("Sign In") { reconnecting = true }
                        .fontWeight(.semibold)
                        .tint(.ribbon)
                        .accessibilityIdentifier("library.reconnect")
                }
                .sheet(isPresented: $reconnecting) {
                    NavigationStack { SignInFlow(prefilledEmail: email, onDone: { reconnecting = false }) }
                }
            } else if app.library.syncProblem == .offline, app.account != nil {
                Label("Offline. Your books are here, and your place will sync when you're back.", systemImage: "wifi.slash")
                    .foregroundStyle(.secondary)
            } else if case let .other(message)? = app.library.syncProblem, app.account != nil {
                Label(message, systemImage: "exclamationmark.icloud")
                    .foregroundStyle(.secondary)
            } else if app.library.isRefreshing, !app.library.books.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Checking PocketBook Cloud…").foregroundStyle(.secondary)
                }
            }
        }
        .font(.footnote)
        .transition(.opacity)
        .animation(.easeOut(duration: 0.25), value: app.library.isRefreshing)
        .accessibilityIdentifier("library.syncStatus")
    }
}
