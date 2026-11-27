import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Reads a catalog page as whatever it turns out to be: OPDS 2.0 JSON when it starts with `{`, otherwise
/// Atom (OPDS 1.2 or a plain feed). Servers don't reliably label which they sent.
public enum CatalogParser {
    public static func parse(data: Data, from feedURL: URL) throws -> CatalogFeed {
        let start = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
        if start.first(where: { !" \t\r\n".utf8.contains($0) }) == UInt8(ascii: "{") {
            return try OPDS2Reader.feed(from: Data(start), base: feedURL)
        }
        return try AtomReader.feed(from: data, base: feedURL)
    }
}

/// An OpenSearch description, fetched when a catalog's search link points at one instead of a template.
public enum OpenSearchDescription {
    /// The catalog search template it offers, resolved against the description's own URL. Only Atom and
    /// OPDS 2 results count; the HTML and suggestion templates lead to pages the app can't read.
    public static func parse(_ data: Data, from url: URL) -> CatalogSearch? {
        let reader = OpenSearchReader()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = reader
        guard parser.parse() else { return nil }
        for wanted in ["application/atom+xml", "application/opds+json"] {
            for candidate in reader.urls where CatalogMediaType(candidate.type).base == wanted {
                guard candidate.rel == nil || candidate.rel == "results" else { continue }
                if let template = CatalogLinks.resolveTemplate(candidate.template, against: url) {
                    return .template(template)
                }
            }
        }
        return nil
    }
}

private final class OpenSearchReader: NSObject, XMLParserDelegate {
    var urls: [(type: String?, template: String, rel: String?)] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if elementName == "Url", let template = attributes["template"] {
            urls.append((attributes["type"], template, attributes["rel"]))
        }
    }
}

// MARK: - Atom

private final class AtomReader: NSObject, XMLParserDelegate {
    private static let atomNamespace = "http://www.w3.org/2005/Atom"
    private static let mediaNamespace = "http://search.yahoo.com/mrss/"

    struct Entry {
        var id: String?
        var title = ""
        var summary: String?
        var summaryIsHTML = false
        var content: String?
        var contentIsHTML = false
        var authors: [String] = []
        var links: [CatalogRawLink] = []
        var mediaThumbnail: String?
    }

    private enum Field { case feedTitle, title, id, summary, content, authorName }

    private var stack: [String] = []
    private var root: String?
    private var feedTitle = ""
    private var feedLinks: [CatalogRawLink] = []
    private var entries: [Entry] = []
    private var entry: Entry?
    private var field: (kind: Field, depth: Int)?
    private var text = ""

    static func feed(from data: Data, base: URL) throws -> CatalogFeed {
        let reader = AtomReader()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = reader
        guard parser.parse() else { throw CatalogError.unreadable }
        guard let root = reader.root, root == "feed" || root == "entry" else { throw CatalogError.notACatalog }
        let entries = reader.entries.map { catalogEntry($0, base: base) }
        return CatalogFeed(
            title: CatalogLinks.plainText(reader.feedTitle, html: false) ?? entries.first?.title ?? "",
            entries: entries,
            next: CatalogLinks.first(["next"], in: reader.feedLinks, base: base),
            previous: CatalogLinks.first(["prev", "previous"], in: reader.feedLinks, base: base),
            search: CatalogLinks.search(in: reader.feedLinks, base: base)
        )
    }

    private static func catalogEntry(_ raw: Entry, base: URL) -> CatalogEntry {
        let parts = CatalogLinks.entryParts(raw.links, base: base)
        let summary = CatalogLinks.plainText(raw.summary, html: raw.summaryIsHTML)
            ?? CatalogLinks.plainText(raw.content, html: raw.contentIsHTML)
        let title = CatalogLinks.plainText(raw.title, html: false) ?? ""
        let thumbnail = parts.thumbnail ?? raw.mediaThumbnail.flatMap { CatalogLinks.resolve($0, against: base) }
        let id = raw.id.flatMap { CatalogLinks.plainText($0, html: false) }
            ?? parts.navigation?.absoluteString ?? parts.acquisitions.first?.url.absoluteString ?? title
        let authors = raw.authors.compactMap { CatalogLinks.plainText($0, html: false) }
        return CatalogEntry(
            id: id, title: title, author: authors.isEmpty ? nil : authors.joined(separator: ", "), summary: summary,
            navigation: parts.navigation, acquisitions: parts.acquisitions, cover: parts.cover, thumbnail: thumbnail
        )
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        // Feeds written without a namespace are still read as Atom.
        let isAtom = namespaceURI == nil || namespaceURI == "" || namespaceURI == Self.atomNamespace
        let parent = stack.last
        stack.append(isAtom ? elementName : "\(namespaceURI ?? ""):\(elementName)")
        if stack.count == 1 { root = isAtom ? elementName : nil }

        if field != nil {
            // Inside xhtml content: keep a gap between elements so paragraphs don't run together.
            text += " "
            return
        }
        if namespaceURI == Self.mediaNamespace, elementName == "thumbnail", entry != nil, entry?.mediaThumbnail == nil {
            entry?.mediaThumbnail = attributes["url"]
            return
        }
        guard isAtom else { return }
        let inEntry = parent == "entry" && entry != nil
        switch elementName {
        case "entry" where parent == nil || parent == "feed":
            entry = Entry()
        case "link" where parent == "feed" || inEntry:
            guard let href = attributes["href"] else { return }
            let rel = attributes["rel"]?.trimmingCharacters(in: .whitespaces) ?? ""
            let link = CatalogRawLink(
                href: href, rels: rel.isEmpty ? [] : [rel], type: attributes["type"], title: attributes["title"],
                length: attributes["length"].flatMap { Int($0) }
            )
            if inEntry { entry?.links.append(link) } else { feedLinks.append(link) }
        case "title" where parent == "feed":
            begin(.feedTitle)
        case "title" where inEntry:
            begin(.title)
        case "id" where inEntry:
            begin(.id)
        case "summary" where inEntry:
            entry?.summaryIsHTML = attributes["type"] == "html"
            begin(.summary)
        case "content" where inEntry:
            entry?.contentIsHTML = attributes["type"] == "html"
            begin(.content)
        case "name" where parent == "author" && entry != nil && stack.dropLast(2).last == "entry":
            begin(.authorName)
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if let field, field.depth == stack.count {
            switch field.kind {
            case .feedTitle: feedTitle = text
            case .title: entry?.title = text
            case .id: entry?.id = text
            case .summary: entry?.summary = text
            case .content: entry?.content = text
            case .authorName: entry?.authors.append(text)
            }
            self.field = nil
        } else if field != nil {
            text += " "
        }
        if stack.last == "entry", field == nil, let finished = entry, stack.count <= 2 {
            entries.append(finished)
            entry = nil
        }
        stack.removeLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if field != nil { text += string }
    }

    func parser(_ parser: XMLParser, foundCDATA block: Data) {
        if field != nil { text += String(decoding: block, as: UTF8.self) }
    }

    private func begin(_ kind: Field) {
        field = (kind, stack.count)
        text = ""
    }
}

// MARK: - OPDS 2.0

private enum OPDS2Reader {
    static func feed(from data: Data, base: URL) throws -> CatalogFeed {
        let document: OPDS2Feed
        do {
            document = try JSONDecoder().decode(OPDS2Feed.self, from: data)
        } catch {
            throw CatalogError.unreadable
        }
        guard document.metadata != nil || !document.links.isEmpty else { throw CatalogError.notACatalog }
        var entries: [CatalogEntry] = []
        func add(navigation: [OPDS2Link], publications: [OPDS2Publication]) {
            entries += navigation.compactMap { navigationEntry($0, base: base) }
            entries += publications.map { publicationEntry($0, base: base) }
        }
        add(navigation: document.navigation, publications: document.publications)
        // Groups are shelves within the page (Featured, Popular); they read as more of the same list.
        for group in document.groups {
            add(navigation: group.navigation, publications: group.publications)
        }
        let links = document.links.map(\.raw)
        return CatalogFeed(
            title: document.metadata?.title ?? "",
            entries: entries,
            next: CatalogLinks.first(["next"], in: links, base: base),
            previous: CatalogLinks.first(["prev", "previous"], in: links, base: base),
            search: search(in: document.links, base: base)
        )
    }

    private static func navigationEntry(_ link: OPDS2Link, base: URL) -> CatalogEntry? {
        guard let url = CatalogLinks.resolve(link.href, against: base) else { return nil }
        return CatalogEntry(
            id: url.absoluteString, title: link.title ?? url.lastPathComponent, author: nil, summary: nil,
            navigation: url, acquisitions: [], cover: nil, thumbnail: nil
        )
    }

    private static func publicationEntry(_ publication: OPDS2Publication, base: URL) -> CatalogEntry {
        let parts = CatalogLinks.entryParts(publication.links.map(\.raw), base: base)
        let metadata = publication.metadata
        let title = metadata?.title ?? ""
        // OPDS 2 lists images without saying which is which: the widest is the cover and the narrowest the
        // thumbnail. Without widths, the first is the cover and the last the thumbnail, as calibre orders them.
        let images = publication.images.compactMap { image in
            CatalogLinks.resolve(image.href, against: base).map { (url: $0, width: image.width ?? 0) }
        }
        let cover = images.max { $0.width < $1.width }?.url
        let smallest = images.reversed().min { $0.width < $1.width }?.url
        let thumbnail = smallest != cover ? smallest : nil
        let selfLink = publication.links.first { $0.rels.contains("self") }.flatMap { CatalogLinks.resolve($0.href, against: base) }
        let id = metadata?.identifier ?? selfLink?.absoluteString ?? parts.acquisitions.first?.url.absoluteString ?? title
        let authors = metadata?.authors ?? []
        return CatalogEntry(
            id: id, title: title, author: authors.isEmpty ? nil : authors.joined(separator: ", "),
            summary: CatalogLinks.plainText(metadata?.description, html: true),
            navigation: parts.navigation, acquisitions: parts.acquisitions,
            cover: parts.cover ?? cover, thumbnail: parts.thumbnail ?? thumbnail
        )
    }

    /// OPDS 2 marks a URL template with `templated: true` (`/search{?query}`); an OpenSearch description can
    /// also be linked as in OPDS 1.
    private static func search(in links: [OPDS2Link], base: URL) -> CatalogSearch? {
        for link in links where link.rels.contains("search") && link.templated {
            if let template = CatalogLinks.resolveTemplate(link.href, against: base) { return .template(template) }
        }
        return CatalogLinks.search(in: links.filter { !$0.templated }.map(\.raw), base: base)
    }
}

/// Decodes leniently: a field of an unexpected shape is dropped, and one malformed link or publication is
/// skipped, rather than failing the whole page.
private struct Lossy<Value: Decodable>: Decodable {
    var value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

private extension KeyedDecodingContainer {
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }

    func lossyArray<T: Decodable>(_ type: T.Type, _ key: Key) -> [T] {
        (lenient([Lossy<T>].self, key) ?? []).compactMap(\.value)
    }
}

private struct OPDS2Feed: Decodable {
    var metadata: OPDS2Metadata?
    var links: [OPDS2Link]
    var navigation: [OPDS2Link]
    var publications: [OPDS2Publication]
    var groups: [OPDS2Group]

    enum CodingKeys: String, CodingKey { case metadata, links, navigation, publications, groups }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metadata = container.lenient(OPDS2Metadata.self, .metadata)
        links = container.lossyArray(OPDS2Link.self, .links)
        navigation = container.lossyArray(OPDS2Link.self, .navigation)
        publications = container.lossyArray(OPDS2Publication.self, .publications)
        groups = container.lossyArray(OPDS2Group.self, .groups)
    }
}

private struct OPDS2Group: Decodable {
    var navigation: [OPDS2Link]
    var publications: [OPDS2Publication]

    enum CodingKeys: String, CodingKey { case navigation, publications }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        navigation = container.lossyArray(OPDS2Link.self, .navigation)
        publications = container.lossyArray(OPDS2Publication.self, .publications)
    }
}

private struct OPDS2Publication: Decodable {
    var metadata: OPDS2Metadata?
    var links: [OPDS2Link]
    var images: [OPDS2Link]

    enum CodingKeys: String, CodingKey { case metadata, links, images }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metadata = container.lenient(OPDS2Metadata.self, .metadata)
        links = container.lossyArray(OPDS2Link.self, .links)
        images = container.lossyArray(OPDS2Link.self, .images)
    }
}

private struct OPDS2Metadata: Decodable {
    var title: String?
    var identifier: String?
    var description: String?
    var authors: [String]

    enum CodingKeys: String, CodingKey { case title, identifier, description, author }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = container.lenient(OPDS2Text.self, .title)?.value
        identifier = container.lenient(String.self, .identifier)
        description = container.lenient(String.self, .description)
        authors = container.lenient(OPDS2Contributors.self, .author)?.names ?? []
    }
}

/// A string, or a language map such as `{"en": "…", "fr": "…"}`; English first, then any, in a stable order.
private struct OPDS2Text: Decodable {
    var value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
            return
        }
        let map = try container.decode([String: String].self)
        guard let chosen = map["en"] ?? map["und"] ?? map.keys.sorted().first.flatMap({ map[$0] }) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Empty language map")
        }
        value = chosen
    }
}

/// A contributor is a name, an object with a name, or a list of either.
private struct OPDS2Contributors: Decodable {
    var names: [String]

    private struct Named: Decodable { var name: OPDS2Text }

    private struct One: Decodable {
        var name: String?
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            name = (try? container.decode(OPDS2Text.self))?.value ?? (try? container.decode(Named.self))?.name.value
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let list = try? container.decode([One].self) {
            names = list.compactMap(\.name)
        } else {
            names = [try container.decode(One.self).name].compactMap { $0 }
        }
    }
}

private struct OPDS2Link: Decodable {
    var href: String
    var type: String?
    var rels: [String]
    var title: String?
    var templated: Bool
    var width: Double?

    enum CodingKeys: String, CodingKey { case href, type, rel, title, templated, width }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        href = try container.decode(String.self, forKey: .href)
        type = container.lenient(String.self, .type)
        // `rel` may be one string or a list of them.
        rels = container.lenient([String].self, .rel) ?? container.lenient(String.self, .rel).map { [$0] } ?? []
        title = container.lenient(String.self, .title)
        templated = container.lenient(Bool.self, .templated) ?? false
        width = container.lenient(Double.self, .width)
    }

    var raw: CatalogRawLink {
        CatalogRawLink(href: href, rels: rels, type: type, title: title, length: nil, width: width)
    }
}
