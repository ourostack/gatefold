import Foundation

enum CatalogLinkRel {
    static let acquisition = "http://opds-spec.org/acquisition"
    // calibre sends all four cover rels on every book; the older `cover` and `thumbnail` ones come first.
    static let covers: Set = ["http://opds-spec.org/image", "http://opds-spec.org/cover", "x-stanza-cover-image"]
    static let thumbnails: Set = ["http://opds-spec.org/image/thumbnail", "http://opds-spec.org/thumbnail", "x-stanza-cover-image-thumbnail"]
}

/// A media type split into its base and parameters, so `application/atom+xml;type=feed;profile=opds-catalog`
/// and plain `application/atom+xml` are the same kind of document.
struct CatalogMediaType: Equatable {
    var base: String
    var parameters: [String: String]

    init(_ raw: String?) {
        let parts = (raw ?? "").split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        base = parts.first ?? ""
        var parameters: [String: String] = [:]
        for part in parts.dropFirst() {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2 { parameters[pair[0]] = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        }
        self.parameters = parameters
    }

    /// A feed to open. `type=entry` is a single book's Atom entry, which is the book, not a shelf.
    var isCatalog: Bool {
        (base == "application/atom+xml" && parameters["type"] != "entry") || base == "application/opds+json"
    }

    var isOpenSearchDescription: Bool { base == "application/opensearchdescription+xml" }
}

/// A link as either format writes it, before it is sorted into navigation, downloads and covers.
struct CatalogRawLink {
    var href: String
    /// Empty when the link has no rel; Atom then reads it as `alternate`.
    var rels: [String]
    var type: String?
    var title: String?
    var length: Int?
    var width: Double?

    func has(_ rel: String) -> Bool { rels.contains(rel) }
}

enum CatalogLinks {
    /// The href resolved against the feed it came from. `data:` URLs are skipped: Gutenberg inlines icons
    /// that way and they are never a cover worth showing.
    static func resolve(_ href: String, against base: URL) -> URL? {
        let href = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !href.isEmpty, !href.lowercased().hasPrefix("data:"),
              let url = URL(string: href, relativeTo: base) else { return nil }
        return URL(string: secured(url.absoluteString))
    }

    /// A search template resolved against its feed. The `{…}` expressions are swapped out first, because
    /// URL parsing would percent-encode the braces or refuse the string.
    static func resolveTemplate(_ template: String, against base: URL) -> String? {
        var expressions: [String] = []
        var masked = ""
        var index = template.startIndex
        while index < template.endIndex {
            if template[index] == "{", let close = template[index...].firstIndex(of: "}") {
                masked += "gatefoldexpr\(expressions.count)z"
                expressions.append(String(template[index...close]))
                index = template.index(after: close)
            } else {
                masked.append(template[index])
                index = template.index(after: index)
            }
        }
        guard var resolved = resolve(masked, against: base)?.absoluteString else { return nil }
        for (number, expression) in expressions.enumerated() {
            resolved = resolved.replacingOccurrences(of: "gatefoldexpr\(number)z", with: expression)
        }
        return resolved
    }

    /// Project Gutenberg still advertises `http://m.gutenberg.org/` in its OpenSearch description. App Transport
    /// Security refuses plain http, and the mobile host only redirects, so both go to `https://www.gutenberg.org/`.
    static func secured(_ url: String) -> String {
        guard let schemeEnd = url.range(of: "://") else { return url }
        let scheme = url[..<schemeEnd.lowerBound].lowercased()
        let rest = url[schemeEnd.upperBound...]
        let authorityEnd = rest.firstIndex { "/?#".contains($0) } ?? rest.endIndex
        let authority = rest[..<authorityEnd].lowercased()
        let host = authority.split(separator: ":", maxSplits: 1).first.map(String.init) ?? authority
        guard ["gutenberg.org", "www.gutenberg.org", "m.gutenberg.org"].contains(host),
              scheme == "http" || host == "m.gutenberg.org" else { return url }
        return "https://www.gutenberg.org" + rest[authorityEnd...]
    }

    /// The feed's own search, preferring a template it can fill in now over a description to fetch.
    static func search(in links: [CatalogRawLink], base: URL) -> CatalogSearch? {
        var description: URL?
        for link in links where link.has("search") {
            let type = CatalogMediaType(link.type)
            if type.isOpenSearchDescription {
                if description == nil { description = resolve(link.href, against: base) }
            } else if link.href.contains("{"), type.base.isEmpty || type.isCatalog,
                      let template = resolveTemplate(link.href, against: base) {
                return .template(template)
            }
        }
        return description.map(CatalogSearch.description)
    }

    static func first(_ rels: Set<String>, in links: [CatalogRawLink], base: URL) -> URL? {
        for link in links where link.rels.contains(where: rels.contains) {
            if let url = resolve(link.href, against: base) { return url }
        }
        return nil
    }

    /// How strongly a catalog-typed link with this rel means "open this": OPDS says `subsection`, Atom's
    /// default (no rel) is `alternate`, which calibre and Calibre-Web use for every shelf. `related`, `self`,
    /// `start`, `up` and paging links are not this entry's contents.
    private static func navigationRank(_ rel: String) -> Int? {
        switch rel {
        case "subsection", "collection": return 0
        case "", "alternate": return 1
        case "http://opds-spec.org/featured", "http://opds-spec.org/recommended", "http://opds-spec.org/shelf", "http://opds-spec.org/subscriptions":
            return 2
        default:
            return rel.hasPrefix("http://opds-spec.org/sort/") ? 2 : nil
        }
    }

    /// An entry's links sorted into the feed it opens, its downloads and its cover images.
    static func entryParts(_ links: [CatalogRawLink], base: URL) -> (navigation: URL?, acquisitions: [CatalogAcquisition], cover: URL?, thumbnail: URL?) {
        var navigation: (url: URL, rank: Int)?
        var acquisitions: [CatalogAcquisition] = []
        var cover: URL?
        var thumbnail: URL?
        for link in links {
            let rels = link.rels.isEmpty ? [""] : link.rels
            let type = CatalogMediaType(link.type)
            // Plain Atom feeds (Standard Ebooks' open feed) put the files in enclosures.
            if let rel = rels.first(where: { $0.hasPrefix(CatalogLinkRel.acquisition) || $0 == "enclosure" }) {
                guard let url = resolve(link.href, against: base) else { continue }
                acquisitions.append(CatalogAcquisition(url: url, mediaType: type.base, rel: rel, length: link.length, title: link.title))
            } else if rels.contains(where: CatalogLinkRel.thumbnails.contains) {
                if thumbnail == nil { thumbnail = resolve(link.href, against: base) }
            } else if rels.contains(where: CatalogLinkRel.covers.contains) {
                if cover == nil { cover = resolve(link.href, against: base) }
            } else if type.isCatalog, let rank = rels.compactMap(navigationRank).min(),
                      navigation == nil || rank < navigation!.rank,
                      let url = resolve(link.href, against: base) {
                navigation = (url, rank)
            }
        }
        return (navigation?.url, acquisitions, cover, thumbnail)
    }

    /// Readable text from a summary: tags dropped (HTML summaries arrive as text), whitespace collapsed.
    static func plainText(_ raw: String?, html: Bool) -> String? {
        guard let raw else { return nil }
        var text = raw
        if html {
            text = ""
            var inTag = false
            for character in raw {
                if character == "<" {
                    inTag = true
                    text.append(" ")
                } else if character == ">", inTag {
                    inTag = false
                } else if !inTag {
                    text.append(character)
                }
            }
        }
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }
}
