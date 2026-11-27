import Foundation

/// What the app talks to. `PocketBookCloud` is the real one; the app can swap in a fake.
///
/// Writes (`push`, `save`, `deleteAnnotation`) never throw: they go to a durable outbox and
/// reach the Cloud when it is reachable. Watch `changes()` for what happened.
public protocol SyncService: Sendable {
    // Accounts
    /// The bookstores (sign-in providers) that hold an account for this email.
    func stores(forEmail email: String) async throws -> [CloudStore]
    func signIn(email: String, password: String, store: CloudStore) async throws -> CloudAccount
    func signOut() async
    var account: CloudAccount? { get async }

    // Library
    /// The last library seen, from disk. Instant; may be stale.
    func cachedLibrary() async -> [CloudBook]
    /// Fetches the whole library and announces what changed since the last fetch.
    func library() async throws -> [CloudBook]
    /// A verified local copy in the app container.
    func download(_ book: CloudBook) async throws -> URL
    /// As `download(_:)`, telling `progress` how far it has got where the transfer can say.
    func download(_ book: CloudBook, progress: DownloadProgress?) async throws -> URL
    func upload(fileAt url: URL) async throws -> CloudBook
    func delete(_ book: CloudBook) async throws

    // Reading position
    func remotePosition(for book: CloudBook) async throws -> ReadingPosition?
    func push(_ position: ReadingPosition, for book: CloudBook) async
    /// Marks the book finished in the Cloud (`read_status` "read"). Queued like any write.
    func markRead(_ book: CloudBook) async

    // Annotations
    /// Server copies with any queued local edits applied on top.
    func annotations(for book: CloudBook) async throws -> [CloudAnnotation]
    func save(_ annotation: CloudAnnotation, for book: CloudBook) async
    func deleteAnnotation(_ annotation: CloudAnnotation, for book: CloudBook) async

    // Outbox
    func pendingChanges() async -> Int
    /// Sends whatever is due now. The real service also does this by itself.
    func flushOutbox() async
    /// Sends whatever is due now; `trigger` says why, in the place reports (telemetry).
    func flushOutbox(trigger: PlaceReport.Trigger) async
    /// How the latest try to sign in again went (telemetry); nil before any.
    func reSignIn() async -> ReSignInNote?

    func changes() -> AsyncStream<CloudChange>
}

public extension SyncService {
    func flushOutbox(trigger: PlaceReport.Trigger) async { await flushOutbox() }
    func reSignIn() async -> ReSignInNote? { nil }
}

/// Fans each change out to every live subscriber.
final class ChangeBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<CloudChange>.Continuation] = [:]

    func stream() -> AsyncStream<CloudChange> {
        let (stream, continuation) = AsyncStream.makeStream(of: CloudChange.self, bufferingPolicy: .bufferingNewest(256))
        let id = UUID()
        lock.withLock { continuations[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            _ = self.lock.withLock { self.continuations.removeValue(forKey: id) }
        }
        return stream
    }

    func emit(_ change: CloudChange) {
        for continuation in lock.withLock({ Array(continuations.values) }) { continuation.yield(change) }
    }
}

extension SyncService {
    /// A service that can't tell how far a download has got says nothing until it is done.
    public func download(_ book: CloudBook, progress: DownloadProgress?) async throws -> URL {
        try await download(book)
    }
}
