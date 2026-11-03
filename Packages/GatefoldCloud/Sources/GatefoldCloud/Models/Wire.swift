import Foundation
import GatefoldCore

/// Every date form the Cloud sends: ISO-8601 (with or without fractions or offset),
/// `yyyy-MM-dd HH:mm:ss` (UTC, on upload responses) and unix seconds.
enum PBDate {
    static func parse(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if s.allSatisfy(\.isNumber), let seconds = Double(s) { return Date(timeIntervalSince1970: seconds) }
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        let plain = DateFormatter()
        plain.locale = Locale(identifier: "en_US_POSIX")
        plain.timeZone = TimeZone(identifier: "UTC")
        plain.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return plain.date(from: s)
    }

    static func string(_ date: Date) -> String {
        let iso = ISO8601DateFormatter()
        return iso.string(from: Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)))
    }
}

/// A JSON value decoded loosely: the Cloud mixes strings, numbers and nulls for the same field.
enum Loose: Decodable {
    case string(String), number(Double), bool(Bool), null, array([Loose]), object([String: Loose])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([Loose].self) { self = .array(a) }
        else { self = .object(try c.decode([String: Loose].self)) }
    }

    subscript(key: String) -> Loose? { if case let .object(o) = self { return o[key] } else { return nil } }

    var string: String? {
        switch self {
        case let .string(s): s
        case let .number(n): n == n.rounded() ? String(Int64(n)) : String(n)
        default: nil
        }
    }
    var int: Int64? {
        switch self {
        case let .number(n): Int64(n)
        case let .string(s): Int64(s)
        default: nil
        }
    }
    var double: Double? {
        switch self {
        case let .number(n): n
        case let .string(s): Double(s)
        default: nil
        }
    }
    var bool: Bool? { if case let .bool(b) = self { return b } else { return nil } }
    var array: [Loose]? { if case let .array(a) = self { return a } else { return nil } }
    var url: URL? { string.flatMap(URL.init(string:)) }
    var date: Date? {
        switch self {
        case let .number(n): Date(timeIntervalSince1970: n)
        case let .string(s): PBDate.parse(s)
        default: nil
        }
    }
}

public enum WireError: Error, Equatable {
    case unexpectedShape(String)
}

enum WireDecoder {
    static func loose(_ data: Data) throws -> Loose { try JSONDecoder().decode(Loose.self, from: data) }

    static func stores(_ data: Data) throws -> [CloudStore] {
        guard let providers = try loose(data)["providers"]?.array else { throw WireError.unexpectedShape("providers") }
        return providers.compactMap { p in
            guard let alias = p["alias"]?.string else { return nil }
            return CloudStore(alias: alias, name: p["name"]?.string ?? alias, shopID: p["shop_id"]?.string ?? "",
                              iconURL: p["icon"]?.url, loggedBy: p["logged_by"]?.string)
        }
    }

    static func token(_ data: Data, now: Date) throws -> CloudToken {
        let j = try loose(data)
        guard let access = j["access_token"]?.string else { throw WireError.unexpectedShape("access_token") }
        // PocketOrbit assumes an hour when expires_in is missing.
        let lifetime = j["expires_in"]?.double ?? 3600
        return CloudToken(accessToken: access, refreshToken: j["refresh_token"]?.string, expiresAt: now.addingTimeInterval(lifetime))
    }

    static func account(_ data: Data, store: CloudStore) throws -> CloudAccount {
        let j = try loose(data)
        guard let email = j["email"]?.string ?? j["login"]?.string else { throw WireError.unexpectedShape("user.email") }
        return CloudAccount(email: email, store: store, displayName: j["full_name"]?.string,
                            mailInAddress: j["internal_account"]?["email"]?.string,
                            quotaBytes: j["files_size_limit"]?.int, usedBytes: j["files_size"]?.int)
    }

    /// One page of `/books`: `listed` counts every entry, `items` only the ones we could read.
    static func booksPage(_ data: Data) throws -> (total: Int, items: [CloudBook], listed: Int) {
        let j = try loose(data)
        guard let items = j["items"]?.array else { throw WireError.unexpectedShape("books.items") }
        return (Int(j["total"]?.int ?? Int64(items.count)), items.compactMap(book), items.count)
    }

    static func uploadResponse(_ data: Data) throws -> CloudBook {
        guard let b = book(try loose(data)) else { throw WireError.unexpectedShape("upload.fast_hash") }
        return b
    }

    static func fileInfo(_ data: Data) throws -> (book: CloudBook, position: ReadingPosition?) {
        let j = try loose(data)
        guard let b = book(j) else { throw WireError.unexpectedShape("fileops.info") }
        return (b, b.position)
    }

    static func book(_ j: Loose) -> CloudBook? {
        guard let fastHash = j["fast_hash"]?.string, !fastHash.isEmpty else { return nil }
        let meta = j["metadata"]
        let covers = meta?["cover"]?.array ?? []
        let sortedCovers = covers.sorted { ($0["width"]?.double ?? 0) < ($1["width"]?.double ?? 0) }
        let name = j["name"]?.string ?? ""
        return CloudBook(
            fastHash: fastHash,
            cloudID: j["id"]?.string ?? "",
            path: j["path"]?.string ?? "",
            name: name,
            title: j["title"]?.string ?? meta?["title"]?.string ?? name,
            authors: meta?["authors"]?.string,
            format: j["format"]?.string,
            mimeType: j["mime_type"]?.string,
            bytes: j["bytes"]?.int ?? 0,
            md5Base64: j["md5_hash"]?.string,
            createdAt: j["created_at"]?.date,
            modifiedAt: j["mtime"]?.date,
            readStatus: j["read_status"]?.string,
            readPercent: j["read_percent"]?.int.map(Int.init),
            favorite: j["favorite"]?.bool ?? false,
            isDRM: (j["isDrm"]?.bool ?? false) || (j["isLcp"]?.bool ?? false),
            coverURL: sortedCovers.first?["path"]?.url,
            largeCoverURL: sortedCovers.last?["path"]?.url,
            downloadURL: j["link"]?.url ?? j["download_link"]?.url,
            position: position(j["position"] ?? j["read_position"])
        )
    }

    /// Nil when the Cloud has no position (`updated` null and no pointer).
    static func position(_ j: Loose?) -> ReadingPosition? {
        guard let j else { return nil }
        let pointerPB = j["pointer_pb"]?.string
        let pointer = j["pointer"]?.string
        guard let updated = j["updated"]?.date, pointerPB != nil || pointer != nil || (j["percent"]?.double ?? 0) > 0 else { return nil }
        let raw = pointerPB ?? pointer
        let cfi = (pointerPB.flatMap(EPUBCFI.init) ?? pointer.flatMap(EPUBCFI.init))?.description
        let percent = j["percent"]?.double ?? j["offs"]?.double ?? 0
        let source: PositionSource
        switch raw.map(PocketBookAnchor.init) {
        case .cfi(_, .web)?: source = .pocketBookWeb
        case .cfi(_, .external)?, .cfi(_, .device)?, .page?, .word?: source = .pocketBookNative
        case .pdf?: source = raw?.hasPrefix("pbr:") == true ? .pocketBookNative : .pocketBookWeb
        default: source = .unknown
        }
        return ReadingPosition(cfi: cfi, pointer: raw, totalProgression: ReadingPercent.fraction(percent), updated: updated, source: source)
    }

    static func annotation(_ data: Data) throws -> CloudAnnotation {
        let j = try loose(data)
        if let list = j.array, let first = list.first { return try annotation(first) }
        return try annotation(j)
    }

    static func annotation(_ j: Loose) throws -> CloudAnnotation {
        guard let type = j["type"], let kind = type["value"]?.string else { throw WireError.unexpectedShape("note.type") }
        func stamped<T>(_ field: Loose?, _ make: (Loose) -> T?) -> Stamped<T>? {
            guard let field, let value = make(field) else { return nil }
            return Stamped(value, updated: field["updated"]?.date)
        }
        return CloudAnnotation(
            uuid: j["uuid"]?.string,
            kind: Stamped(AnnotationKind(wireValue: kind), updated: type["updated"]?.date),
            color: stamped(j["color"]) { $0["value"]?.string.map(AnnotationColor.init(wireValue:)) },
            note: stamped(j["note"]) { $0["text"]?.string },
            mark: stamped(j["mark"]) { m in m["anchor"]?.string.map { AnnotationMark(anchor: $0, created: m["created"]?.date) } },
            quotation: stamped(j["quotation"]) { q in
                guard let begin = q["begin"]?.string else { return nil }
                return AnnotationQuotation(begin: begin, end: q["end"]?.string ?? begin, text: q["text"]?.string ?? "")
            }
        )
    }

    static func annotationList(_ data: Data) throws -> [AnnotationSummary] {
        let j = try loose(data)
        guard let rows = j.array ?? j["items"]?.array else { throw WireError.unexpectedShape("notes list") }
        return rows.compactMap { r in
            guard let uuid = r["uuid"]?.string else { return nil }
            let type = r["type"]?.string ?? r["type"]?["value"]?.string ?? ""
            return AnnotationSummary(uuid: uuid, kind: AnnotationKind(wireValue: type), updated: r["updated"]?.date)
        }
    }
}

enum WireEncoder {
    static func positionBody(_ position: ReadingPosition, pointerStyle: PocketBookAnchor.Style) throws -> Data {
        var body: [String: Any] = ["offs": position.wholePercent]
        if let cfi = position.parsedCFI {
            body["pointer"] = PocketBookAnchor.string(for: cfi, style: .web)
            body["pointer_pb"] = PocketBookAnchor.string(for: cfi, style: pointerStyle)
        }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    static func annotationBody(_ a: CloudAnnotation) throws -> Data {
        try JSONSerialization.data(withJSONObject: fields(kind: a.kind, color: a.color, note: a.note, mark: a.mark, quotation: a.quotation), options: [.sortedKeys])
    }

    static func annotationPatch(kind: Stamped<AnnotationKind>? = nil, color: Stamped<AnnotationColor>? = nil, note: Stamped<String>? = nil,
                                mark: Stamped<AnnotationMark>? = nil, quotation: Stamped<AnnotationQuotation>? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: fields(kind: kind, color: color, note: note, mark: mark, quotation: quotation), options: [.sortedKeys])
    }

    private static func fields(kind: Stamped<AnnotationKind>?, color: Stamped<AnnotationColor>?, note: Stamped<String>?,
                               mark: Stamped<AnnotationMark>?, quotation: Stamped<AnnotationQuotation>?) -> [String: Any] {
        func withUpdated(_ dict: [String: Any], _ date: Date?) -> [String: Any] {
            var d = dict
            if let date { d["updated"] = PBDate.string(date) }
            return d
        }
        var body: [String: Any] = [:]
        if let kind { body["type"] = withUpdated(["value": kind.value.wireValue], kind.updated) }
        if let color { body["color"] = withUpdated(["value": color.value.wireValue], color.updated) }
        if let note { body["note"] = withUpdated(["text": note.value], note.updated) }
        if let mark {
            var m: [String: Any] = ["anchor": mark.value.anchor]
            if let created = mark.value.created { m["created"] = Int(created.timeIntervalSince1970) }
            body["mark"] = withUpdated(m, mark.updated)
        }
        if let q = quotation { body["quotation"] = withUpdated(["begin": q.value.begin, "end": q.value.end, "text": q.value.text], q.updated) }
        return body
    }
}
