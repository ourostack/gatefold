import Foundation

/// One page of an OPDS catalog: a list of shelves to open and books to download, from OPDS 1.2 Atom,
/// OPDS 2.0 JSON or a plain Atom feed of enclosures. Every URL in it is already absolute.
public struct CatalogFeed: Equatable, Sendable {
    public var title: String
    public var entries: [CatalogEntry]
    public var next: URL?
    public var previous: URL?
    public var search: CatalogSearch?

    public init(title: String, entries: [CatalogEntry], next: URL? = nil, previous: URL? = nil, search: CatalogSearch? = nil) {
        self.title = title
        self.entries = entries
        self.next = next
        self.previous = previous
        self.search = search
    }
}

/// A shelf to open (`navigation`), a book to download (`acquisitions`), or both. Entries with neither an
/// EPUB nor a feed are kept, so the shelf can show them as unavailable instead of silently dropping them.
public struct CatalogEntry: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var author: String?
    public var summary: String?
    public var navigation: URL?
    public var acquisitions: [CatalogAcquisition]
    public var cover: URL?
    public var thumbnail: URL?

    public init(id: String, title: String, author: String?, summary: String?, navigation: URL?, acquisitions: [CatalogAcquisition], cover: URL?, thumbnail: URL?) {
        self.id = id
        self.title = title
        self.author = author
        self.summary = summary
        self.navigation = navigation
        self.acquisitions = acquisitions
        self.cover = cover
        self.thumbnail = thumbnail
    }

    /// The EPUB to download, or nil when there is none the app can read. Gutenberg offers several editions
    /// and only says which is which in the href and title, so EPUB3 beats EPUB and images beat none.
    /// On a tie the server's own order wins: Standard Ebooks lists its recommended file first.
    public var epub: CatalogAcquisition? {
        var best: CatalogAcquisition?
        for acquisition in acquisitions where acquisition.isEPUB && acquisition.isDirect {
            if let current = best, acquisition.editionScore <= current.editionScore { continue }
            best = acquisition
        }
        return best
    }
}

/// A download link. `mediaType` is the base type without parameters, lowercased (`application/epub+zip`).
public struct CatalogAcquisition: Equatable, Sendable {
    public var url: URL
    public var mediaType: String
    public var rel: String
    public var length: Int?
    public var title: String?

    public init(url: URL, mediaType: String, rel: String, length: Int?, title: String?) {
        self.url = url
        self.mediaType = mediaType
        self.rel = rel
        self.length = length
        self.title = title
    }

    var isEPUB: Bool {
        if mediaType == "application/epub+zip" { return true }
        // Some servers send no type, or a generic one, for a file that is plainly an EPUB.
        let generic = mediaType.isEmpty || mediaType == "application/octet-stream"
        return generic && url.path.lowercased().hasSuffix(".epub")
    }

    /// Buying, borrowing, subscribing and samples need a flow the app doesn't have, or aren't the book.
    var isDirect: Bool {
        let indirect = ["buy", "borrow", "subscribe", "sample", "preview"]
        return !indirect.contains { rel == CatalogLinkRel.acquisition + "/" + $0 }
    }

    var editionScore: Int {
        let text = (url.absoluteString + " " + (title ?? "")).lowercased()
        var score = 0
        if text.contains("noimages") || text.contains("no images") {
            score -= 2
        } else if text.contains("images") {
            score += 1
        }
        if text.contains("epub3") { score += 2 }
        return score
    }
}

/// How a catalog searches: a URL template to fill in now, or an OpenSearch description to fetch first
/// (then `OpenSearchDescription.parse` turns it into a template).
public enum CatalogSearch: Equatable, Sendable {
    /// An absolute URL with OpenSearch `{searchTerms}` or an RFC 6570 expression such as `{?query}`.
    case template(String)
    case description(URL)

    /// The URL to fetch for these search terms, or nil for a blank query or a description not yet fetched.
    public func url(for query: String) -> URL? {
        guard case .template(let template) = self else { return nil }
        let terms = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !terms.isEmpty else { return nil }
        let encoded = Self.encode(terms)
        var expanded = ""
        var index = template.startIndex
        while index < template.endIndex {
            if template[index] == "{", let close = template[index...].firstIndex(of: "}") {
                expanded += Self.expand(String(template[template.index(after: index)..<close]), with: encoded)
                index = template.index(after: close)
            } else {
                expanded.append(template[index])
                index = template.index(after: index)
            }
        }
        return URL(string: CatalogLinks.secured(expanded))
    }

    /// RFC 3986 unreserved characters stay; everything else, spaces included, is percent-encoded.
    static func encode(_ terms: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return terms.addingPercentEncoding(withAllowedCharacters: unreserved) ?? terms
    }

    /// One `{…}` expression. `?` and `&` are RFC 6570 form-style query expansions (OPDS 2); anything else is
    /// an OpenSearch parameter, where a trailing `?` marks it optional. Only the search terms get a value.
    private static func expand(_ expression: String, with encoded: String) -> String {
        if let op = expression.first, op == "?" || op == "&" {
            let names = expression.dropFirst().split(separator: ",").map { variableName(String($0)) }
            let pairs = names.filter(isSearchTerms).map { "\($0)=\(encoded)" }
            return pairs.isEmpty ? "" : String(op) + pairs.joined(separator: "&")
        }
        var name = expression
        if let op = name.first, "+#./;".contains(op) { name.removeFirst() }
        let optional = name.hasSuffix("?")
        if optional { name.removeLast() }
        name = variableName(name)
        if isSearchTerms(name) { return encoded }
        // OpenSearch counts pages and items from 1 unless the description says otherwise.
        if !optional, name == "startPage" || name == "startIndex" { return "1" }
        return ""
    }

    private static func variableName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespaces)
        if name.hasSuffix("*") { name.removeLast() }
        // RFC 6570 prefix modifier (`query:3`); OpenSearch namespaces look like `os:searchTerms`.
        if let colon = name.lastIndex(of: ":") {
            let after = name[name.index(after: colon)...]
            name = after.allSatisfy(\.isNumber) ? String(name[..<colon]) : String(after)
        }
        return name
    }

    private static func isSearchTerms(_ name: String) -> Bool {
        name == "searchTerms" || name == "query"
    }
}

public enum CatalogError: Error, Equatable, Sendable {
    /// The bytes aren't XML or JSON this parser can read.
    case unreadable
    /// It parsed, but it's something else: a web page, an OpenSearch description, an empty JSON object.
    case notACatalog
}
