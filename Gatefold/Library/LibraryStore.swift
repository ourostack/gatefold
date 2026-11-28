import CryptoKit
import Foundation
import GatefoldCloud
import GatefoldCore
import Observation
import UIKit

/// This device's shelf. Cloud books merge with imported ones; places, bookmarks and covers persist
/// under Application Support, so the app is a whole reader without any account (design brief D8).
@MainActor @Observable
final class LibraryStore {
    private(set) var books: [LibraryBook] = []
    private(set) var downloads: [String: DownloadState] = [:]
    /// When each download under way began, for the tap telemetry's "downloading for how long".
    private var downloadStarted: [String: Date] = [:]
    /// How far each download under way has got (0 to 1), where its transfer can say.
    private(set) var downloadProgress: [String: Double] = [:]
    /// Each download under way, so a tap can stop it. The token tells a stopped download's late end from a new one's.
    private var downloadTasks: [String: (token: UUID, task: Task<Void, Never>)] = [:]
    /// One tap on a book in the Cloud downloads it and then opens it, if he is still waiting for it.
    private var openAfterDownload = OpenAfterDownload()
    /// A book to open now: it landed while he waited on the shelf. The root view opens it and clears this.
    var openRequest: String?
    /// The app is in front with the shelf showing and nothing over it, as a download lands.
    @ObservationIgnored var shelfInFront: @MainActor () -> Bool = { ShelfFront.isShowing }
    private(set) var covers: [String: UIImage] = [:]
    private(set) var isRefreshing = false
    /// The Cloud has answered at least once since launch, so an empty shelf really is empty.
    private(set) var hasRefreshed = false
    /// An import that failed (shown as an alert: the reader just asked for it).
    var lastError: String?
    /// Why the last refresh didn't reach the Cloud (shown quietly on the shelf, never as an alert).
    private(set) var syncProblem: SyncProblem?
    /// When the Cloud last answered, kept across launches for "In step with your e-reader · 5 min ago".
    private(set) var lastSynced: Date? {
        didSet { UserDefaults.standard.set(lastSynced, forKey: Self.lastSyncedKey) }
    }
    /// Books whose last place read here the Cloud turned away, so the e-reader never got it. While any
    /// remain, the shelf says so instead of "In step with your e-reader". Kept across launches.
    private(set) var placesNotSent: Set<String> = [] {
        didSet { try? JSONEncoder().encode(placesNotSent.sorted()).write(to: placesNotSentURL) }
    }
    var placesReachEReader: Bool { placesNotSent.isEmpty }
    static let placesNotSentLine = "Places read here aren't reaching your e-reader. The cloud is turning them away."
    private var placesNotSentURL: URL { root.appending(path: "places-not-sent.json") }

    func placeRefused(_ fastHash: String) { placesNotSent.insert(fastHash) }
    func placeSent(_ fastHash: String) { if placesNotSent.contains(fastHash) { placesNotSent.remove(fastHash) } }

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
        if let data = try? Data(contentsOf: placesNotSentURL), let saved = try? JSONDecoder().decode([String].self, from: data) {
            placesNotSent = Set(saved)
        }
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

    /// Fetches the shelf. Only a whole, successful listing changes it: a cancelled pull, an error or a
    /// listing that comes back empty once (while the shelf has Cloud books) leaves every book where it is.
    func refresh() async {
        guard await sync.account != nil else { return }
        isRefreshing = true
        defer { isRefreshing = false; hasRefreshed = true }
        do {
            // One request per page of books: each book already carries its position.
            var cloudBooks = try await sync.library()
            if cloudBooks.isEmpty, books.contains(where: { $0.origin == .cloud }) {
                // A Cloud that suddenly lists nothing is more likely having a bad moment than emptied:
                // ask once more before taking his books off the shelf.
                cloudBooks = try await sync.library()
            }
            // Signed out while the listing was on its way: it no longer belongs on the shelf.
            guard await sync.account != nil else { return }
            syncProblem = nil
            cloudIsEmpty = cloudBooks.isEmpty
            lastSynced = Date()
            prune(keeping: Set(cloudBooks.map(\.id)))
            await merge(cloudBooks)
        } catch {
            // A cancelled refresh (the pull let go) is not a problem: keep whatever the shelf said before.
            guard let problem = SyncProblem(error) else { return }
            syncProblem = problem
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
            } else if let localID = await copyFromBeforeSignIn(of: cloudBook) {
                fold(localID, into: cloudBook)
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

    /// A book on this device and not linked to the Cloud (imported, or a sample, from before he signed in) that
    /// is this Cloud book's file: the same MD5 and size, or, when the Cloud's checksum isn't a real MD5 (it is
    /// often the fast_hash), the same size to the byte and the same title.
    private func copyFromBeforeSignIn(of cloudBook: CloudBook) async -> String? {
        guard cloudBook.bytes > 0 else { return nil }
        let sameSize = books.filter { $0.cloud == nil }.compactMap { book -> (String, String, URL)? in
            guard let url = fileURL(of: book),
                  (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 == cloudBook.bytes else { return nil }
            return (book.id, book.title, url)
        }
        for (id, title, url) in sameSize {
            if let md5 = cloudBook.verifiableMD5 {
                if (try? await Self.fingerprint(of: url))?.md5Base64 == md5 { return id }
            } else if Self.folded(title) == Self.folded(cloudBook.title) {
                return id
            }
        }
        return nil
    }

    nonisolated static func folded(_ title: String) -> String {
        title.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// One shelf entry: the local copy becomes the Cloud book in its place on the shelf, so its place goes to
    /// and from the e-reader. Its file, reading, bookmarks, cover and highlights come with it.
    private func fold(_ localID: String, into cloudBook: CloudBook) {
        guard let i = books.firstIndex(where: { $0.id == localID }), let oldName = books[i].fileName else { return }
        let name = "\(cloudBook.id).epub"
        if oldName != name {
            // The Cloud book takes the file under its own name, so the Cloud's download path finds it.
            let target = booksDir.appending(path: name)
            try? FileManager.default.removeItem(at: target)
            guard (try? FileManager.default.moveItem(at: booksDir.appending(path: oldName), to: target)) != nil else { return }
        }
        var book = books[i]
        book.id = cloudBook.id
        book.origin = .cloud
        book.cloud = cloudBook
        book.fileName = name
        book.remote = cloudBook.position ?? book.remote
        book.noteOtherDevice(cloudBook.position)
        books[i] = book
        downloads[localID] = nil
        if let cover = covers.removeValue(forKey: localID) {
            covers[cloudBook.id] = cover
            try? FileManager.default.moveItem(at: coversDir.appending(path: "\(localID).jpg"), to: coversDir.appending(path: "\(cloudBook.id).jpg"))
        }
        HighlightStore.carryCache(from: localID, to: cloudBook.id)
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

    /// Each book as it lands on the device, for the root view's open of a book asked for before it was here
    /// (`-GatefoldOpenBook`, Shortcuts). A stream, not a count the view watches: on CI a launch asked for Emma, the
    /// last book to download, and the view's change handler fired for the first seven landings but never for hers,
    /// so she never opened (gatefold#432).
    @ObservationIgnored private var landed: AsyncStream<String>.Continuation?

    /// The books landing from now on, in order. One listener at a time: a new call ends the stream before it.
    func landings() -> AsyncStream<String> {
        landed?.finish()
        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        landed = continuation
        return stream
    }

    /// A tap on a book that isn't here yet means "read this": it downloads, and opens as it lands if he is still
    /// waiting on the shelf; if he has gone elsewhere, it waits there, Ready (`OpenAfterDownload`).
    func tapToRead(_ book: LibraryBook, telemetry: GatefoldTelemetry = .shared) {
        noteDownloadTap(book, telemetry: telemetry)
        openAfterDownload.tapped(book.id)
        // Started now, so the tile says so from this frame on and a quick second tap meets it on its way.
        startDownload(book)
    }

    /// Stops a download under way: the book waits in the Cloud again, with no error, and won't open by itself.
    func stopDownload(_ book: LibraryBook) {
        openAfterDownload.stopped(book.id)
        guard let running = downloadTasks.removeValue(forKey: book.id) else { return }
        downloads[book.id] = nil
        downloadStarted[book.id] = nil
        downloadProgress[book.id] = nil
        running.task.cancel()
    }

    /// He went elsewhere (a sheet, another screen, the app into the background): no download opens by itself now.
    func leftShelf() { openAfterDownload.left() }

    /// A book opened: he isn't waiting for another to land, and this one is no longer Ready.
    func noteOpened(_ book: LibraryBook) { openAfterDownload.opened(book.id) }

    /// Downloaded while he was elsewhere, after he asked for it, and not opened since.
    func isReady(_ book: LibraryBook) -> Bool { openAfterDownload.isReady(book.id) }

    /// Downloads a book and returns when it has landed, failed or been stopped. A second call for a book already on
    /// its way waits for that download.
    func download(_ book: LibraryBook) async {
        await startDownload(book)?.value
    }

    /// Starts a book's download, or finds the one already on its way; nil for a book with nothing to download.
    @discardableResult
    private func startDownload(_ book: LibraryBook) -> Task<Void, Never>? {
        if let running = downloadTasks[book.id] { return running.task }
        guard let cloud = book.cloud, state(of: book) != .downloading else { return nil }
        let token = UUID()
        downloads[book.id] = .downloading
        downloadStarted[book.id] = Date()
        let task = Task { await fetch(book, cloud: cloud, token: token) }
        downloadTasks[book.id] = (token, task)
        return task
    }

    /// This download is still the book's own: not stopped, and not followed by another.
    private func isCurrent(_ id: String, _ token: UUID) -> Bool { downloadTasks[id]?.token == token }

    private func finish(_ id: String) {
        downloadTasks[id] = nil
        downloadStarted[id] = nil
        downloadProgress[id] = nil
    }

    private func fetch(_ book: LibraryBook, cloud: CloudBook, token: UUID) async {
        let id = book.id
        let progress: DownloadProgress = { fraction in
            Task { @MainActor [weak self] in
                guard let self, self.isCurrent(id, token) else { return }
                self.downloadProgress[id] = fraction
            }
        }
        var fetched = false
        do {
            let temp = try await sync.download(cloud, progress: progress)
            // Stopped as it landed: he asked for it not to come.
            guard isCurrent(id, token) else { return }
            fetched = true
            let name = "\(book.id).epub"
            let target = booksDir.appending(path: name)
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            // The Cloud keeps its verified copy; a hard link shares it instead of doubling the space.
            do { try FileManager.default.linkItem(at: temp, to: target) } catch { try FileManager.default.copyItem(at: temp, to: target) }
            // The Cloud's copy may differ from a file this book held before: its digest is worked out again.
            update(book.id) { $0.fileName = name; $0.digest = nil }
            finish(id)
            downloads[book.id] = nil
            landed?.yield(book.id)
            if openAfterDownload.landed(id, shelfInFront: shelfInFront()) == .open { openRequest = id }
            if covers[book.id] == nil, let meta = try? await BookOpener.shared.metadata(of: target), let cover = meta.cover {
                storeCover(cover, id: book.id)
                coverless.remove(book.id)
            }
        } catch {
            // Stopped: the stop has already put the book back in the Cloud.
            guard isCurrent(id, token) else { return }
            finish(id)
            if fetched {
                // The Cloud's part worked; putting the book on the shelf did not. The Cloud's own stages
                // report themselves (DownloadReports); this one is ours.
                var report = DownloadReport(stage: .shelve, format: "epub", isDRM: cloud.isDRM)
                report.note(error)
                DownloadReports.shared.record(report)
            }
            openAfterDownload.failed(id)
            if let message = FriendlyError.message(for: error) {
                downloads[book.id] = .failed(message)
            } else {
                downloads[book.id] = nil // called off: back to waiting in the Cloud
            }
        }
    }

    /// Reports a tap on a book that isn't on the device: counts only (`GatefoldTelemetry.tapProperties`).
    func noteDownloadTap(_ book: LibraryBook, telemetry: GatefoldTelemetry = .shared) {
        let state = state(of: book)
        let waited = state == .downloading ? downloadStarted[book.id].map { Date().timeIntervalSince($0) } : nil
        telemetry.capture("gatefold_download_tap",
                          properties: GatefoldTelemetry.tapProperties(state: state, hasCloudCopy: book.cloud != nil, secondsDownloading: waited))
    }

    // MARK: Adding books

    /// What one round of adding books did, for the shelf's word afterwards and the counts-only telemetry.
    struct ImportResult: Equatable {
        /// New books on the shelf.
        var added: [LibraryBook] = []
        /// Books that were on the shelf already (the same bytes), or Cloud books that took the file.
        var alreadyHere: [LibraryBook] = []
        /// PocketBook Cloud books, not yet on this device, that took the file as their own.
        var linkedToCloud = 0
        /// Files that weren't books Gatefold reads.
        var refused = 0

        /// The book to show or open when one book came in.
        var single: LibraryBook? { added.count + alreadyHere.count == 1 ? (added.first ?? alreadyHere.first) : nil }
    }

    /// Takes books into the library: zipped EPUBs, EPUB folders (zipped on the way in) and folders of
    /// either. The same bytes already on the shelf, or a PocketBook Cloud book whose checksum is this
    /// file's, never become a second book. Returns what happened, and reports it as counts.
    @discardableResult
    func importBooks(from urls: [URL], source: LibraryBook.Source = .files, telemetry: GatefoldTelemetry? = .shared) async -> ImportResult {
        await oneAtATime { await self.importNow(from: urls.map { (url: $0, id: String?.none) }, source: source, telemetry: telemetry) }
    }

    /// Public-domain books from Project Gutenberg that ship in the app (Resources/SampleBooks), the same ones the
    /// App Store screenshots show. A reader with no PocketBook account, App Review included, gets a real shelf in one
    /// tap (Guidelines 2.1 and 4.2).
    static let sampleShelf = ["frankenstein", "pride-and-prejudice", "moby-dick", "dracula", "alice-in-wonderland",
                              "sherlock-holmes", "emma"]

    /// Puts the sample books on the shelf, as books of his own (`imported`, on the device). Each has a fixed ID, so a
    /// second tap adds only the ones he has since removed, and a tap while another is still adding (two iPad windows)
    /// waits its turn and adds nothing. The shelf lists newest first, so they go on in reverse and Frankenstein leads.
    @discardableResult
    func addSampleShelf(bundle: Bundle = .main, telemetry: GatefoldTelemetry? = .shared) async -> ImportResult {
        let bundled: [(url: URL, id: String?)] = Self.sampleShelf.reversed().compactMap { resource in
            bundle.url(forResource: resource, withExtension: "epub").map { (url: $0, id: "sample-\(resource)") }
        }
        return await oneAtATime {
            // Read the shelf only once it is this tap's turn, so a tap behind another finds its books already on.
            let missing = bundled.filter { file in !self.books.contains { $0.id == file.id } }
            guard !missing.isEmpty else { return ImportResult() }
            return await self.importNow(from: missing, source: .sample, telemetry: telemetry)
        }
    }

    /// One import at a time: two arriving together (several files opened in Gatefold at once, a share during a Files
    /// import, two taps on the classics) would otherwise both find a book new before either had shelved it.
    private func oneAtATime(_ work: @escaping @MainActor @Sendable () async -> ImportResult) async -> ImportResult {
        let previous = importTail
        let run = Task { () -> ImportResult in
            await previous?.value
            return await work()
        }
        importTail = Task { _ = await run.value }
        return await run.value
    }

    @ObservationIgnored private var importTail: Task<Void, Never>?

    /// Each file comes in under a new `local-` ID, or under the fixed one beside it (the bundled classics).
    private func importNow(from files: [(url: URL, id: String?)], source: LibraryBook.Source, telemetry: GatefoldTelemetry?) async -> ImportResult {
        var result = ImportResult()
        var refusedNames: [String] = []
        var sawPDF = false
        await backfillDigests()
        for (url, fixedID) in files {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            for item in await Self.expand(url) {
                switch await importOne(item, source: source, id: fixedID) {
                case let .added(book): result.added.append(book)
                case let .alreadyHere(book): result.alreadyHere.append(book)
                case let .linked(book): result.alreadyHere.append(book); result.linkedToCloud += 1
                case let .refused(kind):
                    result.refused += 1
                    if kind == .pdf { sawPDF = true }
                    refusedNames.append(item.deletingPathExtension().lastPathComponent)
                case .cancelled: break
                }
            }
        }
        save()
        if !refusedNames.isEmpty { lastError = Self.refusal(names: refusedNames, sawPDF: sawPDF) }
        if let telemetry, result != ImportResult() {
            telemetry.capture("gatefold_books_added", properties: GatefoldTelemetry.addedProperties(source: source, result: result))
        }
        return result
    }

    private enum ImportOutcome {
        case added(LibraryBook)
        case alreadyHere(LibraryBook)
        case linked(LibraryBook)
        case refused(BookFile.Kind)
        case cancelled
    }

    /// A folder that isn't itself a book stands for the books inside it, listed by name through a file
    /// coordinator, so a folder in iCloud Drive is listed without downloading every book in it first.
    nonisolated static func expand(_ url: URL) async -> [URL] {
        await Task.detached(priority: .userInitiated) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  !FileManager.default.fileExists(atPath: url.appending(path: "META-INF/container.xml").path)
            else { return [url] }
            var found: [URL] = []
            var error: NSError?
            NSFileCoordinator().coordinate(readingItemAt: url, options: .immediatelyAvailableMetadataOnly, error: &error) { readable in
                found = BookFile.books(in: readable)
            }
            return found
        }.value
    }

    /// With a fixed `id`, a file already at its place with no book on the shelf for it (an import the app was killed in
    /// the middle of) is replaced. On a failure it deletes only the file it wrote.
    private func importOne(_ url: URL, source: LibraryBook.Source, id fixedID: String? = nil) async -> ImportOutcome {
        let id = fixedID ?? "local-" + UUID().uuidString.lowercased()
        let name = "\(id).epub"
        let target = booksDir.appending(path: name)
        var owned = false  // whether this call put the file at `target`, so a failure deletes only its own
        do {
            if fixedID != nil, !books.contains(where: { $0.id == id }), FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            owned = !FileManager.default.fileExists(atPath: target.path)
            let kind = try await Self.take(url, to: target)
            guard kind == .epub || kind == .epubFolder else { return .refused(kind) }
            let found = try await Self.fingerprint(of: target)
            switch ShelfMatch.match(found, on: shelfCandidates) {
            case let .alreadyHere(existing):
                if owned { try? FileManager.default.removeItem(at: target) }
                return book(existing).map { .alreadyHere($0) } ?? .cancelled
            case let .takeCloudBook(cloudID):
                // The PocketBook book takes the file under its own name, so the Cloud's download path finds it.
                let cloudName = "\(cloudID).epub"
                let cloudTarget = booksDir.appending(path: cloudName)
                try? FileManager.default.removeItem(at: cloudTarget)
                try FileManager.default.moveItem(at: target, to: cloudTarget)
                update(cloudID) {
                    $0.fileName = cloudName
                    $0.digest = found.sha256
                }
                // A download that failed earlier no longer stands: the book is here.
                downloads[cloudID] = nil
                return book(cloudID).map { .linked($0) } ?? .cancelled
            case .new:
                let meta = try await BookOpener.shared.metadata(of: target)
                let book = LibraryBook(id: id, title: meta.title, author: meta.author, origin: .imported, source: source,
                                       digest: found.sha256, fileName: name, added: Date())
                books.append(book)
                if let cover = meta.cover { storeCover(cover, id: id) }
                return .added(book)
            }
        } catch {
            if owned { try? FileManager.default.removeItem(at: target) }
            if FriendlyError.isCancellation(error) { return .cancelled }
            return .refused(.other)
        }
    }

    /// Copies a zipped EPUB, or zips an EPUB folder, to `target`, reading through a file coordinator so
    /// a book still in iCloud Drive downloads first. Returns what it found; anything else isn't copied.
    nonisolated private static func take(_ url: URL, to target: URL) async throws -> BookFile.Kind {
        try await Task.detached(priority: .userInitiated) {
            var coordinated: NSError?
            var kind = BookFile.Kind.other
            var failure: Error?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinated) { readable in
                do {
                    kind = BookFile.kind(at: readable)
                    switch kind {
                    case .epub: try FileManager.default.copyItem(at: readable, to: target)
                    case .epubFolder: try BookFile.pack(folder: readable, to: target)
                    case .pdf, .folder, .other: break
                    }
                } catch { failure = error }
            }
            if let error = coordinated ?? failure { throw error }
            return kind
        }.value
    }

    /// SHA-256 and MD5 of a file, read in pieces so a big book never sits in memory whole.
    nonisolated static func fingerprint(of url: URL) async throws -> ShelfMatch.Fingerprint {
        try await Task.detached(priority: .userInitiated) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var sha = SHA256(), md5 = Insecure.MD5()
            var bytes: Int64 = 0
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                sha.update(data: chunk)
                md5.update(data: chunk)
                bytes += Int64(chunk.count)
            }
            return ShelfMatch.Fingerprint(sha256: sha.finalize().map { String(format: "%02x", $0) }.joined(),
                                          md5Base64: Data(md5.finalize()).base64EncodedString(), bytes: bytes)
        }.value
    }

    /// The shelf as `ShelfMatch` sees it.
    private var shelfCandidates: [ShelfMatch.Candidate] {
        books.map { book in
            ShelfMatch.Candidate(id: book.id, sha256: book.isOnDevice ? book.digest : nil, cloudMD5: book.cloud?.verifiableMD5,
                                 cloudBytes: book.cloud.map(\.bytes), isOnDevice: book.isOnDevice)
        }
    }

    /// Books on this device from before Gatefold kept digests get theirs, so a file coming in can be
    /// matched against them. Each file is read once, ever.
    private func backfillDigests() async {
        let missing = books.filter { $0.isOnDevice && $0.digest == nil }.compactMap { book in fileURL(of: book).map { (book.id, $0) } }
        guard !missing.isEmpty else { return }
        // Off the main actor: a big shelf's first import after updating would otherwise freeze the screen.
        let found = await Task.detached(priority: .userInitiated) {
            missing.compactMap { id, url in LibraryStore.sha256(of: url).map { (id, $0) } }
        }.value
        for (id, digest) in found {
            if let i = books.firstIndex(where: { $0.id == id }) { books[i].digest = digest }
        }
    }

    nonisolated private static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var sha = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { sha.update(data: chunk) }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// What the alert says when files didn't come aboard.
    nonisolated static func refusal(names: [String], sawPDF: Bool) -> String {
        let what = names.count == 1 ? "“\(names[0])” didn't come aboard." : "\(names.count) files didn't come aboard."
        return sawPDF ? "\(what) Gatefold reads EPUB books, and doesn't open PDFs yet." : "\(what) Gatefold reads EPUB books; is this one?"
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
        // The place is kept on Readium's scale, the one this reader compares places on. After landing on
        // a Cloud place, what we send is on the Cloud's scale (and the shelf shows it, `displayProgression`),
        // so a difference in how two readers count never shows as lost progress.
        let totalProgression = book(bookID)?.cloudScale?.onCloudScale(readium) ?? readium
        update(bookID) {
            $0.locatorJSON = locatorJSON
            $0.totalProgression = readium
            $0.lastOpened = now
        }
        onPlaceRecorded?(bookID)
        guard let cloud = book(bookID)?.cloud else { return }
        var position = exact ?? ReadingPosition(cfi: nil, progression: progression, totalProgression: totalProgression, updated: now)
        position.totalProgression = totalProgression
        position.updated = now
        position.source = .gatefold
        // One push per book at a time, latest wins: rapid turns settle on the last page, in order.
        pending[bookID] = (position, cloud)
        schedulePush(bookID, after: .milliseconds(400))
    }

    /// Hears of each place kept here, after it is saved: the watched folder passes it to the other devices.
    @ObservationIgnored var onPlaceRecorded: ((String) -> Void)?

    /// Another device's newer place for a book from the watched folder. It becomes this device's place,
    /// as if read here at `updated`, so the shelf and the reader open on it; it isn't sent anywhere.
    func takeFolderPlace(bookID: String, locatorJSON: String, totalProgression: Double, updated: Date) {
        update(bookID) {
            $0.locatorJSON = locatorJSON
            $0.totalProgression = totalProgression
            $0.lastOpened = updated
        }
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

    /// "Mark Finished on Your E-reader": 100 % and `read_status` "read" in the Cloud, so the InkPad's
    /// library shows it finished too.
    func markFinishedInCloud(_ id: String, at now: Date = Date()) async {
        markFinished(id, at: now)
        guard let cloud = book(id)?.cloud else { return }
        pending[id] = nil
        var done = ReadingPosition(cfi: nil, progression: 1, totalProgression: 1, updated: now)
        done.source = .gatefold
        await sync.push(done, for: cloud)
        await sync.markRead(cloud)
        await sync.flushOutbox(trigger: .finished)
    }

    /// Sends waiting places now (the app is going to the background).
    func flushPushes() {
        for id in pending.keys { schedulePush(id, after: .zero) }
    }

    /// Hands every waiting place to the sync service and asks it to send at once (book closed, app
    /// leaving). Returns when the service has tried.
    func sendPendingPushes(trigger: PlaceReport.Trigger = .other) async {
        flushPushes()
        for push in Array(pushes.values) { await push.task.value }
        await sync.flushOutbox(trigger: trigger)
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

    func remotePosition(for book: LibraryBook, telemetry: GatefoldTelemetry = .shared) async -> ReadingPosition? {
        guard let cloud = book.cloud else { return nil }
        let remote: ReadingPosition?
        let reSignInBefore = await sync.reSignIn()
        do {
            remote = try await sync.remotePosition(for: cloud)
            telemetry.capture(Self.pullReport(remote: remote, local: book))
        } catch {
            var report = PlaceReport(direction: .pull, result: .failed, reason: .error)
            report.note(error)
            report.note(reSignIn: await sync.reSignIn(), since: reSignInBefore)
            telemetry.capture(report)
            remote = nil
        }
        if let remote {
            update(book.id) {
                $0.remote = remote
                $0.noteOtherDevice(remote)
            }
        }
        return remote
    }

    /// The counts-only report of one place fetch: who wrote the Cloud's place, and whether it is newer
    /// or further on than the place here. Never the place itself.
    nonisolated static func pullReport(remote: ReadingPosition?, local book: LibraryBook) -> PlaceReport {
        guard let remote else { return PlaceReport(direction: .pull, result: .skipped, reason: .noPlace) }
        var report = PlaceReport(direction: .pull, result: .received, hasCFI: remote.parsedCFI != nil,
                                 remoteSource: PlaceReport.sourceName(remote.source))
        report.remoteNewer = book.lastOpened.map { remote.updated > $0 } ?? true
        report.remoteAhead = remote.wholePercent > ReadingPercent.whole(book.totalProgression)
        return report
    }

    /// What the shelf shows when the Cloud can't be reached. Always in the reader's words (`FriendlyError`).
    enum SyncProblem: Equatable {
        case offline
        case signInExpired
        case other(String)

        /// Nil for a cancellation: that is not a problem, and nothing is shown.
        init?(_ error: Error) {
            let friendly = FriendlyError(error)
            switch friendly {
            case .cancelled: return nil
            case .offline: self = .offline
            case .sessionExpired: self = .signInExpired
            default: self = .other(friendly.message ?? FriendlyError.unknown.message!)
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
        for running in downloadTasks.values { running.task.cancel() }
        downloadTasks = [:]
        downloadStarted = [:]
        downloadProgress = [:]
        downloads = [:]
        openAfterDownload = OpenAfterDownload()
        openRequest = nil
        coverless = []
        lastSynced = nil
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: booksDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: coversDir, withIntermediateDirectories: true)
    }
}

/// Whether the shelf is what he is looking at: the app active, and nothing presented over the shelf (the reader, a
/// sheet, the Files picker, an alert). Asked as a download lands, to open it or leave it Ready.
enum ShelfFront {
    @MainActor static var isShowing: Bool {
        guard UIApplication.shared.applicationState == .active else { return false }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.filter { $0.activationState == .foregroundActive }
        let windows = scenes.flatMap(\.windows)
        guard let root = (windows.first(where: \.isKeyWindow) ?? windows.first)?.rootViewController else { return false }
        return root.presentedViewController == nil
    }
}
