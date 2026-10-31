import Foundation

// The seam between the app and PocketBook Cloud, exactly as planning.md defines it. Stream A's
// `GatefoldCloud` package implements it for real; the app codes only against this protocol, so
// integration swaps `FakeSyncService` for the real service.

public protocol SyncService: Sendable {
    func signIn(email: String, password: String, store: CloudStore) async throws -> CloudAccount
    func stores(forEmail: String) async throws -> [CloudStore]
    func signOut() async
    var account: CloudAccount? { get async }
    func library() async throws -> [CloudBook]          // cached + refreshed
    func download(_ book: CloudBook) async throws -> URL // local file URL
    func remotePosition(for book: CloudBook) async throws -> ReadingPosition?
    func push(_ position: ReadingPosition, for book: CloudBook) async  // outboxed, never throws to UI
    func changes() -> AsyncStream<CloudChange>           // library/position updates
}

public struct ReadingPosition: Sendable, Codable, Equatable {
    public var cfi: String?; public var progression: Double; public var totalProgression: Double
    public var updated: Date; public var device: String

    public init(cfi: String?, progression: Double, totalProgression: Double, updated: Date, device: String) {
        self.cfi = cfi
        self.progression = progression
        self.totalProgression = totalProgression
        self.updated = updated
        self.device = device
    }
}

/// A PocketBook store ("provider") the account belongs to.
public struct CloudStore: Sendable, Codable, Equatable, Hashable, Identifiable {
    public var alias: String
    public var name: String
    public var shopID: String
    public var id: String { alias }

    public init(alias: String, name: String, shopID: String) {
        self.alias = alias
        self.name = name
        self.shopID = shopID
    }
}

public struct CloudAccount: Sendable, Codable, Equatable {
    public var email: String
    public var store: CloudStore

    public init(email: String, store: CloudStore) {
        self.email = email
        self.store = store
    }
}

public struct CloudBook: Sendable, Codable, Equatable, Hashable, Identifiable {
    /// The Cloud's `fast_hash`, stable across devices.
    public var id: String
    public var title: String
    public var authors: [String]
    public var fileName: String
    public var byteCount: Int?
    public var coverURL: URL?
    /// The Cloud's own percent read, 0...1, when it reports one.
    public var readProgression: Double?
    public var updated: Date?

    public init(id: String, title: String, authors: [String], fileName: String, byteCount: Int? = nil, coverURL: URL? = nil, readProgression: Double? = nil, updated: Date? = nil) {
        self.id = id
        self.title = title
        self.authors = authors
        self.fileName = fileName
        self.byteCount = byteCount
        self.coverURL = coverURL
        self.readProgression = readProgression
        self.updated = updated
    }
}

public enum CloudChange: Sendable, Equatable {
    case library
    case position(bookID: String, ReadingPosition)
}

public enum SyncError: Error, Equatable, LocalizedError {
    case noAccount
    case wrongPassword
    case offline
    case notFound

    public var errorDescription: String? {
        switch self {
        case .noAccount: "There's no PocketBook Cloud account with that email."
        case .wrongPassword: "That password didn't work. Check it and try again."
        case .offline: "You're offline. Your books and place are safe; we'll sync when you're back."
        case .notFound: "That book isn't in your Cloud library any more."
        }
    }
}
