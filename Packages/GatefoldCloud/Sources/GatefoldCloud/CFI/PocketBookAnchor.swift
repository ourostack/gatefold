import Foundation

/// A location string as PocketBook stores it in `pointer`, `pointer_pb`, `mark.anchor` and
/// `quotation.begin`/`end`.
public enum PocketBookAnchor: Sendable, Hashable {
    /// How a CFI anchor is prefixed. Each PocketBook client writes its own form.
    public enum Style: String, Sendable, Hashable, Codable {
        /// `#epubcfi(...)`: the web reader, and the `pointer` field everywhere.
        case web
        /// `pbr:/external##epubcfi(...)`: seen in `pointer_pb` written by native clients.
        case external
        /// `pbr:/webkit?##epubcfi(...)`: the InkPad's own database form.
        case device
        /// A bare `epubcfi(...)`.
        case bare
    }

    case cfi(EPUBCFI, style: Style)
    /// Layout-dependent PocketBook page anchor (FB2 and similar). Resolve by quoted text.
    case page(page: Int, offset: Int?)
    /// Layout-dependent word anchor used by dictionary notes. Resolve by quoted text.
    case word(page: Int, offset: Int?)
    /// PDF location; `pageIndex` is 0-based.
    case pdf(fastHash: String, pageIndex: Int)
    case unknown(String)

    public init(_ raw: String) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cfi = EPUBCFI(s) {
            let style: Style
            if s.hasPrefix("pbr:/external") { style = .external }
            else if s.hasPrefix("pbr:/webkit") { style = .device }
            else if s.hasPrefix("#") { style = .web }
            else { style = .bare }
            self = .cfi(cfi, style: style)
            return
        }
        // PocketBook's parser reads whatever follows the last `#`.
        let tail = s.range(of: "#", options: .backwards).map { String(s[$0.upperBound...]) } ?? s
        if tail.hasPrefix("pdfloc("), tail.hasSuffix(")") {
            let args = tail.dropFirst("pdfloc(".count).dropLast().split(separator: ",", omittingEmptySubsequences: false)
            if args.count == 2, let page = Int(args[1]) {
                self = .pdf(fastHash: String(args[0]), pageIndex: page)
                return
            }
        }
        for (prefix, make) in [("pbr:/word?", PocketBookAnchor.word), ("pbr:/page?", PocketBookAnchor.page)] where s.hasPrefix(prefix) {
            let query = Self.query(String(s.dropFirst(prefix.count)))
            if let page = query["page"].flatMap(Int.init) {
                self = make(page, query["offs"].flatMap(Int.init))
                return
            }
        }
        self = .unknown(s)
    }

    public var cfi: EPUBCFI? {
        if case let .cfi(cfi, _) = self { return cfi }
        return nil
    }

    public var style: Style? {
        if case let .cfi(_, style) = self { return style }
        return nil
    }

    public static func string(for cfi: EPUBCFI, style: Style) -> String {
        switch style {
        case .web: "#" + cfi.description
        case .external: "pbr:/external##" + cfi.description
        case .device: "pbr:/webkit?##" + cfi.description
        case .bare: cfi.description
        }
    }

    private static func query(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in text.split(separator: "#").first?.split(separator: "&") ?? [] {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { out[String(kv[0])] = String(kv[1]) }
        }
        return out
    }
}
