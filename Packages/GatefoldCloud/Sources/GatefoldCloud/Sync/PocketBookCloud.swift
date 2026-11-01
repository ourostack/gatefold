import CryptoKit
import Foundation

/// `SyncService` for PocketBook Cloud.
public actor PocketBookCloud: SyncService {
    public struct Configuration: Sendable {
        /// Holds `Books/`, the library cache and the outbox. Use a directory inside Application Support.
        public var storageDirectory: URL
        /// Send queued writes by itself (after a short debounce, then with backoff). Off in tests.
        public var autoFlush: Bool
        /// How `pointer_pb` is written. `.external` is what PocketBook's own mobile apps write.
        public var pointerStyle: PocketBookAnchor.Style
        public var debounce: TimeInterval

        public init(storageDirectory: URL, autoFlush: Bool = true, pointerStyle: PocketBookAnchor.Style = .external, debounce: TimeInterval = 2) {
            self.storageDirectory = storageDirectory
            self.autoFlush = autoFlush
            self.pointerStyle = pointerStyle
            self.debounce = debounce
        }
    }

    /// PocketBook's iOS reader crashes on EPUBs this small, so we never upload one.
    public static let minimumUploadBytes: Int64 = 4096
    static let maxAttempts = 12

    public nonisolated let session: CloudSession
    let configuration: Configuration
    let transport: HTTPTransport
    let now: @Sendable () -> Date
    let jitter: @Sendable () -> Double
    let sleep: @Sendable (Duration) async throws -> Void
    private let broadcaster = ChangeBroadcaster()

    private var books: [CloudBook]
    private var state: OutboxState
    private var pageSize = 100
    private var draining: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var timerDue: Date?
    private var blockedOnSignIn = false
    /// The outbox item being sent right now.
    private var inFlight: UUID?
    /// Bumped on sign-in and sign-out; a send that straddles one must not touch the new state.
    private var accountGeneration = 0

    private var booksDirectory: URL { configuration.storageDirectory.appendingPathComponent("Books", isDirectory: true) }
    private var partialDirectory: URL { configuration.storageDirectory.appendingPathComponent("Partial", isDirectory: true) }
    private var libraryFile: URL { configuration.storageDirectory.appendingPathComponent("library.json") }
    private var outboxFile: URL { configuration.storageDirectory.appendingPathComponent("outbox.json") }

    public init(configuration: Configuration,
                transport: HTTPTransport = URLSessionTransport(),
                credentials: ClientCredentialsProvider? = nil,
                tokenStore: TokenStore = KeychainTokenStore(),
                base: URL = CloudSession.defaultBase,
                now: @escaping @Sendable () -> Date = { Date() },
                jitter: @escaping @Sendable () -> Double = { Double.random(in: 0.8...1.2) },
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.configuration = configuration
        self.transport = transport
        self.now = now
        self.jitter = jitter
        self.sleep = sleep
        self.session = CloudSession(transport: transport, credentials: credentials ?? WebBundleCredentials(transport: transport),
                                    tokenStore: tokenStore, base: base, now: now)
        let fm = FileManager.default
        let dir = configuration.storageDirectory
        for sub in ["Books", "Partial"] {
            try? fm.createDirectory(at: dir.appendingPathComponent(sub, isDirectory: true), withIntermediateDirectories: true)
        }
        // Leftovers from downloads a previous launch did not finish.
        let partial = dir.appendingPathComponent("Partial", isDirectory: true)
        for file in (try? fm.contentsOfDirectory(at: partial, includingPropertiesForKeys: nil)) ?? [] { try? fm.removeItem(at: file) }
        books = JSONFile.read([CloudBook].self, at: dir.appendingPathComponent("library.json")) ?? []
        state = JSONFile.readOrSetAside(OutboxState.self, at: dir.appendingPathComponent("outbox.json"), now: now()) ?? OutboxState()
    }

    public nonisolated func changes() -> AsyncStream<CloudChange> { broadcaster.stream() }

    // MARK: Accounts

    public var account: CloudAccount? {
        get async { await session.account }
    }

    /// Fetches what sign-in needs (the web app's client pair) ahead of time, so the store lookup
    /// after the reader types their email is quick. Failures are left for sign-in to report.
    public func prepareSignIn() async {
        _ = try? await session.credentials.credentials(refresh: false)
    }

    public func stores(forEmail email: String) async throws -> [CloudStore] {
        try await session.stores(forEmail: email)
    }

    public func signIn(email: String, password: String, store: CloudStore) async throws -> CloudAccount {
        let account = try await session.signIn(email: email, password: password, store: store)
        if let owner = state.owner, owner.caseInsensitiveCompare(account.email) != .orderedSame {
            state = OutboxState()
            books = []
            JSONFile.write(books, to: libraryFile)
        }
        state.owner = account.email
        accountGeneration += 1
        saveOutbox()
        blockedOnSignIn = false
        broadcaster.emit(.signedIn(account))
        scheduleFlush(after: 0)
        return account
    }

    public func signOut() async {
        timer?.cancel()
        timer = nil
        await session.signOut()
        accountGeneration += 1
        state = OutboxState()
        books = []
        saveOutbox()
        JSONFile.write(books, to: libraryFile)
        broadcaster.emit(.signedOut)
        broadcaster.emit(.library([]))
        broadcaster.emit(.outbox(pending: 0))
    }

    // MARK: Library

    func setPageSize(_ size: Int) { pageSize = max(1, size) }

    public func cachedLibrary() -> [CloudBook] { books }

    public func library() async throws -> [CloudBook] {
        var fetched: [CloudBook] = []
        var total = Int.max
        while fetched.count < total {
            let (data, _) = try await session.send(.get("/books", query: ["limit": String(pageSize), "offset": String(fetched.count)]))
            let page = try WireDecoder.booksPage(data)
            total = page.total
            fetched += page.items
            if page.items.isEmpty { break }
        }
        fetched = fetched.map(markOwnPosition)
        announceDifferences(from: books, to: fetched)
        books = fetched
        JSONFile.write(books, to: libraryFile)
        if !state.items.isEmpty { scheduleFlush(after: 0) }
        return fetched
    }

    private func announceDifferences(from old: [CloudBook], to new: [CloudBook]) {
        let before = Dictionary(old.map { ($0.fastHash, $0) }, uniquingKeysWith: { a, _ in a })
        let after = Set(new.map(\.fastHash))
        for book in new {
            guard let previous = before[book.fastHash] else {
                broadcaster.emit(.bookAdded(book))
                continue
            }
            if Self.visibleFields(previous) != Self.visibleFields(book) { broadcaster.emit(.bookUpdated(book)) }
            if let remote = book.position, remote.source != .gatefold,
               previous.position.map({ remote.updated > $0.updated }) ?? true {
                broadcaster.emit(.remotePosition(fastHash: book.fastHash, remote))
            }
        }
        for hash in before.keys where !after.contains(hash) { broadcaster.emit(.bookRemoved(fastHash: hash)) }
        broadcaster.emit(.library(new))
    }

    /// Signed URLs change on every fetch, so they don't count as an update.
    private static func visibleFields(_ b: CloudBook) -> [String] {
        [b.name, b.title, b.authors ?? "", String(b.bytes), b.md5Base64 ?? "", b.readStatus ?? "", String(b.readPercent ?? -1),
         String(b.favorite), b.position.map { "\($0.pointer ?? "")@\($0.updated.timeIntervalSince1970)" } ?? ""]
    }

    private func markOwnPosition(_ book: CloudBook) -> CloudBook {
        var book = book
        if let p = book.position { book.position = markOwn(p, fastHash: book.fastHash) }
        return book
    }

    private func markOwn(_ position: ReadingPosition, fastHash: String) -> ReadingPosition {
        var p = position
        if let pushed = state.pushedPointers[fastHash], pushed == p.pointer { p.source = .gatefold }
        return p
    }

    // MARK: Files

    public func download(_ book: CloudBook) async throws -> URL {
        let ext = (book.format?.lowercased()).flatMap { $0.isEmpty ? nil : $0 } ?? URL(fileURLWithPath: book.name).pathExtension.lowercased()
        let destination = booksDirectory.appendingPathComponent("\(book.fastHash).\(ext.isEmpty ? "epub" : ext)")
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            if try await Self.matches(destination, md5: book.md5Base64) { return destination }
            try? fm.removeItem(at: destination)
        }

        var link = book.downloadURL
        var refetched = false
        if link == nil {
            link = try await freshDownloadLink(for: book)
            refetched = true
        }
        while true {
            guard let url = link else { throw CloudError.unexpectedResponse("no download link") }
            let partial = partialDirectory.appendingPathComponent(UUID().uuidString)
            let response: HTTPURLResponse
            do {
                response = try await transport.download(URLRequest(url: url), to: partial)
            } catch {
                try? fm.removeItem(at: partial)
                throw CloudSession.mapTransportError(error)
            }
            if [401, 403, 404, 410].contains(response.statusCode), !refetched {
                try? fm.removeItem(at: partial)
                link = try await freshDownloadLink(for: book)
                refetched = true
                continue
            }
            do {
                try CloudSession.check(response, Data())
                if let expected = book.md5Base64, try await Self.md5OffActor(partial) != expected { throw CloudError.checksumMismatch }
                try fm.moveItem(at: partial, to: destination)
            } catch {
                try? fm.removeItem(at: partial)
                // Another download of the same book may have finished first.
                if fm.fileExists(atPath: destination.path), (try? await Self.matches(destination, md5: book.md5Base64)) == true { return destination }
                throw error
            }
            return destination
        }
    }

    private func freshDownloadLink(for book: CloudBook) async throws -> URL? {
        let (data, _) = try await session.send(.get("/fileops/info/", query: ["fast_hash": book.fastHash]))
        return try WireDecoder.fileInfo(data).book.downloadURL
    }

    public func upload(fileAt url: URL) async throws -> CloudBook {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard Int64(data.count) >= Self.minimumUploadBytes else { throw CloudError.fileTooSmall(bytes: Int64(data.count)) }
        let md5 = Data(Insecure.MD5.hash(data: data)).base64EncodedString()
        if let existing = try await library().first(where: { $0.md5Base64 == md5 }) { return existing }

        let name = url.lastPathComponent
        let type = switch url.pathExtension.lowercased() {
        case "epub": "application/epub+zip"
        case "pdf": "application/pdf"
        default: "application/octet-stream"
        }
        let (body, _) = try await session.send(Endpoint(method: "PUT", path: "/files/\(Endpoint.pathSegment(name))",
                                                        body: .raw(data, contentType: type), version: .v1_1))
        let uploaded = try WireDecoder.uploadResponse(body)
        // The Cloud indexes a new file for a few seconds (live: /books after ~3 s, fileops/info after ~5 s)
        // and answers 404 for it until then. Return once other calls can use it.
        for wait in [1, 1, 2, 2, 3, 4, 5, 6] {
            try await sleep(.seconds(wait))
            do {
                try await session.send(.get("/fileops/info/", query: ["fast_hash": uploaded.fastHash]))
                break
            } catch CloudError.notFound {
                continue
            }
        }
        let refreshed = try? await library()
        return refreshed?.first(where: { $0.fastHash == uploaded.fastHash }) ?? uploaded
    }

    public func delete(_ book: CloudBook) async throws {
        for _ in 0..<2 {
            try await session.send(Endpoint(method: "POST", path: "/fileops/delete/", query: ["fast_hash": book.fastHash],
                                            body: .emptyForm, version: .v1_1))
            do {
                try await session.send(.get("/fileops/info/", query: ["fast_hash": book.fastHash]))
            } catch CloudError.notFound {
                forget(book.fastHash)
                return
            }
        }
        throw CloudError.deleteNotApplied
    }

    private func forget(_ fastHash: String) {
        let fm = FileManager.default
        for file in (try? fm.contentsOfDirectory(at: booksDirectory, includingPropertiesForKeys: nil)) ?? []
        where file.deletingPathExtension().lastPathComponent == fastHash {
            try? fm.removeItem(at: file)
        }
        books.removeAll { $0.fastHash == fastHash }
        state.items.removeAll { $0.fastHash == fastHash }
        state.pushedPointers[fastHash] = nil
        state.createdUUIDs = state.createdUUIDs.filter { !$0.key.hasPrefix("\(fastHash)|") }
        JSONFile.write(books, to: libraryFile)
        saveOutbox()
        broadcaster.emit(.bookRemoved(fastHash: fastHash))
        broadcaster.emit(.outbox(pending: state.items.count))
    }

    /// True when `file` has the expected md5, or when the Cloud gave none to check against.
    static func matches(_ file: URL, md5: String?) async throws -> Bool {
        guard let md5 else { return true }
        return try await md5OffActor(file) == md5
    }

    /// Hashes off the actor so a large book does not stall the outbox.
    static func md5OffActor(_ file: URL) async throws -> String {
        try await Task.detached(priority: .utility) { try md5Base64(of: file) }.value
    }

    static func md5Base64(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var md5 = Insecure.MD5()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { md5.update(data: chunk) }
        return Data(md5.finalize()).base64EncodedString()
    }

    // MARK: Positions

    public func remotePosition(for book: CloudBook) async throws -> ReadingPosition? {
        let (data, _) = try await session.send(.get("/fileops/info/", query: ["fast_hash": book.fastHash]))
        return try WireDecoder.fileInfo(data).position.map { markOwn($0, fastHash: book.fastHash) }
    }

    public func push(_ position: ReadingPosition, for book: CloudBook) async {
        var p = position
        p.source = .gatefold
        enqueue(OutboxItem(fastHash: book.fastHash, operation: .position(p)))
    }

    // MARK: Annotations

    public func annotations(for book: CloudBook) async throws -> [CloudAnnotation] {
        var list = try await serverAnnotations(fastHash: book.fastHash)
        for item in state.items where item.fastHash == book.fastHash {
            switch item.operation {
            case let .updateAnnotation(local):
                if let i = list.firstIndex(where: { $0.uuid == local.uuid }) { list[i] = list[i].merged(with: local) }
            case let .deleteAnnotation(uuid):
                list.removeAll { $0.uuid == uuid }
            case let .createAnnotation(local):
                if !list.contains(where: { $0.dedupeKey == local.dedupeKey }) { list.append(local) }
            case .position:
                break
            }
        }
        broadcaster.emit(.annotations(fastHash: book.fastHash, list))
        return list
    }

    private func serverAnnotations(fastHash: String) async throws -> [CloudAnnotation] {
        let (data, _) = try await session.send(.get("/notes", query: ["fast_hash": fastHash]))
        var list: [CloudAnnotation] = []
        for summary in try WireDecoder.annotationList(data) {
            let (detail, _) = try await session.send(.get("/notes/\(Endpoint.pathSegment(summary.uuid))", query: ["fast_hash": fastHash]))
            if var a = try? WireDecoder.annotation(detail) {
                if a.uuid == nil { a.uuid = summary.uuid }
                list.append(a)
            }
        }
        return list
    }

    public func save(_ annotation: CloudAnnotation, for book: CloudBook) async {
        var stamped = stampMissing(annotation, at: now())
        if stamped.uuid == nil { stamped.uuid = state.createdUUIDs[OutboxState.annotationKey(book.fastHash, stamped)] }
        enqueue(OutboxItem(fastHash: book.fastHash, operation: stamped.uuid == nil ? .createAnnotation(stamped) : .updateAnnotation(stamped)))
    }

    public func deleteAnnotation(_ annotation: CloudAnnotation, for book: CloudBook) async {
        guard let uuid = annotation.uuid ?? state.createdUUIDs[OutboxState.annotationKey(book.fastHash, annotation)] else {
            // Never reached the server, or is on its way there right now.
            let key = "create|\(book.fastHash)|\(annotation.dedupeKey)"
            if let i = state.items.firstIndex(where: { $0.coalescingKey == key }) {
                if state.items[i].id == inFlight || state.items[i].sendStarted {
                    state.items[i].deleteAfterCreate = true
                    state.items[i].notBefore = nil
                } else {
                    state.items.remove(at: i)
                }
            }
            saveOutbox()
            broadcaster.emit(.outbox(pending: state.items.count))
            return
        }
        state.forgetCreated(uuid: uuid)
        enqueue(OutboxItem(fastHash: book.fastHash, operation: .deleteAnnotation(uuid: uuid)))
    }

    /// Gives every field a timestamp so the Cloud's per-field merge applies to it.
    private func stampMissing(_ a: CloudAnnotation, at date: Date) -> CloudAnnotation {
        var a = a
        if a.kind.updated == nil { a.kind.updated = date }
        if a.color != nil, a.color?.updated == nil { a.color?.updated = date }
        if a.note != nil, a.note?.updated == nil { a.note?.updated = date }
        if a.mark != nil, a.mark?.updated == nil { a.mark?.updated = date }
        if a.quotation != nil, a.quotation?.updated == nil { a.quotation?.updated = date }
        return a
    }

    /// The Cloud keeps a future `updated` and then ignores every older edit of that field,
    /// so nothing we send may be later than the server's now.
    private func clampToServerNow(_ a: CloudAnnotation) async -> CloudAnnotation {
        let limit = await session.serverNow()
        func clamp<T>(_ s: Stamped<T>?) -> Stamped<T>? {
            guard var s else { return nil }
            if let u = s.updated, u > limit { s.updated = limit }
            return s
        }
        var a = a
        a.kind = clamp(a.kind) ?? a.kind
        a.color = clamp(a.color)
        a.note = clamp(a.note)
        a.mark = clamp(a.mark)
        a.quotation = clamp(a.quotation)
        return a
    }

    // MARK: Outbox

    public func pendingChanges() -> Int { state.items.count }

    private func enqueue(_ item: OutboxItem) {
        state.enqueue(item)
        saveOutbox()
        broadcaster.emit(.outbox(pending: state.items.count))
        scheduleFlush(after: configuration.debounce)
    }

    private func saveOutbox() { JSONFile.write(state, to: outboxFile) }

    public func flushOutbox() async {
        if let draining {
            await draining.value
            return
        }
        let task = Task { await self.drain() }
        draining = task
        await task.value
        draining = nil
        rescheduleAfterDrain()
    }

    private enum Outcome {
        /// Sent. A newer payload that arrived meanwhile still goes out.
        case done
        /// Nothing left to send for this item, whatever arrived meanwhile.
        case finished
        /// The send succeeded but turned the item into another one (a create into an update).
        case replace(OutboxItem.Operation)
    }

    private func drain() async {
        var index = 0
        while index < state.items.count {
            let item = state.items[index]
            if let due = item.notBefore, due > now() {
                index += 1
                continue
            }
            let generation = accountGeneration
            inFlight = item.id
            defer { inFlight = nil }
            do {
                let outcome = try await send(item)
                guard generation == accountGeneration else { return }
                guard let i = state.items.firstIndex(where: { $0.id == item.id }) else { continue }
                switch outcome {
                case .finished:
                    state.items.remove(at: i)
                case .done:
                    if state.items[i].revision == item.revision {
                        state.items.remove(at: i)
                    } else {
                        state.items[i].notBefore = nil // a newer write arrived meanwhile: send it now
                        index = i
                    }
                case let .replace(operation):
                    state.items[i].operation = operation
                    state.items[i].attempts = 0
                    state.items[i].notBefore = nil
                }
                blockedOnSignIn = false
            } catch {
                guard generation == accountGeneration else { return }
                guard let i = state.items.firstIndex(where: { $0.id == item.id }) else { continue }
                let newerArrived = state.items[i].revision != item.revision
                switch Self.disposition(of: error) {
                case .drop where newerArrived:
                    // The rejection was for the older payload; give the newer one its own chance.
                    state.items[i].attempts = 0
                    state.items[i].notBefore = nil
                    index = i
                case .drop:
                    state.items.remove(at: i)
                case .retry(let retryAfter):
                    state.items[i].attempts += 1
                    if state.items[i].attempts >= Self.maxAttempts, !(error as? CloudError).map(\.isTransient).orFalse, !newerArrived {
                        state.items.remove(at: i)
                        break
                    }
                    state.items[i].notBefore = now().addingTimeInterval(max(retryAfter ?? 0, backoff(attempt: state.items[i].attempts)))
                    if (error as? CloudError) == .offline {
                        saveOutbox()
                        broadcaster.emit(.outbox(pending: state.items.count))
                        return // everything else would fail the same way
                    }
                    index = i + 1
                case .signIn:
                    blockedOnSignIn = true
                    saveOutbox()
                    broadcaster.emit(.authenticationRequired)
                    broadcaster.emit(.outbox(pending: state.items.count))
                    return
                }
            }
            saveOutbox()
            broadcaster.emit(.outbox(pending: state.items.count))
        }
    }

    private enum Disposition { case drop, retry(TimeInterval?), signIn }

    private static func disposition(of error: Error) -> Disposition {
        guard let error = error as? CloudError else { return .retry(nil) }
        switch error {
        case .notFound: return .drop // the book or note is gone
        case .authenticationRequired, .notSignedIn: return .signIn
        case let .rateLimited(retryAfter): return .retry(retryAfter)
        case let .http(status, _) where (400..<500).contains(status) && status != 408: return .drop
        default: return .retry(nil)
        }
    }

    private func backoff(attempt: Int) -> TimeInterval {
        min(600, 2 * pow(2, Double(max(0, attempt - 1)))) * jitter()
    }

    private func send(_ item: OutboxItem) async throws -> Outcome {
        switch item.operation {
        case let .position(position):
            return try await sendPosition(position, fastHash: item.fastHash)
        case let .createAnnotation(annotation):
            return try await sendCreate(annotation, item: item)
        case let .updateAnnotation(annotation):
            guard let uuid = annotation.uuid else { return .done }
            await session.syncClock()
            let body = await clampToServerNow(annotation)
            do {
                try await session.send(Endpoint(method: "POST", path: "/notes/\(Endpoint.pathSegment(uuid))", query: ["fast_hash": item.fastHash],
                                                body: .json(WireEncoder.annotationBody(body))))
            } catch CloudError.notFound where state.createdUUIDs.values.contains(uuid) {
                // We filled in this uuid from memory, and the note has since been deleted elsewhere:
                // the user's save is a new highlight, so create it.
                state.forgetCreated(uuid: uuid)
                var fresh = annotation
                fresh.uuid = nil
                return .replace(.createAnnotation(fresh))
            }
            return .done
        case let .deleteAnnotation(uuid):
            try await session.send(Endpoint(method: "DELETE", path: "/notes/\(Endpoint.pathSegment(uuid))", query: ["fast_hash": item.fastHash]))
            return .done
        }
    }

    /// A create is not idempotent on the server, so once one may have been sent, look for it before
    /// sending again. Remembers the server uuid so later edits and deletes of the app's copy find it.
    private func sendCreate(_ annotation: CloudAnnotation, item: OutboxItem) async throws -> Outcome {
        let key = OutboxState.annotationKey(item.fastHash, annotation)
        var uuid: String?
        if item.sendStarted || item.attempts > 0 {
            uuid = try await serverAnnotations(fastHash: item.fastHash).first(where: { $0.dedupeKey == annotation.dedupeKey })?.uuid
        }
        let foundExisting = uuid != nil
        if uuid == nil {
            if item.deleteAfterCreate { return .finished } // never reached the server
            await session.syncClock()
            let body = await clampToServerNow(annotation)
            if let i = state.items.firstIndex(where: { $0.id == item.id }) {
                state.items[i].sendStarted = true
                saveOutbox()
            }
            let (data, _) = try await session.send(Endpoint(method: "POST", path: "/notes", query: ["fast_hash": item.fastHash],
                                                            body: .json(WireEncoder.annotationBody(body))))
            guard let created = try WireDecoder.loose(data)["uuid"]?.string else { throw CloudError.unexpectedResponse("note uuid") }
            uuid = created
        }
        guard let uuid else { return .done }
        state.createdUUIDs[key] = uuid
        let current = state.items.first(where: { $0.id == item.id })
        if current?.deleteAfterCreate == true {
            try await session.send(Endpoint(method: "DELETE", path: "/notes/\(Endpoint.pathSegment(uuid))", query: ["fast_hash": item.fastHash]))
            return .finished
        }
        var latest = annotation
        if let current, case let .createAnnotation(newer) = current.operation { latest = newer }
        latest.uuid = uuid
        broadcaster.emit(.annotationSaved(fastHash: item.fastHash, latest))
        // A replayed create found on the server, or edits made while it was in flight, go out as an update.
        if foundExisting || current.map({ $0.revision != item.revision }) == true {
            return .replace(.updateAnnotation(latest))
        }
        return .finished
    }

    /// The Cloud stamps a position with its arrival time and keeps the last one to arrive, so a
    /// queued write must not overwrite a newer one from another device. Read first, then write.
    private func sendPosition(_ position: ReadingPosition, fastHash: String) async throws -> Outcome {
        let (data, _) = try await session.send(.get("/fileops/info/", query: ["fast_hash": fastHash]))
        if let remote = try WireDecoder.fileInfo(data).position.map({ markOwn($0, fastHash: fastHash) }), remote.source != .gatefold {
            let ours = await session.serverTime(position.updated)
            if remote.updated > ours {
                updateCachedPosition(remote, fastHash: fastHash)
                broadcaster.emit(.positionSuperseded(fastHash: fastHash, remote: remote))
                return .done
            }
        }
        let body = try WireEncoder.positionBody(position, pointerStyle: configuration.pointerStyle)
        try await session.send(Endpoint(method: "POST", path: "/books/read-position", query: ["fast_hash": fastHash], body: .json(body)))
        if let cfi = position.parsedCFI {
            state.pushedPointers[fastHash] = PocketBookAnchor.string(for: cfi, style: configuration.pointerStyle)
        }
        updateCachedPosition(position, fastHash: fastHash)
        return .done
    }

    private func updateCachedPosition(_ position: ReadingPosition, fastHash: String) {
        guard let i = books.firstIndex(where: { $0.fastHash == fastHash }) else { return }
        books[i].position = position
        JSONFile.write(books, to: libraryFile)
    }

    // MARK: Scheduling

    private func scheduleFlush(after delay: TimeInterval) {
        guard configuration.autoFlush, !blockedOnSignIn else { return }
        let due = now().addingTimeInterval(delay)
        if let timerDue, timerDue <= due, timer != nil { return }
        timer?.cancel()
        timerDue = due
        timer = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            await self?.timerFired()
        }
    }

    private func timerFired() async {
        timer = nil
        timerDue = nil
        await flushOutbox()
    }

    private func rescheduleAfterDrain() {
        guard let next = state.items.map({ $0.notBefore ?? now() }).min() else { return }
        scheduleFlush(after: max(1, next.timeIntervalSince(now())))
    }
}

private extension Optional where Wrapped == Bool {
    var orFalse: Bool { self ?? false }
}
