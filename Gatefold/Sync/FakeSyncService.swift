import Foundation
import os

/// An in-memory PocketBook Cloud, seeded with public-domain books from Project Gutenberg that ship
/// in the app bundle. It drives previews, tests and the prototype; `PocketBookCloud` is the real one.
/// Any email signs in; the password `wrong` fails; an email without `@` has no account.
public actor FakeSyncService: SyncService {
    public struct Seed: Sendable {
        public var resource: String
        public var title: String
        public var authors: [String]
        /// Where "the InkPad" left off, if it has read this book.
        public var remoteProgression: Double?
        public var remoteAge: TimeInterval
    }

    public static let seeds: [Seed] = [
        Seed(resource: "moby-dick", title: "Moby-Dick", authors: ["Herman Melville"], remoteProgression: 0.42, remoteAge: 2 * 3600),
        Seed(resource: "pride-and-prejudice", title: "Pride and Prejudice", authors: ["Jane Austen"], remoteProgression: 0.18, remoteAge: 26 * 3600),
        Seed(resource: "frankenstein", title: "Frankenstein", authors: ["Mary Wollstonecraft Shelley"], remoteProgression: 0.66, remoteAge: 5 * 86400),
        Seed(resource: "the-great-gatsby", title: "The Great Gatsby", authors: ["F. Scott Fitzgerald"], remoteProgression: nil, remoteAge: 0),
        Seed(resource: "alice-in-wonderland", title: "Alice’s Adventures in Wonderland", authors: ["Lewis Carroll"], remoteProgression: nil, remoteAge: 0),
        Seed(resource: "dracula", title: "Dracula", authors: ["Bram Stoker"], remoteProgression: 0.07, remoteAge: 9 * 86400),
        Seed(resource: "sherlock-holmes", title: "The Adventures of Sherlock Holmes", authors: ["Arthur Conan Doyle"], remoteProgression: nil, remoteAge: 0),
        Seed(resource: "emma", title: "Emma", authors: ["Jane Austen"], remoteProgression: nil, remoteAge: 0),
    ]

    public static let stores = [
        CloudStore(alias: "pbookde", name: "PocketBook.de", shopID: "1", iconURL: nil, loggedBy: nil),
        CloudStore(alias: "pbookint", name: "PocketBook International", shopID: "2", iconURL: nil, loggedBy: nil),
    ]

    private var signedIn: CloudAccount?
    private var positions: [String: ReadingPosition] = [:]
    private var annotationsByBook: [String: [CloudAnnotation]] = [:]
    /// How many times the whole library was fetched (tests watch for refresh loops).
    public private(set) var libraryFetches = 0
    /// Subscribers register synchronously, so no change sent after `changes()` returns is missed.
    private let subscribers = OSAllocatedUnfairLock<[UUID: AsyncStream<CloudChange>.Continuation]>(initialState: [:])
    private let latency: Duration
    private let bundle: Bundle
    private let now: @Sendable () -> Date

    public init(signedIn: Bool = false, latency: Duration = .milliseconds(450), bundle: Bundle = .main, now: @escaping @Sendable () -> Date = { Date() }) {
        self.latency = latency
        self.bundle = bundle
        self.now = now
        if signedIn {
            self.signedIn = CloudAccount(email: "reader@example.com", store: Self.stores[0])
        }
        let t = now()
        for seed in Self.seeds {
            if let p = seed.remoteProgression {
                positions[Self.id(for: seed)] = ReadingPosition(cfi: nil, progression: 0, totalProgression: p, updated: t.addingTimeInterval(-seed.remoteAge), source: .pocketBookNative)
            }
        }
    }

    public static func id(for seed: Seed) -> String { "gutenberg-\(seed.resource)" }

    public var account: CloudAccount? { signedIn }

    public func stores(forEmail email: String) async throws -> [CloudStore] {
        try await pause()
        guard email.contains("@") else { throw CloudError.noAccount }
        return Self.stores
    }

    public func signIn(email: String, password: String, store: CloudStore) async throws -> CloudAccount {
        try await pause()
        guard email.contains("@") else { throw CloudError.noAccount }
        guard password != "wrong", !password.isEmpty else { throw CloudError.invalidCredentials }
        let account = CloudAccount(email: email, store: store)
        signedIn = account
        broadcast(.signedIn(account))
        return account
    }

    public func signOut() async {
        signedIn = nil
        broadcast(.signedOut)
    }

    public func cachedLibrary() async -> [CloudBook] {
        signedIn == nil ? [] : books()
    }

    public func library() async throws -> [CloudBook] {
        guard signedIn != nil else { return [] }
        try await pause()
        libraryFetches += 1
        let all = books()
        // Like PocketBookCloud: every fetch announces the library it found.
        broadcast(.library(all))
        return all
    }

    private func books() -> [CloudBook] {
        Self.seeds.map { seed in
            let id = Self.id(for: seed)
            let position = positions[id]
            return CloudBook(
                fastHash: id,
                cloudID: id,
                path: "/Books/\(seed.resource).epub",
                name: "\(seed.resource).epub",
                title: seed.title,
                authors: seed.authors.joined(separator: ", "),
                format: "epub",
                mimeType: "application/epub+zip",
                bytes: Int64((try? bundleURL(seed.resource).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0),
                modifiedAt: position?.updated,
                readPercent: position.map { Int(($0.totalProgression * 100).rounded()) },
                coverURL: bundle.url(forResource: seed.resource, withExtension: "jpg"),
                position: position
            )
        }
    }

    public func upload(fileAt url: URL) async throws -> CloudBook {
        try await pause()
        return CloudBook(fastHash: "upload-\(url.lastPathComponent)", name: url.lastPathComponent, title: url.deletingPathExtension().lastPathComponent)
    }

    public func delete(_ book: CloudBook) async throws {
        try await pause()
        broadcast(.bookRemoved(fastHash: book.fastHash))
    }

    public func download(_ book: CloudBook) async throws -> URL {
        guard let seed = Self.seeds.first(where: { Self.id(for: $0) == book.id }) else { throw CloudError.notFound }
        try await Task.sleep(for: latency * 3)
        let source = try bundleURL(seed.resource)
        let dir = FileManager.default.temporaryDirectory.appending(path: "fake-cloud", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appending(path: "\(book.id).epub")
        if !FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.copyItem(at: source, to: target)
        }
        return target
    }

    public func remotePosition(for book: CloudBook) async throws -> ReadingPosition? {
        try await pause()
        return positions[book.id]
    }

    public func push(_ position: ReadingPosition, for book: CloudBook) async {
        positions[book.id] = position
    }

    public func annotations(for book: CloudBook) async throws -> [CloudAnnotation] {
        annotationsByBook[book.id] ?? []
    }

    public func save(_ annotation: CloudAnnotation, for book: CloudBook) async {
        var list = annotationsByBook[book.id] ?? []
        list.removeAll { $0.id == annotation.id }
        list.append(annotation)
        annotationsByBook[book.id] = list
    }

    public func deleteAnnotation(_ annotation: CloudAnnotation, for book: CloudBook) async {
        annotationsByBook[book.id]?.removeAll { $0.id == annotation.id }
    }

    public func pendingChanges() async -> Int { 0 }

    public func flushOutbox() async {}

    public nonisolated func changes() -> AsyncStream<CloudChange> {
        let (stream, continuation) = AsyncStream<CloudChange>.makeStream()
        let key = UUID()
        subscribers.withLock { $0[key] = continuation }
        continuation.onTermination = { [subscribers] _ in subscribers.withLock { $0[key] = nil } }
        return stream
    }

    /// Test hook: another device moved the place.
    public func simulateRemoteRead(bookID: String, totalProgression: Double, source: PositionSource = .pocketBookNative) {
        let p = ReadingPosition(cfi: nil, progression: 0, totalProgression: totalProgression, updated: now(), source: source)
        positions[bookID] = p
        broadcast(.remotePosition(fastHash: bookID, p))
    }

    private func broadcast(_ change: CloudChange) {
        subscribers.withLock { $0.values.forEach { $0.yield(change) } }
    }

    private func pause() async throws {
        if latency > .zero { try await Task.sleep(for: latency) }
    }

    private func bundleURL(_ resource: String) throws -> URL {
        guard let url = bundle.url(forResource: resource, withExtension: "epub") else { throw CloudError.notFound }
        return url
    }
}
