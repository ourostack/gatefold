import Foundation

/// One queued write. Kept on disk until the Cloud confirms it or rejects it for good.
struct OutboxItem: Codable, Sendable, Hashable {
    enum Operation: Codable, Sendable, Hashable {
        case position(ReadingPosition)
        case createAnnotation(CloudAnnotation)
        case updateAnnotation(CloudAnnotation)
        case deleteAnnotation(uuid: String)
    }

    var id = UUID()
    var fastHash: String
    var operation: Operation
    /// Failed sends so far. A create that failed may still have landed, so replays check first.
    var attempts = 0
    var notBefore: Date?
    /// Bumped when a newer write replaces the payload while a send is in flight.
    var revision = 0

    /// Writes with the same key replace each other instead of queueing twice.
    var coalescingKey: String {
        switch operation {
        case .position: "position|\(fastHash)"
        case let .createAnnotation(a): "create|\(fastHash)|\(a.dedupeKey)"
        case let .updateAnnotation(a): "note|\(a.uuid ?? "")"
        case let .deleteAnnotation(uuid): "note|\(uuid)"
        }
    }
}

/// The outbox plus what we last wrote, saved atomically as one JSON file.
struct OutboxState: Codable, Sendable {
    /// Email of the account the queued writes belong to.
    var owner: String?
    var items: [OutboxItem] = []
    /// The `pointer_pb` we last wrote per book, to recognise our own position when it comes back.
    var pushedPointers: [String: String] = [:]

    mutating func enqueue(_ item: OutboxItem) {
        if let i = items.firstIndex(where: { $0.coalescingKey == item.coalescingKey }) {
            var merged = items[i]
            merged.operation = Self.combine(merged.operation, item.operation)
            merged.revision += 1
            items[i] = merged
        } else {
            items.append(item)
        }
    }

    private static func combine(_ old: OutboxItem.Operation, _ new: OutboxItem.Operation) -> OutboxItem.Operation {
        switch (old, new) {
        case let (.updateAnnotation(a), .updateAnnotation(b)): .updateAnnotation(a.merged(with: b))
        case let (.createAnnotation(a), .createAnnotation(b)): .createAnnotation(a.merged(with: b))
        default: new
        }
    }
}

enum JSONFile {
    static func read<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func write<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: [.atomic])
    }
}
