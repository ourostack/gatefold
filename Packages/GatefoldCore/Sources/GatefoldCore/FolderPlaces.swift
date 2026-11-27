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
/// conflict copies; every device reads all of them and settles each book by what moved since it last looked (`settle`).
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

    /// Times keep their fractions of a second, so two pages turned in one second are two places.
    public static func encode(_ file: FolderPlaceFile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var box = encoder.singleValueContainer()
            try box.encode(date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted)))
        }
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(file)
    }

    public static func decode(_ data: Data) throws -> FolderPlaceFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(text, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted)) { return date }
            if let date = try? Date(text, strategy: .iso8601) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not an ISO 8601 time: \(text)"))
        }
        return try decoder.decode(FolderPlaceFile.self, from: data)
    }

    /// Every file that reads; one that doesn't (half-synced, or damaged) is skipped until it does.
    public static func decodeAll(_ files: [Data]) -> [FolderPlaceFile] { files.compactMap { try? decode($0) } }

    /// What to do with the places other devices left for one book, given this device's own place and
    /// what it last settled (`mark`). `remotes` is each other device's own entry, by device ID: a device
    /// writes only places it read itself, never one it took from the folder.
    ///
    /// A device moved when its entry changed since the mark: a new time and another page (opening a book
    /// on the same page is not a move). Times are compared only with that device's own earlier times, so
    /// clocks that disagree don't matter, except for a device seen for the first time, which counts as
    /// moved when its place is newer than this device's was at the mark.
    ///
    /// - Nobody else moved: this device's place stays.
    /// - Others moved and this device didn't: the newest of their places is taken, even going back
    ///   (rereading is a place too).
    /// - Both moved: the place further on wins, so a page turned on a device that had the book open on
    ///   an old page never sends the reader back.
    public static func settle(_ remotes: [String: FolderPlace], local: FolderSyncMark.Seen?, mark: FolderSyncMark?) -> FolderSettlement {
        let before = mark?.local ?? local
        let moved = remotes.filter { id, place in
            if let seen = mark?.others[id] { return FolderSyncMark.Seen(place).differs(from: seen) }
            guard let before else { return true }
            return place.updated > before.updated
        }
        guard let newest = moved.values.max(by: { $0.updated < $1.updated }) else { return .keepLocal }
        guard let local else { return .takeRemote(newest) }
        let localMoved = mark.map { mark in mark.local.map { local.differs(from: $0) } ?? true } ?? false
        guard localMoved else { return .takeRemote(newest) }
        let furthest = moved.values.max(by: { $0.progression < $1.progression })!
        return furthest.progression > local.progression ? .takeRemote(furthest) : .keepLocal
    }

    /// The places file a folder listing names: the file itself, or the placeholder iCloud Drive lists
    /// in its place (".places-X.json.icloud") while the file isn't downloaded yet; nil for anything else.
    public static func placesFile(listedAs name: String) -> String? {
        var real = name
        if name.hasPrefix("."), name.hasSuffix(".icloud") {
            real = String(name.dropFirst().dropLast(".icloud".count))
        }
        return deviceID(fromFileName: real) == nil ? nil : real
    }
}

/// What a device last settled with the folder for one book (`FolderPlaces.settle`).
public struct FolderSyncMark: Codable, Equatable, Sendable {
    /// A place, as far as settling needs it: when, and how far.
    public struct Seen: Codable, Equatable, Sendable {
        public var updated: Date
        public var progression: Double

        public init(updated: Date, progression: Double) {
            self.updated = updated
            self.progression = progression
        }

        public init(_ place: FolderPlace) { self.init(updated: place.updated, progression: place.progression) }

        /// Another place: a new time and another page.
        public func differs(from other: Seen) -> Bool {
            updated != other.updated && abs(progression - other.progression) > 0.0005
        }
    }

    /// Each other device's place then, by device ID.
    public var others: [String: Seen]
    /// This device's own place then; nil when it had none.
    public var local: Seen?
    /// The place this device last took from the folder: while the book is still on that page (opened
    /// there or not), it isn't this device's own reading, so it isn't written back to the folder.
    public var taken: Seen?

    public init(others: [String: Seen] = [:], local: Seen? = nil, taken: Seen? = nil) {
        self.others = others
        self.local = local
        self.taken = taken
    }
}

public enum FolderSettlement: Equatable, Sendable {
    case takeRemote(FolderPlace)
    case keepLocal
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
