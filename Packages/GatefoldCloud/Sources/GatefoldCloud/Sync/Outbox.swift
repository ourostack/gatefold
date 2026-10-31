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
    /// A create was handed to the network at least once, so it may exist on the server already.
    var sendStarted = false
    /// The user deleted an annotation whose create may already be on its way.
    var deleteAfterCreate = false

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
    /// Server uuids of annotations we created, by `fast_hash|dedupeKey`, so the app's uuid-less copy
    /// can still be edited or deleted after the create lands.
    var createdUUIDs: [String: String] = [:]

    /// Forgets a uuid we created, once its note is deleted, so the same passage can be highlighted anew.
    mutating func forgetCreated(uuid: String) {
        createdUUIDs = createdUUIDs.filter { $0.value != uuid }
    }

    static func annotationKey(_ fastHash: String, _ annotation: CloudAnnotation) -> String { "\(fastHash)|\(annotation.dedupeKey)" }

    mutating func enqueue(_ item: OutboxItem) {
        if let i = items.firstIndex(where: { $0.coalescingKey == item.coalescingKey }) {
            var merged = items[i]
            merged.operation = Self.combine(merged.operation, item.operation)
            merged.revision += 1
            if case .createAnnotation = item.operation { merged.deleteAfterCreate = false } // saved again: an undo
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

    /// Like `read`, but an existing file that does not decode is moved aside instead of being
    /// overwritten later, so queued work is never silently lost.
    static func readOrSetAside<T: Decodable>(_ type: T.Type, at url: URL, now: Date) -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        if let value = read(type, at: url) { return value }
        let stamp = Int(now.timeIntervalSince1970)
        let aside = url.deletingLastPathComponent().appendingPathComponent("\(url.deletingPathExtension().lastPathComponent).unreadable-\(stamp).json")
        try? FileManager.default.moveItem(at: url, to: aside)
        return nil
    }

    static func write<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: [.atomic])
    }
}
