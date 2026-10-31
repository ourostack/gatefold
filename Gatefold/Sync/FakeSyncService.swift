import Foundation
import os

/// An in-memory PocketBook Cloud, seeded with public-domain books from Project Gutenberg that ship
/// in the app bundle. It drives previews, tests and the prototype until stream A's real service
/// lands. Any email signs in; the password `wrong` fails; an email without `@` has no account.
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
        CloudStore(alias: "pbookde", name: "PocketBook.de", shopID: "1"),
        CloudStore(alias: "pbookint", name: "PocketBook International", shopID: "2"),
    ]

    private var signedIn: CloudAccount?
    private var positions: [String: ReadingPosition] = [:]
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
                positions[Self.id(for: seed)] = ReadingPosition(cfi: nil, progression: 0, totalProgression: p, updated: t.addingTimeInterval(-seed.remoteAge), device: "PocketBook InkPad 4")
            }
        }
    }

    public static func id(for seed: Seed) -> String { "gutenberg-\(seed.resource)" }

    public var account: CloudAccount? { signedIn }

    public func stores(forEmail email: String) async throws -> [CloudStore] {
        try await pause()
        guard email.contains("@") else { throw SyncError.noAccount }
        return Self.stores
    }

    public func signIn(email: String, password: String, store: CloudStore) async throws -> CloudAccount {
        try await pause()
        guard email.contains("@") else { throw SyncError.noAccount }
        guard password != "wrong", !password.isEmpty else { throw SyncError.wrongPassword }
        let account = CloudAccount(email: email, store: store)
        signedIn = account
        broadcast(.library)
        return account
    }

    public func signOut() async {
        signedIn = nil
        broadcast(.library)
    }

    public func library() async throws -> [CloudBook] {
        guard signedIn != nil else { return [] }
        try await pause()
        return Self.seeds.map { seed in
            CloudBook(
                id: Self.id(for: seed),
                title: seed.title,
                authors: seed.authors,
                fileName: "\(seed.resource).epub",
                byteCount: (try? bundleURL(seed.resource).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil,
                coverURL: bundle.url(forResource: seed.resource, withExtension: "jpg"),
                readProgression: positions[Self.id(for: seed)]?.totalProgression,
                updated: positions[Self.id(for: seed)]?.updated
            )
        }
    }

    public func download(_ book: CloudBook) async throws -> URL {
        guard let seed = Self.seeds.first(where: { Self.id(for: $0) == book.id }) else { throw SyncError.notFound }
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

    public nonisolated func changes() -> AsyncStream<CloudChange> {
        let (stream, continuation) = AsyncStream<CloudChange>.makeStream()
        let key = UUID()
        subscribers.withLock { $0[key] = continuation }
        continuation.onTermination = { [subscribers] _ in subscribers.withLock { $0[key] = nil } }
        return stream
    }

    /// Test hook: another device moved the place.
    public func simulateRemoteRead(bookID: String, totalProgression: Double, device: String = "PocketBook InkPad 4") {
        let p = ReadingPosition(cfi: nil, progression: 0, totalProgression: totalProgression, updated: now(), device: device)
        positions[bookID] = p
        broadcast(.position(bookID: bookID, p))
    }

    private func broadcast(_ change: CloudChange) {
        subscribers.withLock { $0.values.forEach { $0.yield(change) } }
    }

    private func pause() async throws {
        if latency > .zero { try await Task.sleep(for: latency) }
    }

    private func bundleURL(_ resource: String) throws -> URL {
        guard let url = bundle.url(forResource: resource, withExtension: "epub") else { throw SyncError.notFound }
        return url
    }
}
