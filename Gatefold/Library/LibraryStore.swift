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
    /// The Cloud has answered at least once since launch, so an empty shelf really is empty.
    private(set) var hasRefreshed = false
    /// An import that failed (shown as an alert: the reader just asked for it).
    var lastError: String?
    /// Why the last refresh didn't reach the Cloud (shown quietly on the shelf, never as an alert).
    private(set) var syncProblem: SyncProblem?
    /// When the Cloud last answered, kept across launches for "Up to date with your InkPad · 5 min ago".
    private(set) var lastSynced: Date? {
        didSet { UserDefaults.standard.set(lastSynced, forKey: Self.lastSyncedKey) }
    }
    /// The last Cloud fetch came back with no books at all: only then is an empty shelf really empty.
    private(set) var cloudIsEmpty = false
    /// Covers that couldn't be fetched: these books wear a typeset cover. Every other book without its
    /// cover yet is about to get one, so it shows plain paper instead of flashing a made-up cover.
    private(set) var coverless: Set<String> = []
    private static let lastSyncedKey = "lastSynced"
    /// The push task waiting or running per book. Each removes itself when it ends, so this holds only
    /// books with a push in flight.
    @ObservationIgnored private var pushes: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var pending: [String: (ReadingPosition, CloudBook)] = [:]

    private let sync: any SyncService
    let root: URL
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
        ReadingNow.shelf(books.filter { !$0.isFinished }.map(\.shelfItem), limit: 10).compactMap { item in books.first { $0.id == item.id } }
    }

    /// Books finished, most recent first.
    var finishedBooks: [LibraryBook] {
        books.filter(\.isFinished).sorted { ($0.finished ?? $0.lastOpened ?? $0.added) > ($1.finished ?? $1.lastOpened ?? $1.added) }
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
        defer { isRefreshing = false; hasRefreshed = true }
        do {
            // One request per page of books: each book already carries its position.
            let cloudBooks = try await sync.library()
            syncProblem = nil
            cloudIsEmpty = cloudBooks.isEmpty
            lastSynced = Date()
            prune(keeping: Set(cloudBooks.map(\.id)))
            await merge(cloudBooks)
        } catch {
            syncProblem = SyncProblem(error)
        }
    }

    /// After a full fetch: Cloud books that are no longer in the Cloud leave the shelf (a downloaded one
    /// stays, unlinked). The fake Cloud's demo books never belong on a real account's shelf.
    func prune(keeping cloudIDs: Set<String>) {
        for book in books where book.origin == .cloud && !cloudIDs.contains(book.id) {
            if book.isDemo {
                if let url = fileURL(of: book) { try? FileManager.default.removeItem(at: url) }
                books.removeAll { $0.id == book.id }
                covers[book.id] = nil
                try? FileManager.default.removeItem(at: coversDir.appending(path: "\(book.id).jpg"))
            } else {
                cloudBookRemoved(book.id)
            }
        }
        save()
    }

    /// Puts cloud books on the shelf, or updates the ones already there. Never fetches the library.
    func merge(_ cloudBooks: [CloudBook]) async {
        for cloudBook in cloudBooks {
            if let i = books.firstIndex(where: { $0.id == cloudBook.id }) {
                books[i].cloud = cloudBook
                books[i].remote = cloudBook.position ?? books[i].remote
                books[i].noteOtherDevice(cloudBook.position)
            } else {
                var book = LibraryBook(
                    id: cloudBook.id,
                    title: cloudBook.title,
                    author: cloudBook.authors ?? "",
                    origin: .cloud,
                    cloud: cloudBook,
                    remote: cloudBook.position,
                    added: cloudBook.createdAt ?? cloudBook.modifiedAt ?? Date()
                )
                book.noteOtherDevice(cloudBook.position)
                books.append(book)
            }
        }
        if !cloudBooks.isEmpty { cloudIsEmpty = false }
        save()
        await loadCovers(for: cloudBooks)
    }

    /// Fetches the missing covers side by side; a big shelf shouldn't fill in one cover at a time.
    private func loadCovers(for cloudBooks: [CloudBook]) async {
        let wanted = cloudBooks.compactMap { book -> (String, URL)? in
            guard covers[book.id] == nil else { return nil }
            guard let url = book.largeCoverURL ?? book.coverURL else {
                coverless.insert(book.id)
                return nil
            }
            return (book.id, url)
        }
        guard !wanted.isEmpty else { return }
        await withTaskGroup(of: (String, Data?).self) { group in
            for (id, url) in wanted {
                group.addTask {
                    if url.isFileURL { return (id, try? Data(contentsOf: url)) }
                    return (id, try? await URLSession.shared.data(from: url).0)
                }
            }
            for await (id, data) in group {
                if let data, let image = UIImage(data: data) {
                    storeCover(image, id: id)
                } else if covers[id] == nil {
                    coverless.insert(id)
                }
            }
        }
    }

    /// The book has no cover coming: show the typeset one.
    func isCoverless(_ book: LibraryBook) -> Bool {
        covers[book.id] == nil && (book.cloud == nil || coverless.contains(book.id))
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
            // The Cloud keeps its verified copy; a hard link shares it instead of doubling the space.
            do { try FileManager.default.linkItem(at: temp, to: target) } catch { try FileManager.default.copyItem(at: temp, to: target) }
            update(book.id) { $0.fileName = name }
            downloads[book.id] = nil
            if covers[book.id] == nil, let meta = try? await BookOpener.shared.metadata(of: target), let cover = meta.cover {
                storeCover(cover, id: book.id)
                coverless.remove(book.id)
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

    /// Saves the place here and queues it for the Cloud. `position` carries the exact CFI when the
    /// reader could make one; without it the Cloud gets a percent.
    func recordPlace(bookID: String, locatorJSON: String, totalProgression readium: Double, progression: Double,
                     position exact: ReadingPosition? = nil, at now: Date = Date()) {
        // After landing on a Cloud place, every number we show or send stays on the Cloud's scale, so a
        // difference in how two readers count never shows as lost progress.
        let totalProgression = book(bookID)?.cloudScale?.onCloudScale(readium) ?? readium
        update(bookID) {
            $0.locatorJSON = locatorJSON
            $0.totalProgression = totalProgression
            $0.lastOpened = now
        }
        guard let cloud = book(bookID)?.cloud else { return }
        var position = exact ?? ReadingPosition(cfi: nil, progression: progression, totalProgression: totalProgression, updated: now)
        position.totalProgression = totalProgression
        position.updated = now
        position.source = .gatefold
        // One push per book at a time, latest wins: rapid turns settle on the last page, in order.
        pending[bookID] = (position, cloud)
        schedulePush(bookID, after: .milliseconds(400))
    }

    /// The reader landed on another device's Cloud place: `cloud` is the Cloud's progress there and
    /// `landed` Readium's for the same words. Replaces any earlier scale; none is kept when ours is
    /// already at or above the Cloud's.
    func landedOnCloudPlace(bookID: String, cloud: Double, landed: Double) {
        update(bookID) { $0.cloudScale = CloudScale(cloud: cloud, landed: landed) }
    }

    /// A reading session began: remembers when the book was first opened and counts the sessions.
    func noteSession(_ id: String, at now: Date = Date()) {
        update(id) {
            if $0.started == nil { $0.started = now }
            $0.sessions = ($0.sessions ?? 0) + 1
        }
    }

    /// The reader turned past the story's last page.
    func markFinished(_ id: String, at now: Date = Date()) {
        update(id) { if $0.finished == nil { $0.finished = now } }
    }

    /// "Mark Finished on InkPad": 100 % and `read_status` "read" in the Cloud, so the InkPad's
    /// library shows it finished too.
    func markFinishedInCloud(_ id: String, at now: Date = Date()) async {
        markFinished(id, at: now)
        guard let cloud = book(id)?.cloud else { return }
        pending[id] = nil
        var done = ReadingPosition(cfi: nil, progression: 1, totalProgression: 1, updated: now)
        done.source = .gatefold
        await sync.push(done, for: cloud)
        await sync.markRead(cloud)
        await sync.flushOutbox()
    }

    /// Sends waiting places now (the app is going to the background).
    func flushPushes() {
        for id in pending.keys { schedulePush(id, after: .zero) }
    }

    /// Hands every waiting place to the sync service and asks it to send at once (book closed, app
    /// leaving). Returns when the service has tried.
    func sendPendingPushes() async {
        flushPushes()
        for push in Array(pushes.values) { await push.task.value }
        await sync.flushOutbox()
    }

    /// The place waiting to go to the Cloud for a book (tests).
    func pendingPush(for bookID: String) -> ReadingPosition? { pending[bookID]?.0 }

    /// Books with a push waiting or running (tests).
    var pushesInFlight: Int { pushes.count }

    private func schedulePush(_ bookID: String, after delay: Duration) {
        let previous = pushes[bookID]?.task
        previous?.cancel()
        let id = UUID()
        pushes[bookID] = (id, Task { [weak self, sync] in
            // Done, sent or overtaken: leave the table unless a newer push has taken this book's slot.
            defer { if self?.pushes[bookID]?.id == id { self?.pushes[bookID] = nil } }
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await previous?.value
            guard !Task.isCancelled, let self, let (position, cloud) = self.pending.removeValue(forKey: bookID) else { return }
            await sync.push(position, for: cloud)
        })
    }

    func remotePosition(for book: LibraryBook) async -> ReadingPosition? {
        guard let cloud = book.cloud else { return nil }
        let remote = try? await sync.remotePosition(for: cloud)
        if let remote {
            update(book.id) {
                $0.remote = remote
                $0.noteOtherDevice(remote)
            }
        }
        return remote
    }

    /// What the shelf shows when the Cloud can't be reached.
    enum SyncProblem: Equatable {
        case offline
        case signInExpired
        case other(String)

        init(_ error: Error) {
            switch error as? CloudError {
            case .offline?, .network(_)?: self = .offline
            case .authenticationRequired?, .notSignedIn?: self = .signInExpired
            default: self = .other(error.localizedDescription)
            }
        }
    }

    // MARK: Covers

    func cover(for book: LibraryBook) -> UIImage? { covers[book.id] }

    private func storeCover(_ image: UIImage, id: String) {
        let prepared = image.preparingThumbnail(of: CGSize(width: 600, height: 900 * image.size.height / max(image.size.width * 1.5, 1))) ?? image
        covers[id] = prepared
        if let data = prepared.jpegData(compressionQuality: 0.85) {
            try? data.write(to: coversDir.appending(path: "\(id).jpg"))
        }
    }

    // MARK: Persistence

    private func load() {
        lastSynced = UserDefaults.standard.object(forKey: Self.lastSyncedKey) as? Date
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
        coverless = []
        lastSynced = nil
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: booksDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: coversDir, withIntermediateDirectories: true)
    }
}
