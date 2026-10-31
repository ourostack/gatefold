import Foundation

/// A PocketBook "provider": the bookstore an account belongs to. Sign-in is per store.
public struct CloudStore: Sendable, Codable, Hashable, Identifiable {
    public var alias: String
    public var name: String
    public var shopID: String
    public var iconURL: URL?
    /// `"password"` for password accounts; social-login accounts report something else.
    public var loggedBy: String?

    public var id: String { shopID + alias }
    public var usesPassword: Bool { loggedBy == nil || loggedBy == "password" }

    public init(alias: String, name: String, shopID: String, iconURL: URL?, loggedBy: String?) {
        self.alias = alias
        self.name = name
        self.shopID = shopID
        self.iconURL = iconURL
        self.loggedBy = loggedBy
    }
}

public struct CloudAccount: Sendable, Codable, Hashable {
    public var email: String
    public var store: CloudStore
    public var displayName: String?
    /// The account's `@pbsync.com` mail-in address. Not a login.
    public var mailInAddress: String?
    public var quotaBytes: Int64?
    public var usedBytes: Int64?

    public init(email: String, store: CloudStore, displayName: String? = nil, mailInAddress: String? = nil, quotaBytes: Int64? = nil, usedBytes: Int64? = nil) {
        self.email = email
        self.store = store
        self.displayName = displayName
        self.mailInAddress = mailInAddress
        self.quotaBytes = quotaBytes
        self.usedBytes = usedBytes
    }
}

public struct CloudBook: Sendable, Codable, Hashable, Identifiable {
    /// PocketBook's per-book key; content-derived and the same across accounts.
    public var fastHash: String
    public var cloudID: String
    public var path: String
    public var name: String
    public var title: String
    public var authors: String?
    public var format: String?
    public var mimeType: String?
    public var bytes: Int64
    /// Base64 of the full-file MD5. Can be nil on the server.
    public var md5Base64: String?
    public var createdAt: Date?
    public var modifiedAt: Date?
    public var readStatus: String?
    public var readPercent: Int?
    public var favorite: Bool
    public var isDRM: Bool
    /// Pre-signed URLs; they expire, so refresh the library before using an old one.
    public var coverURL: URL?
    public var largeCoverURL: URL?
    public var downloadURL: URL?
    public var position: ReadingPosition?

    public var id: String { fastHash }

    public init(fastHash: String, cloudID: String = "", path: String = "", name: String = "", title: String = "", authors: String? = nil,
                format: String? = nil, mimeType: String? = nil, bytes: Int64 = 0, md5Base64: String? = nil, createdAt: Date? = nil,
                modifiedAt: Date? = nil, readStatus: String? = nil, readPercent: Int? = nil, favorite: Bool = false, isDRM: Bool = false,
                coverURL: URL? = nil, largeCoverURL: URL? = nil, downloadURL: URL? = nil, position: ReadingPosition? = nil) {
        self.fastHash = fastHash
        self.cloudID = cloudID
        self.path = path
        self.name = name
        self.title = title
        self.authors = authors
        self.format = format
        self.mimeType = mimeType
        self.bytes = bytes
        self.md5Base64 = md5Base64
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.readStatus = readStatus
        self.readPercent = readPercent
        self.favorite = favorite
        self.isDRM = isDRM
        self.coverURL = coverURL
        self.largeCoverURL = largeCoverURL
        self.downloadURL = downloadURL
        self.position = position
    }
}

/// Who most likely wrote a Cloud position.
public enum PositionSource: String, Sendable, Codable, Hashable {
    /// This app (matched against what we last pushed).
    case gatefold
    /// PocketBook's web reader writes `#epubcfi(...)` in both fields.
    case pocketBookWeb
    /// A `pbr:` pointer: an InkPad or PocketBook's mobile app.
    case pocketBookNative
    case unknown
}

public struct ReadingPosition: Sendable, Codable, Hashable {
    /// Bare `epubcfi(...)`, no PocketBook prefix. Nil for a percent-only position.
    public var cfi: String?
    /// The raw `pointer_pb` as the Cloud holds it, kept so we never rewrite another client's form.
    public var pointer: String?
    /// Progress inside the current resource (Readium `progression`). Local only; the Cloud does not store it.
    public var progression: Double?
    /// Whole-book progress 0...1. The Cloud stores whole percents.
    public var totalProgression: Double
    public var updated: Date
    public var source: PositionSource

    public init(cfi: String?, pointer: String? = nil, progression: Double? = nil, totalProgression: Double, updated: Date, source: PositionSource = .gatefold) {
        self.cfi = cfi
        self.pointer = pointer
        self.progression = progression
        self.totalProgression = totalProgression
        self.updated = updated
        self.source = source
    }

    public var parsedCFI: EPUBCFI? { cfi.flatMap(EPUBCFI.init) }

    /// Same place in the book: identical CFI location, or equal whole percents when either side has no CFI.
    public func isSameLocation(as other: ReadingPosition) -> Bool {
        if let a = parsedCFI, let b = other.parsedCFI { return a.isSameLocation(as: b) }
        return Int((totalProgression * 100).rounded()) == Int((other.totalProgression * 100).rounded())
    }
}

public enum AnnotationKind: Sendable, Hashable, Codable {
    case highlight, note, bookmark
    case other(String)

    public init(wireValue: String) {
        switch wireValue {
        case "highlight": self = .highlight
        case "note": self = .note
        case "bookmark": self = .bookmark
        default: self = .other(wireValue)
        }
    }

    public var wireValue: String {
        switch self {
        case .highlight: "highlight"
        case .note: "note"
        case .bookmark: "bookmark"
        case let .other(value): value
        }
    }

    public init(from decoder: Decoder) throws { self.init(wireValue: try decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(wireValue) }
}

public enum AnnotationColor: Sendable, Hashable, Codable {
    case yellow, cyan, red, green, blue, lime, magenta
    case other(String)

    public init(wireValue: String) {
        switch wireValue {
        case "yellow": self = .yellow
        case "cian", "cyan": self = .cyan // PocketBook spells it "cian"
        case "red": self = .red
        case "green": self = .green
        case "blue": self = .blue
        case "lime": self = .lime
        case "magenta": self = .magenta
        default: self = .other(wireValue)
        }
    }

    public var wireValue: String {
        switch self {
        case .yellow: "yellow"
        case .cyan: "cian"
        case .red: "red"
        case .green: "green"
        case .blue: "blue"
        case .lime: "lime"
        case .magenta: "magenta"
        case let .other(value): value
        }
    }

    public init(from decoder: Decoder) throws { self.init(wireValue: try decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(wireValue) }
}

/// A value with its own last-modified time. The Cloud merges notes field by field and keeps
/// the newer `updated`; a field sent without one overwrites unconditionally.
public struct Stamped<Value: Sendable & Hashable & Codable>: Sendable, Hashable, Codable {
    public var value: Value
    public var updated: Date?
    public init(_ value: Value, updated: Date?) {
        self.value = value
        self.updated = updated
    }

    /// Per-field newest-wins. Ties keep `self`.
    public func newest(_ other: Stamped<Value>) -> Stamped<Value> {
        switch (updated, other.updated) {
        case let (a?, b?): b > a ? other : self
        case (nil, _?): other
        default: self
        }
    }
}

public struct AnnotationMark: Sendable, Hashable, Codable {
    public var anchor: String
    public var created: Date?
    public init(anchor: String, created: Date?) {
        self.anchor = anchor
        self.created = created
    }
}

public struct AnnotationQuotation: Sendable, Hashable, Codable {
    public var begin: String
    public var end: String
    public var text: String
    public init(begin: String, end: String, text: String) {
        self.begin = begin
        self.end = end
        self.text = text
    }
}

/// A PocketBook Cloud highlight, note or bookmark.
public struct CloudAnnotation: Sendable, Hashable, Codable, Identifiable {
    /// Server-assigned; nil until created.
    public var uuid: String?
    public var kind: Stamped<AnnotationKind>
    public var color: Stamped<AnnotationColor>?
    public var note: Stamped<String>?
    public var mark: Stamped<AnnotationMark>?
    public var quotation: Stamped<AnnotationQuotation>?

    public var id: String { uuid ?? "local:\(quotation?.value.begin ?? mark?.value.anchor ?? "")" }

    public init(uuid: String? = nil, kind: Stamped<AnnotationKind>, color: Stamped<AnnotationColor>? = nil, note: Stamped<String>? = nil,
                mark: Stamped<AnnotationMark>? = nil, quotation: Stamped<AnnotationQuotation>? = nil) {
        self.uuid = uuid
        self.kind = kind
        self.color = color
        self.note = note
        self.mark = mark
        self.quotation = quotation
    }

    public static func highlight(begin: String, end: String, text: String, color: AnnotationColor = .yellow, note: String? = nil, at date: Date) -> CloudAnnotation {
        CloudAnnotation(
            kind: .init(note == nil ? .highlight : .note, updated: date),
            color: .init(color, updated: date),
            note: .init(note ?? "", updated: date),
            mark: .init(AnnotationMark(anchor: begin, created: date), updated: date),
            quotation: .init(AnnotationQuotation(begin: begin, end: end, text: text), updated: date)
        )
    }

    /// The shape PocketBook's web reader writes for a bookmark.
    public static func bookmark(at anchor: String, date: Date) -> CloudAnnotation {
        CloudAnnotation(
            kind: .init(.bookmark, updated: date),
            mark: .init(AnnotationMark(anchor: anchor, created: date), updated: date),
            quotation: .init(AnnotationQuotation(begin: anchor, end: anchor, text: ""), updated: date)
        )
    }

    /// Field-by-field newest-wins merge, the rule the Cloud applies on write.
    public func merged(with other: CloudAnnotation) -> CloudAnnotation {
        func pick<T>(_ a: Stamped<T>?, _ b: Stamped<T>?) -> Stamped<T>? {
            switch (a, b) {
            case let (a?, b?): a.newest(b)
            default: a ?? b
            }
        }
        return CloudAnnotation(uuid: uuid ?? other.uuid, kind: kind.newest(other.kind), color: pick(color, other.color),
                               note: pick(note, other.note), mark: pick(mark, other.mark), quotation: pick(quotation, other.quotation))
    }

    /// The location used to de-duplicate: begin anchor for highlights, mark anchor for bookmarks.
    public var dedupeKey: String {
        let begin = quotation?.value.begin ?? mark?.value.anchor ?? ""
        let normalized = EPUBCFI(begin)?.description ?? begin
        switch kind.value {
        case .bookmark: return "bookmark|" + normalized
        default: return "text|" + normalized + "|" + (EPUBCFI(quotation?.value.end ?? "")?.description ?? "") + "|" + (quotation?.value.text ?? "")
        }
    }
}

/// One row of `GET /notes?fast_hash=`.
public struct AnnotationSummary: Sendable, Hashable, Codable {
    public var uuid: String
    public var kind: AnnotationKind
    public var updated: Date?
    public init(uuid: String, kind: AnnotationKind, updated: Date?) {
        self.uuid = uuid
        self.kind = kind
        self.updated = updated
    }
}

public struct CloudToken: Sendable, Codable, Hashable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date
    public init(accessToken: String, refreshToken: String?, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

/// What changed, for the UI. Treat every case as "re-read what you show".
public enum CloudChange: Sendable, Hashable {
    case library([CloudBook])
    case bookAdded(CloudBook)
    case bookUpdated(CloudBook)
    case bookRemoved(fastHash: String)
    /// A newer position arrived from another client.
    case remotePosition(fastHash: String, ReadingPosition)
    /// Our queued position lost to a newer one from another client and was dropped.
    case positionSuperseded(fastHash: String, remote: ReadingPosition)
    case annotations(fastHash: String, [CloudAnnotation])
    case outbox(pending: Int)
    case signedIn(CloudAccount)
    case signedOut
    /// The refresh token stopped working; the user must sign in again.
    case authenticationRequired
}
