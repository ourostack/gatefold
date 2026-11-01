import Foundation
import GatefoldCore
import Observation
import UIKit

/// This device's shelf. Cloud books merge with imported ones; places, bookmarks and covers persist
/// under Application Support, so the app is a whole reader without any account (design brief D8).
@MainActor @Observable
final class LibraryStore {
    private(set) var books: [LibraryBook] = []
    private(set) var downloads: [String: DownloadState] = [:]
    private(set) var covers: [String: UIImage] = [:]
    private(set) var isRefreshing = false
    var lastError: String?
    @ObservationIgnored private var pushes: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var pending: [String: (ReadingPosition, CloudBook)] = [:]

    private let sync: any SyncService
    private let root: URL
    private var booksDir: URL { root.appending(path: "Books", directoryHint: .isDirectory) }
    private var coversDir: URL { root.appending(path: "Covers", directoryHint: .isDirectory) }
    private var indexURL: URL { root.appending(path: "library.json") }

    init(sync: any SyncService, root: URL = LibraryStore.defaultRoot) {
        self.sync = sync
        self.root = root
        try? FileManager.default.createDirectory(at: booksDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: coversDir, withIntermediateDirectories: true)
        load()
    }

    static var defaultRoot: URL {
        URL.applicationSupportDirectory.appending(path: "Gatefold", directoryHint: .isDirectory)
    }

    // MARK: Queries

    var readingNow: [LibraryBook] {
        ReadingNow.shelf(books.map(\.shelfItem), limit: 10).compactMap { item in books.first { $0.id == item.id } }
    }

    /// Everything, newest first.
    var allBooks: [LibraryBook] {
        books.sorted { ($0.lastOpened ?? $0.added) > ($1.lastOpened ?? $1.added) }
    }

    func book(_ id: String) -> LibraryBook? { books.first { $0.id == id } }

    func state(of book: LibraryBook) -> DownloadState {
        if let state = downloads[book.id] { return state }
        return book.isOnDevice ? .onDevice : .cloudOnly
    }

    func fileURL(of book: LibraryBook) -> URL? {
        book.fileName.map { booksDir.appending(path: $0) }
    }

    // MARK: Cloud

    func refresh() async {
        guard await sync.account != nil else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            var cloudBooks = try await sync.library()
            for i in cloudBooks.indices {
                if let remote = try? await sync.remotePosition(for: cloudBooks[i]) { cloudBooks[i].position = remote }
            }
            await merge(cloudBooks)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Puts cloud books on the shelf, or updates the ones already there. Never fetches the library.
    func merge(_ cloudBooks: [CloudBook]) async {
        for cloudBook in cloudBooks {
            if let i = books.firstIndex(where: { $0.id == cloudBook.id }) {
                books[i].cloud = cloudBook
                books[i].remote = cloudBook.position ?? books[i].remote
            } else {
                books.append(LibraryBook(
                    id: cloudBook.id,
                    title: cloudBook.title,
                    author: cloudBook.authors ?? "",
                    origin: .cloud,
                    cloud: cloudBook,
                    remote: cloudBook.position,
                    added: cloudBook.createdAt ?? cloudBook.modifiedAt ?? Date()
                ))
            }
        }
        save()
        for cloudBook in cloudBooks where covers[cloudBook.id] == nil {
            if let url = cloudBook.coverURL { await loadCover(id: cloudBook.id, from: url) }
        }
    }

    /// The book left PocketBook Cloud: a cloud-only book leaves the shelf; a downloaded one stays, unlinked.
    func cloudBookRemoved(_ id: String) {
        guard let book = book(id) else { return }
        if book.isOnDevice {
            update(id) { $0.cloud = nil }
        } else {
            books.removeAll { $0.id == id }
            covers[id] = nil
            save()
        }
    }

    /// Cloud books leave the shelf on sign-out; anything downloaded or imported stays.
    func forgetCloudOnlyBooks() {
        books.removeAll { $0.origin == .cloud && !$0.isOnDevice }
        save()
    }

    func download(_ book: LibraryBook) async {
        guard let cloud = book.cloud, state(of: book) != .downloading else { return }
        downloads[book.id] = .downloading
        do {
            let temp = try await sync.download(cloud)
            let name = "\(book.id).epub"
            let target = booksDir.appending(path: name)
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.copyItem(at: temp, to: target)
            update(book.id) { $0.fileName = name }
            downloads[book.id] = nil
            if covers[book.id] == nil, let meta = try? await BookOpener.shared.metadata(of: target), let cover = meta.cover {
                storeCover(cover, id: book.id)
            }
        } catch {
            downloads[book.id] = .failed(error.localizedDescription)
        }
    }

    // MARK: Files import

    /// Copies EPUBs from Files into the library. Returns the books added.
    @discardableResult
    func importBooks(from urls: [URL]) async -> [LibraryBook] {
        var added: [LibraryBook] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let id = "local-" + UUID().uuidString.lowercased()
            let name = "\(id).epub"
            let target = booksDir.appending(path: name)
            do {
                try FileManager.default.copyItem(at: url, to: target)
                let meta = try await BookOpener.shared.metadata(of: target)
                let book = LibraryBook(id: id, title: meta.title, author: meta.author, origin: .imported, fileName: name, added: Date())
                books.append(book)
                if let cover = meta.cover { storeCover(cover, id: id) }
                added.append(book)
            } catch {
                try? FileManager.default.removeItem(at: target)
                lastError = "\(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        save()
        return added
    }

    func remove(_ book: LibraryBook) {
        if let url = fileURL(of: book) { try? FileManager.default.removeItem(at: url) }
        if book.origin == .imported {
            books.removeAll { $0.id == book.id }
            covers[book.id] = nil
            try? FileManager.default.removeItem(at: coversDir.appending(path: "\(book.id).jpg"))
        } else {
            update(book.id) { $0.fileName = nil }
        }
        save()
    }

    // MARK: Reading state

    func update(_ id: String, _ change: (inout LibraryBook) -> Void) {
        guard let i = books.firstIndex(where: { $0.id == id }) else { return }
        change(&books[i])
        save()
    }

    func recordPlace(bookID: String, locatorJSON: String, totalProgression: Double, progression: Double) {
        let now = Date()
        update(bookID) {
            $0.locatorJSON = locatorJSON
            $0.totalProgression = totalProgression
            $0.lastOpened = now
        }
        guard let cloud = book(bookID)?.cloud else { return }
        let position = ReadingPosition(cfi: nil, progression: progression, totalProgression: totalProgression, updated: now, source: .gatefold)
        // One push per book at a time, latest wins: rapid turns settle on the last page, in order.
        pending[bookID] = (position, cloud)
        schedulePush(bookID, after: .milliseconds(400))
    }

    /// Sends waiting places now (the app is going to the background).
    func flushPushes() {
        for id in pending.keys { schedulePush(id, after: .zero) }
    }

    private func schedulePush(_ bookID: String, after delay: Duration) {
        let previous = pushes[bookID]
        previous?.cancel()
        pushes[bookID] = Task { [weak self, sync] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await previous?.value
            guard !Task.isCancelled, let self, let (position, cloud) = self.pending.removeValue(forKey: bookID) else { return }
            await sync.push(position, for: cloud)
        }
    }

    func remotePosition(for book: LibraryBook) async -> ReadingPosition? {
        guard let cloud = book.cloud else { return nil }
        let remote = try? await sync.remotePosition(for: cloud)
        if let remote { update(book.id) { $0.remote = remote } }
        return remote
    }

    // MARK: Covers

    func cover(for book: LibraryBook) -> UIImage? { covers[book.id] }

    private func loadCover(id: String, from url: URL) async {
        let data: Data?
        if url.isFileURL {
            data = try? Data(contentsOf: url)
        } else {
            data = try? await URLSession.shared.data(from: url).0
        }
        if let data, let image = UIImage(data: data) { storeCover(image, id: id) }
    }

    private func storeCover(_ image: UIImage, id: String) {
        let prepared = image.preparingThumbnail(of: CGSize(width: 600, height: 900 * image.size.height / max(image.size.width * 1.5, 1))) ?? image
        covers[id] = prepared
        if let data = prepared.jpegData(compressionQuality: 0.85) {
            try? data.write(to: coversDir.appending(path: "\(id).jpg"))
        }
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let saved = try? JSONDecoder().decode([LibraryBook].self, from: data) else { return }
        books = saved.map { book in
            var b = book
            if let name = b.fileName, !FileManager.default.fileExists(atPath: booksDir.appending(path: name).path) {
                b.fileName = nil
            }
            return b
        }
        for book in books {
            if let image = UIImage(contentsOfFile: coversDir.appending(path: "\(book.id).jpg").path) {
                covers[book.id] = image
            }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(books) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    /// Clears everything (DEBUG launch option for tests and screenshots).
    func wipe() {
        books = []
        covers = [:]
        downloads = [:]
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: booksDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: coversDir, withIntermediateDirectories: true)
    }
}
