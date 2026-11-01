import Foundation

/// The book's table of contents, keyed for "which chapter is this page in?". The contents name chapters
/// the way the publisher meant; a heading scraped from the page can be a caption or a quotation.
public struct ContentsIndex: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var title: String
        /// The resource, without a fragment or leading slash.
        public var href: String
        /// The element id the entry points at, when it points inside the resource.
        public var fragment: String?
        public var level: Int

        public init(title: String, href: String, fragment: String?, level: Int) {
            self.title = title
            self.href = ContentsIndex.normalize(href)
            self.fragment = fragment.flatMap { $0.isEmpty ? nil : $0 }
            self.level = level
        }
    }

    public let entries: [Entry]
    private let order: [String: Int]

    public init(entries: [Entry], readingOrder: [String]) {
        self.entries = entries
        var order: [String: Int] = [:]
        for (i, href) in readingOrder.enumerated() where order[Self.normalize(href)] == nil { order[Self.normalize(href)] = i }
        self.order = order
    }

    /// The anchors in `href` the contents point at, for the web view to look for above the first line.
    public func fragments(in href: String) -> [String] {
        let key = Self.normalize(href)
        return entries.filter { $0.href == key }.compactMap(\.fragment)
    }

    /// The chapter the page is in. `precedingFragment` is the last contents anchor at or above the
    /// first line on screen (nil when none of the file's anchors are above it).
    public func title(href: String, precedingFragment: String?) -> String? {
        let key = Self.normalize(href)
        if let fragment = precedingFragment, let entry = entries.last(where: { $0.href == key && $0.fragment == fragment }) {
            return entry.title
        }
        if let whole = entries.first(where: { $0.href == key && $0.fragment == nil }) {
            return whole.title
        }
        // Above the file's first chapter anchor: still in whatever chapter came before.
        guard let here = order[key] else { return nil }
        let before = entries.enumerated().filter { _, e in order[e.href].map { $0 < here } ?? false }
        guard let latestFile = before.map({ order[$0.element.href]! }).max() else { return nil }
        return before.last { order[$0.element.href] == latestFile }?.element.title
    }

    /// Whether two hrefs name the same resource (ignoring a leading slash, fragment and escaping).
    public static func sameResource(_ a: String, _ b: String) -> Bool { normalize(a) == normalize(b) }

    static func normalize(_ href: String) -> String {
        var s = href
        if let hash = s.firstIndex(of: "#") { s = String(s[..<hash]) }
        s = s.removingPercentEncoding ?? s
        return String(s.drop(while: { $0 == "/" }))
    }
}

/// Converts "this far into this resource" into "this far into the book" on Readium's scale, so a
/// place from another device compares fairly with ours.
public enum ReadingScale {
    /// `resourceStarts[i]` is the total progression where resource `i` begins.
    public static func totalProgression(resourceIndex: Int, progression: Double, resourceStarts: [Double]) -> Double? {
        guard resourceStarts.indices.contains(resourceIndex) else { return nil }
        let start = resourceStarts[resourceIndex]
        let end = resourceIndex + 1 < resourceStarts.count ? resourceStarts[resourceIndex + 1] : 1
        return start + min(1, max(0, progression)) * max(0, end - start)
    }
}

/// Titles as a shelf shows them: Gutenberg-style subtitles ("Frankenstein; or, The Modern
/// Prometheus") are the book's business, not the shelf's.
public enum BookTitle {
    public static func short(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let cut = trimmed.firstIndex(where: { $0 == ";" || $0 == ":" }) else { return trimmed }
        let head = trimmed[..<cut].trimmingCharacters(in: .whitespaces)
        // A one-letter main title ("Q: …") says too little on its own.
        return head.count >= 3 ? head : trimmed
    }
}
