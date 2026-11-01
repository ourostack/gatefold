import Foundation

/// The OPF reading order, enough to turn a CFI's package steps into a resource href and back.
public struct SpineMap: Sendable, Hashable {
    public struct Item: Sendable, Hashable {
        public var idref: String
        /// Path from the publication root, percent-decoded, no leading slash (`OEBPS/ch1.xhtml`).
        public var href: String
        public init(idref: String, href: String) {
            self.idref = idref
            self.href = href
        }
    }

    /// The CFI step of `<spine>` inside `<package>` (2 × its 1-based element position; usually 6).
    public var spineStep: Int
    public var items: [Item]

    public init(spineStep: Int, items: [Item]) {
        self.spineStep = spineStep
        self.items = items
    }

    public enum ParseError: Error { case malformed(String) }

    /// Reads `opf` (the package document) located at `opfPath` inside the publication.
    public init(opf: Data, opfPath: String) throws {
        let reader = OPFReader()
        let parser = XMLParser(data: opf)
        parser.delegate = reader
        parser.shouldProcessNamespaces = true
        guard parser.parse(), let step = reader.spineStep else {
            throw ParseError.malformed(parser.parserError?.localizedDescription ?? "no <spine> in package")
        }
        let base = URL(string: "https://package.invalid/")!
            .appendingPathComponent(opfPath)
        spineStep = step
        items = reader.itemrefs.compactMap { idref in
            guard let raw = reader.manifest[idref],
                  let url = URL(string: raw, relativeTo: base)?.standardized else { return nil }
            return Item(idref: idref, href: String(url.path.drop(while: { $0 == "/" })))
        }
    }

    /// The href a CFI points into. A matching idref assertion wins over the step index.
    public func href(for cfi: EPUBCFI) -> String? {
        if let id = cfi.spineItemID, let item = items.first(where: { $0.idref == id }) { return item.href }
        guard let index = cfi.spineIndex, items.indices.contains(index) else { return nil }
        return items[index].href
    }

    public func index(ofHref href: String) -> Int? {
        let wanted = Self.normalize(href)
        return items.firstIndex { Self.normalize($0.href) == wanted }
    }

    static func normalize(_ href: String) -> String {
        var s = href
        if let hash = s.firstIndex(of: "#") { s = String(s[..<hash]) }
        s = s.removingPercentEncoding ?? s
        return String(s.drop(while: { $0 == "/" }))
    }
}

private final class OPFReader: NSObject, XMLParserDelegate {
    var depth = 0
    var packageChildren = 0
    var spineStep: Int?
    var manifest: [String: String] = [:]
    var itemrefs: [String] = []

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        depth += 1
        if depth == 2 {
            packageChildren += 1
            if name == "spine" { spineStep = packageChildren * 2 }
        }
        if name == "item", let id = attributes["id"], let href = attributes["href"] { manifest[id] = href }
        if name == "itemref", let idref = attributes["idref"] { itemrefs.append(idref) }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        depth -= 1
    }
}
