import Foundation

/// A parsed XHTML content document that resolves CFI paths to text positions and back,
/// following the EPUB CFI rules epub.js (PocketBook's web reader) uses: element children take
/// even indices, runs of text between them take odd indices, and offsets count UTF-16 units.
///
/// Positions are `TextPoint`s: an offset into the concatenated text of `<body>`. That makes
/// "same place?" checks, progression and text-quote matching work without a WebView.
public struct CFIDocument: Sendable {
    public struct TextPoint: Sendable, Hashable, Comparable {
        /// UTF-16 offset into the concatenated text of `<body>`.
        public var textOffset: Int
        public init(textOffset: Int) { self.textOffset = textOffset }
        public static func < (a: TextPoint, b: TextPoint) -> Bool { a.textOffset < b.textOffset }
    }

    public struct Path: Sendable, Hashable {
        public var steps: [EPUBCFI.Step]
        public var offset: Int?
    }

    public enum ParseError: Error { case malformed(String) }

    struct Node: Sendable {
        var isElement: Bool
        var id: String?
        var parent: Int?
        var children: [Int] = []
        /// Body-text offsets covered by this node (both 0 outside `<body>`).
        var textStart = 0
        var textEnd = 0
    }

    let nodes: [Node]
    let root: Int
    let text: [UInt16]

    /// Total UTF-16 length of the body text.
    public var textLength: Int { text.count }

    public init(xhtml: Data) throws {
        let source = String(decoding: xhtml, as: UTF8.self)
        let builder = TreeBuilder()
        let parser = XMLParser(data: Data(HTMLEntities.numericize(source).utf8))
        parser.delegate = builder
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), let root = builder.root else {
            throw ParseError.malformed(parser.parserError?.localizedDescription ?? "empty document")
        }
        nodes = builder.nodes
        self.root = root
        text = builder.text
    }

    // MARK: CFI → text

    /// Resolves the in-document part of `cfi`. Returns nil when the path does not exist here.
    public func resolve(_ cfi: EPUBCFI) -> TextPoint? {
        resolve(steps: cfi.documentSteps, offset: cfi.offset)
    }

    public func resolve(steps: [EPUBCFI.Step], offset: Int?) -> TextPoint? {
        var current = root
        for (n, step) in steps.enumerated() {
            let elements = nodes[current].children.filter { nodes[$0].isElement }
            if step.index % 2 == 0 {
                let ordinal = step.index / 2
                var next: Int? = elements.indices.contains(ordinal - 1) ? elements[ordinal - 1] : nil
                if let id = step.assertion, next.map({ nodes[$0].id }) != id {
                    next = nodes.indices.first { nodes[$0].isElement && nodes[$0].id == id } ?? next
                }
                guard let found = next else { return nil }
                current = found
            } else {
                guard n == steps.count - 1 else { return nil }
                let k = step.index / 2 // number of element siblings before this text run
                guard k <= elements.count else { return nil }
                let start = k == 0 ? nodes[current].textStart : nodes[elements[k - 1]].textEnd
                let end = k < elements.count ? nodes[elements[k]].textStart : nodes[current].textEnd
                let local = offset ?? 0
                guard local >= 0, local <= end - start else { return nil }
                return TextPoint(textOffset: start + local)
            }
        }
        return TextPoint(textOffset: nodes[current].textStart)
    }

    public func progression(of cfi: EPUBCFI) -> Double? {
        guard let point = resolve(cfi) else { return nil }
        return textLength == 0 ? 0 : Double(point.textOffset) / Double(textLength)
    }

    public func text(from point: TextPoint, count: Int) -> String {
        let lower = max(0, min(point.textOffset, text.count))
        let upper = min(text.count, lower + max(0, count))
        return String(decoding: text[lower..<upper], as: UTF16.self)
    }

    /// The occurrence of `quote` nearest `hint`; used when an anchor no longer resolves.
    public func find(_ quote: String, nearTextOffset hint: Int) -> TextPoint? {
        let needle = Array(quote.utf16)
        guard !needle.isEmpty, needle.count <= text.count else { return nil }
        var best: Int?
        var i = 0
        while i <= text.count - needle.count {
            if text[i] == needle[0], Array(text[i..<(i + needle.count)]) == needle {
                if best == nil || abs(i - hint) < abs(best! - hint) { best = i }
            }
            i += 1
        }
        return best.map(TextPoint.init(textOffset:))
    }

    // MARK: text → CFI

    /// The CFI path (relative to the root element) of body-text offset `textOffset`.
    public func cfiPath(at textOffset: Int) -> Path? {
        guard textOffset >= 0, textOffset <= text.count else { return nil }
        // Prefer the text node that starts at the offset over the one that ends there.
        let textNodes = nodes.indices.filter { !nodes[$0].isElement && nodes[$0].textEnd > nodes[$0].textStart }
        guard let node = textNodes.first(where: { nodes[$0].textStart <= textOffset && textOffset < nodes[$0].textEnd })
            ?? textNodes.last(where: { nodes[$0].textEnd == textOffset }) else { return nil }

        let parent = nodes[node].parent!
        let siblings = nodes[parent].children
        let position = siblings.firstIndex(of: node)!
        let elementsBefore = siblings[..<position].filter { nodes[$0].isElement }.count
        // Text siblings in the same run (after the last element before this node) add to the offset.
        var runStart = position
        while runStart > 0, !nodes[siblings[runStart - 1]].isElement { runStart -= 1 }
        let precedingInRun = siblings[runStart..<position].reduce(0) { $0 + nodes[$1].textEnd - nodes[$1].textStart }

        var steps = [EPUBCFI.Step(2 * elementsBefore + 1)]
        var child = parent
        while child != root, let up = nodes[child].parent {
            let ordinal = nodes[up].children.filter { nodes[$0].isElement }.firstIndex(of: child)! + 1
            steps.insert(EPUBCFI.Step(2 * ordinal, assertion: nodes[child].id), at: 0)
            child = up
        }
        return Path(steps: steps, offset: precedingInRun + textOffset - nodes[node].textStart)
    }

    public func cfiPath(atProgression progression: Double) -> Path? {
        let clamped = min(1, max(0, progression))
        return cfiPath(at: min(text.count, Int((clamped * Double(text.count)).rounded(.down))))
    }
}

private final class TreeBuilder: NSObject, XMLParserDelegate {
    var nodes: [CFIDocument.Node] = []
    var root: Int?
    var text: [UInt16] = []
    private var stack: [Int] = []
    private var bodyDepth: Int?
    private var pendingText: Int?

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        pendingText = nil
        if name == "body", bodyDepth == nil { bodyDepth = stack.count }
        let index = nodes.count
        nodes.append(.init(isElement: true, id: attributes["id"] ?? attributes["xml:id"], parent: stack.last, textStart: text.count))
        if let parent = stack.last { nodes[parent].children.append(index) } else { root = index }
        stack.append(index)
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        pendingText = nil
        let index = stack.removeLast()
        nodes[index].textEnd = text.count
        if bodyDepth == stack.count { bodyDepth = nil }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { append(string) }
    func parser(_ parser: XMLParser, foundIgnorableWhitespace string: String) { append(string) }
    func parser(_ parser: XMLParser, foundCDATA data: Data) { append(String(decoding: data, as: UTF8.self)) }

    private func append(_ string: String) {
        guard let parent = stack.last else { return }
        let inBody = bodyDepth != nil
        let units = inBody ? Array(string.utf16) : []
        if let open = pendingText {
            text.append(contentsOf: units)
            nodes[open].textEnd = text.count
            return
        }
        let index = nodes.count
        nodes.append(.init(isElement: false, id: nil, parent: parent, textStart: text.count))
        text.append(contentsOf: units)
        nodes[index].textEnd = text.count
        nodes[parent].children.append(index)
        pendingText = index
    }
}
