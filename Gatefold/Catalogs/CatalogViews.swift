import GatefoldCore
import OuroHX
import SwiftUI

/// A page of a catalog to show: its address, and the catalog it belongs to for signing in.
struct CatalogPage: Hashable {
    var catalog: CatalogShelf.Catalog
    var url: URL
    var title: String
    /// What was searched for, when this page is search results.
    var query: String?
}

/// Catalogs to browse: the free libraries built in, and the reader's own. Opened from the Add menu.
struct CatalogsView: View {
    let shelf: CatalogShelf
    /// Called with a book that came aboard, when the reader taps Read: the shelf closes this and opens it.
    var onRead: (LibraryBook) -> Void
    var onDone: () -> Void
    @State private var path: [CatalogPage] = []
    @State private var adding = false
    @State private var draft = CatalogDraft()

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    OuroItemGroup("Free books", variant: .outline) {
                        ForEach(CatalogShelf.builtIn) { catalog in
                            OuroItem(catalog.name, description: catalog.about, systemImage: "books.vertical") { open(catalog) }
                                .accessibilityIdentifier("catalogs.\(catalog.id)")
                        }
                    }
                    if !shelf.own.isEmpty {
                        OuroItemGroup("Your catalogs", variant: .outline) {
                            ForEach(shelf.own) { catalog in
                                OuroItem(catalog.name, description: catalog.url.host() ?? catalog.url.absoluteString, systemImage: "server.rack") { open(catalog) }
                                    .contextMenu {
                                        Button("Remove", systemImage: "trash", role: .destructive) { shelf.remove(catalog) }
                                    }
                                    .accessibilityIdentifier("catalogs.own")
                            }
                        }
                    }
                    OuroButton("Add a Catalog", systemImage: "plus", variant: .outline, fullWidth: true) {
                        draft = CatalogDraft()
                        adding = true
                    }
                        .accessibilityIdentifier("catalogs.add")
                    Text("Any OPDS catalog works: a calibre or Calibre-Web library at home, Kavita, Komga, or one a library gives you.")
                        .font(.footnote)
                        .foregroundStyle(Color.ink.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
            }
            .navigationTitle("Catalogs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: onDone) }
            }
            .navigationDestination(for: CatalogPage.self) { page in
                CatalogFeedView(page: page, shelf: shelf, onRead: onRead) { path.append($0) }
            }
            .ouroSheet(isPresented: $adding, title: "Add a Catalog", detents: [.large]) {
                AddCatalogForm(draft: draft)
            } footer: {
                OuroButton("Add", size: .lg, fullWidth: true, loading: draft.checking, loadingLabel: "Opening the catalog") {
                    Task {
                        guard let catalog = await draft.add(to: shelf) else { return }
                        adding = false
                        open(catalog)
                    }
                }
                .disabled(!draft.canAdd)
                .accessibilityIdentifier("catalog.save")
            }
        }
    }

    private func open(_ catalog: CatalogShelf.Catalog) {
        path.append(CatalogPage(catalog: catalog, url: catalog.url, title: catalog.name))
    }
}

/// One page of a catalog: shelves to open, books to get, search, and More for the next page.
struct CatalogFeedView: View {
    let page: CatalogPage
    let shelf: CatalogShelf
    var onRead: (LibraryBook) -> Void
    var onOpen: (CatalogPage) -> Void
    @Environment(AppModel.self) private var app
    @State private var feed: CatalogFeed?
    @State private var entries: [CatalogEntry] = []
    @State private var next: URL?
    @State private var failure: CatalogClient.Failure?
    @State private var loadingMore = false
    @State private var query = ""
    @State private var getting: Set<String> = []
    @State private var searching = false
    /// Books that came aboard from this page, by entry, with the shelf's book to read.
    @State private var aboard: [String: String] = [:]
    @State private var getFailure: String?
    private let client = CatalogClient()

    private var credential: CatalogClient.Credential? { shelf.credential(for: page.catalog) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if feed?.search != nil, page.query == nil {
                    OuroTextField("Search", text: $query, placeholder: "Title or author", type: .search, hideLabel: true, clearable: true) { search() }
                        .accessibilityIdentifier("catalog.search")
                }
                if let getFailure {
                    OuroBanner(getFailure, tone: .destructive)
                }
                if let failure, feed == nil {
                    OuroEmptyState(failure == .needsSignIn ? "Sign-in needed" : "Couldn't open this catalog", systemImage: "exclamationmark.triangle",
                                   description: failure.words) {
                        OuroButton("Try Again", variant: .outline) { Task { await load() } }
                    }
                } else if feed == nil {
                    OuroSpinner(label: "Opening \(page.title)")
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else if entries.isEmpty {
                    OuroEmptyState(page.query == nil ? "Nothing here yet" : "No books found", systemImage: "books.vertical",
                                   description: page.query.map { "Nothing in \(page.catalog.name) matched “\($0)”." }) { EmptyView() }
                } else {
                    ForEach(entries) { entry in row(entry) }
                    if next != nil {
                        OuroButton("More", variant: .outline, fullWidth: true, loading: loadingMore) { Task { await loadMore() } }
                            .accessibilityIdentifier("catalog.more")
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle(page.query.map { "“\($0)”" } ?? feed?.title.nonEmpty ?? page.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { if feed == nil { await load() } }
    }

    @ViewBuilder
    private func row(_ entry: CatalogEntry) -> some View {
        if let epub = entry.epub {
            OuroItem(entry.title, description: entry.author ?? entry.summary, variant: .outline, mediaSize: .md) {
                CatalogCover(entry: entry, credential: credential, client: client)
            } actions: {
                if let bookID = aboard[entry.id] {
                    OuroButton("Read", variant: .outline, size: .sm) { if let book = app.library.book(bookID) { onRead(book) } }
                        .accessibilityIdentifier("catalog.read")
                } else {
                    OuroButton("Get", size: .sm, loading: getting.contains(entry.id), loadingLabel: "Getting") { Task { await get(entry, epub) } }
                        .accessibilityIdentifier("catalog.get")
                }
            }
        } else if let navigation = entry.navigation {
            OuroItem(entry.title, description: entry.author ?? entry.summary, systemImage: "books.vertical") {
                onOpen(CatalogPage(catalog: page.catalog, url: navigation, title: entry.title))
            }
            .accessibilityIdentifier("catalog.shelf")
        } else {
            OuroItem(entry.title, description: "No EPUB to get here", systemImage: "nosign")
                .opacity(0.6)
        }
    }

    private func load() async {
        failure = nil
        do {
            let loaded = try await client.feed(at: page.url, credential: credential)
            feed = loaded
            entries = loaded.entries
            next = loaded.next
            // Counts only: how many of the page's books the catalog gave a picture.
            let books = loaded.entries.filter { $0.epub != nil }
            GatefoldTelemetry.shared.capture("gatefold_catalog_covers", properties: [
                "books": .int(books.count), "with_picture": .int(books.filter { ($0.thumbnail ?? $0.cover) != nil }.count),
            ])
        } catch let error as CatalogClient.Failure {
            failure = error
        } catch {}
    }

    private func loadMore() async {
        guard let next, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let more = try await client.feed(at: next, credential: credential)
            let seen = Set(entries.map(\.id))
            entries += more.entries.filter { !seen.contains($0.id) }
            self.next = more.next
        } catch let error as CatalogClient.Failure {
            getFailure = error.words
        } catch {}
    }

    private func search() {
        guard let search = feed?.search, !searching, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        searching = true
        Task {
            defer { searching = false }
            do {
                guard let url = try await client.searchURL(search, for: query, credential: credential) else { return }
                onOpen(CatalogPage(catalog: page.catalog, url: url, title: page.title, query: query))
            } catch let error as CatalogClient.Failure {
                getFailure = error.words
            } catch {}
        }
    }

    private func get(_ entry: CatalogEntry, _ epub: CatalogAcquisition) async {
        guard !getting.contains(entry.id) else { return }
        getting.insert(entry.id)
        getFailure = nil
        defer { getting.remove(entry.id) }
        do {
            let file = try await client.download(epub, title: entry.title, credential: credential)
            let result = await app.receive([file], source: .catalog)
            if let book = result.single {
                aboard[entry.id] = book.id
            } else {
                getFailure = app.library.lastError ?? "“\(entry.title)” didn't come aboard."
                app.library.lastError = nil
            }
        } catch let error as CatalogClient.Failure {
            getFailure = error.words
        } catch {}
    }
}

/// A book's cover from the catalog, small, while it loads a quiet tile.
/// A catalog book's cover: its picture from the catalog (the thumbnail first), fetched through the catalog's own
/// client so a catalog behind a password shows covers too, over a cover made from its title and author in the
/// shelf's own cloth. A row never shows a blank tile: not while the picture comes, not when it fails, not when
/// there is none. A book's shape, standing in the row's square picture tile.
struct CatalogCover: View {
    let entry: CatalogEntry
    var credential: CatalogClient.Credential?
    var client = CatalogClient()
    @State private var picture: UIImage?
    private var url: URL? { entry.thumbnail ?? entry.cover }

    static let height = OuroItemMetrics.mediaSide(.md)
    static let width = (height * 2 / 3).rounded()
    /// The made cover is drawn at a shelf cover's size and shrunk, so it is the shelf's own design, not a sketch of it.
    private static let madeWidth: CGFloat = 120

    var body: some View {
        ZStack {
            GeneratedCover(title: BookTitle.display(entry.title), author: entry.author ?? "")
                .frame(width: Self.madeWidth, height: Self.madeWidth * 3 / 2)
                .scaleEffect(Self.width / Self.madeWidth)
                .frame(width: Self.width, height: Self.height)
            if let picture {
                Image(uiImage: picture).resizable().scaledToFill()
                    .frame(width: Self.width, height: Self.height)
                    .transition(.opacity)
            }
        }
        .frame(width: Self.width, height: Self.height)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .animation(.easeOut(duration: 0.25), value: picture == nil)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
        .task(id: url) {
            guard let url else { return }
            if let kept = Self.kept.object(forKey: url as NSURL) { picture = kept; return }
            guard let loaded = await client.cover(at: url, credential: credential) else { return }
            Self.kept.setObject(loaded, forKey: url as NSURL)
            picture = loaded
        }
    }

    /// Pictures already fetched, so scrolling back or reopening a page doesn't fetch them again.
    @MainActor private static let kept = NSCache<NSURL, UIImage>()
}

/// What the reader types to add a catalog, and the check that it opens before it is saved.
@MainActor @Observable
final class CatalogDraft {
    var address = ""
    var name = ""
    var user = ""
    var password = ""
    var problem: String?
    var checking = false

    var canAdd: Bool { !address.trimmingCharacters(in: .whitespaces).isEmpty && !checking }

    /// Opens the catalog with what was typed; saves it to the shelf only once it opened.
    func add(to shelf: CatalogShelf, client: CatalogClient = CatalogClient()) async -> CatalogShelf.Catalog? {
        guard !checking else { return nil }
        guard let url = CatalogClient.address(address) else {
            problem = "That isn't a web address."
            return nil
        }
        checking = true
        defer { checking = false }
        let user = user.trimmingCharacters(in: .whitespaces)
        let credential = user.isEmpty ? nil : CatalogClient.Credential(user: user, password: password, catalog: url)
        do {
            _ = try await client.feed(at: url, credential: credential)
            problem = nil
            return shelf.add(name: name, url: url, user: user, password: password)
        } catch let error as CatalogClient.Failure {
            problem = error.words
        } catch {}
        return nil
    }
}

/// A catalog's address, a name for it, and a user name and password if it has one. The sheet's footer holds Add.
struct AddCatalogForm: View {
    @Bindable var draft: CatalogDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            OuroTextField("Address", text: $draft.address, placeholder: "https://books.example.com/opds", error: draft.problem, type: .url, required: true)
                .accessibilityIdentifier("catalog.address")
            OuroTextField("Name", text: $draft.name, placeholder: "Home library")
                .accessibilityIdentifier("catalog.name")
            OuroTextField("User name", text: $draft.user, description: "Only if the catalog asks for one.")
                .accessibilityIdentifier("catalog.user")
            OuroTextField("Password", text: $draft.password, type: .password)
                .accessibilityIdentifier("catalog.password")
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
