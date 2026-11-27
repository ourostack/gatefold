import Foundation

/// One book's place, as a watched folder carries it between devices: Readium's locator, so the other
/// device opens on the same words (the file there has the same bytes), and when it was read there.
public struct FolderPlace: Codable, Equatable, Sendable {
    public var locator: String
    public var progression: Double
    public var updated: Date
    /// The device that read there ("iPhone", "iPad"), never its owner's name.
    public var device: String

    public init(locator: String, progression: Double, updated: Date, device: String) {
        self.locator = locator
        self.progression = progression
        self.updated = updated
        self.device = device
    }
}

/// One device's places for the books in a watched folder, keyed by each book's SHA-256.
public struct FolderPlaceFile: Codable, Equatable, Sendable {
    public var version = 1
    public var device: String
    public var places: [String: FolderPlace]

    public init(device: String, places: [String: FolderPlace] = [:]) {
        self.device = device
        self.places = places
    }

    public mutating func record(_ place: FolderPlace, for digest: String) { places[digest] = place }
}

/// Places travel through the watched folder itself, in a hidden `.gatefold` folder there. Each device
/// writes only its own file, so iCloud Drive never sees two writers of one file and never makes
/// conflict copies; every device reads all of them, and the newest place for a book wins.
public enum FolderPlaces {
    public static let directory = ".gatefold"

    public static func fileName(deviceID: String) -> String { "places-\(deviceID).json" }

    /// The device a places file belongs to; nil for anything else, a conflict copy ("places-X 2.json") included.
    public static func deviceID(fromFileName name: String) -> String? {
        guard name.hasPrefix("places-"), name.hasSuffix(".json") else { return nil }
        let id = String(name.dropFirst("places-".count).dropLast(".json".count))
        guard !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
        return id
    }

    public static func encode(_ file: FolderPlaceFile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(file)
    }

    public static func decode(_ data: Data) throws -> FolderPlaceFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(FolderPlaceFile.self, from: data)
    }

    /// Every file that reads; one that doesn't (half-synced, or damaged) is skipped until it does.
    public static func decodeAll(_ files: [Data]) -> [FolderPlaceFile] { files.compactMap { try? decode($0) } }

    /// The newest place for each book across every device's file. Newest, not furthest: going back to
    /// reread a chapter is a place too.
    public static func newest(in files: [FolderPlaceFile]) -> [String: FolderPlace] {
        var out: [String: FolderPlace] = [:]
        for file in files {
            for (digest, place) in file.places where out[digest].map({ place.updated > $0.updated }) ?? true {
                out[digest] = place
            }
        }
        return out
    }

    /// The folder's place, when it is newer than the place here; nil to leave this device's own alone.
    public static func take(_ remote: FolderPlace?, overLocalUpdated local: Date?, localProgression: Double) -> FolderPlace? {
        guard let remote else { return nil }
        guard let local else { return remote }
        // ISO 8601 keeps whole seconds: a place this device wrote comes back a fraction older, never newer.
        return remote.updated.timeIntervalSince(local) >= 1 ? remote : nil
    }
}

/// What the watched folder held at the last look, so only new or changed books are read again.
public struct FolderIndex: Codable, Equatable, Sendable {
    public struct Stamp: Codable, Equatable, Sendable {
        public var size: Int64
        public var modified: TimeInterval

        public init(size: Int64, modified: TimeInterval) {
            self.size = size
            self.modified = modified
        }
    }

    /// Keyed by the book's path inside the folder.
    public var stamps: [String: Stamp]

    public init(stamps: [String: Stamp] = [:]) { self.stamps = stamps }

    /// Paths that are new, or whose size or date moved, sorted.
    public func changed(in now: [String: Stamp]) -> [String] {
        now.filter { stamps[$0.key] != $0.value }.keys.sorted()
    }
}
