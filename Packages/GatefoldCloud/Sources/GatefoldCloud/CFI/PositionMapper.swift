import Foundation

/// A reading location in the shape Readium's `Locator` uses, without depending on Readium.
public struct BookLocation: Sendable, Hashable {
    /// Container-relative path of the resource, without a leading slash.
    public var href: String
    /// Progress inside the resource, 0...1.
    public var progression: Double?
    /// Progress through the whole book, 0...1.
    public var totalProgression: Double?
    /// Full `epubcfi(...)`, when known.
    public var cfi: String?
    /// Text right after the location, for display and for re-finding it.
    public var textAfter: String?
    /// The first words at the location (the reader's first words on screen). When present, the CFI
    /// points at them exactly instead of at a page boundary's approximate progression.
    public var textHighlight: String?

    public init(href: String, progression: Double? = nil, totalProgression: Double? = nil, cfi: String? = nil, textAfter: String? = nil,
                textHighlight: String? = nil) {
        let trimmed = href.hasPrefix("/") ? String(href.dropFirst()) : href
        self.href = trimmed.removingPercentEncoding ?? trimmed
        self.progression = progression
        self.totalProgression = totalProgression
        self.cfi = cfi
        self.textAfter = textAfter
        self.textHighlight = textHighlight
    }
}

/// Maps between where the reader is (`BookLocation`) and what the Cloud stores (`ReadingPosition`),
/// using the book's own spine and XHTML so the CFI is exact.
public actor PositionMapper {
    public nonisolated let spine: SpineMap
    private let load: @Sendable (String) async throws -> Data
    private var documents: [String: CFIDocument] = [:]

    /// `load` returns a resource's bytes by container-relative href.
    public init(spine: SpineMap, load: @escaping @Sendable (String) async throws -> Data) {
        self.spine = spine
        self.load = load
    }

    /// The Cloud position for a reader location. Without a resolvable resource, a percent-only position.
    public func position(for location: BookLocation, at date: Date) async -> ReadingPosition? {
        let total = location.totalProgression ?? 0
        guard let index = spine.index(ofHref: location.href) else {
            return ReadingPosition(cfi: nil, progression: location.progression, totalProgression: total, updated: date)
        }
        if let raw = location.cfi, let cfi = EPUBCFI(raw), cfi.spineIndex == index {
            return ReadingPosition(cfi: cfi.description, progression: location.progression, totalProgression: total, updated: date)
        }
        guard let here = await document(location.href) else {
            return ReadingPosition(cfi: nil, progression: location.progression, totalProgression: total, updated: date)
        }
        var found = Self.anchoredPath(in: here, location: location).map { (index: index, path: $0, progression: location.progression) }
        // Just after a turn into the next resource, the reader can still name the old one while the
        // words on screen come from the new one: look for them at the top of the next resource.
        // Only from the last stretch of a resource, and only words near the top of the next one: the
        // same few words deeper in the next chapter are a coincidence, not the page on screen.
        if found == nil, location.textHighlight != nil, (location.progression ?? 0) >= 0.8, index + 1 < spine.items.count,
           let next = await document(spine.items[index + 1].href) {
            var top = location
            top.progression = 0
            found = Self.anchoredPath(in: next, location: top, within: 400).map { (index: index + 1, path: $0, progression: 0) }
        }
        guard let place = found ?? here.cfiPath(atProgression: location.progression ?? 0).map({ (index: index, path: $0, progression: location.progression) }) else {
            return ReadingPosition(cfi: nil, progression: location.progression, totalProgression: total, updated: date)
        }
        let cfi = EPUBCFI.point(spineStep: spine.spineStep, spineIndex: place.index, spineItemID: spine.items[place.index].idref,
                                documentSteps: place.path.steps, offset: place.path.offset)
        return ReadingPosition(cfi: cfi.description, progression: place.progression, totalProgression: total, updated: date)
    }

    /// Where to open for a Cloud position. Nil when it has no usable CFI; seek by `totalProgression` then.
    public func location(for position: ReadingPosition) async -> BookLocation? {
        guard let cfi = position.parsedCFI, let href = spine.href(for: cfi) else { return nil }
        var location = BookLocation(href: href, progression: nil, totalProgression: position.totalProgression, cfi: cfi.description)
        if let document = await document(href), let point = document.resolve(cfi) {
            location.progression = document.progression(of: cfi)
            location.textAfter = document.text(from: point, count: 200).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            location.progression = position.progression
        }
        return location
    }

    /// The path of the first words on screen, searched near where the progression points.
    /// `within` limits how far from the hint a match may be, in characters.
    static func anchoredPath(in document: CFIDocument, location: BookLocation, within: Int? = nil) -> CFIDocument.Path? {
        guard let quote = location.textHighlight?.trimmingCharacters(in: .whitespacesAndNewlines), quote.count >= 8 else { return nil }
        let hint = Int((min(1, max(0, location.progression ?? 0)) * Double(document.textLength)).rounded())
        // The reader's text comes from the live DOM, the document's from the file; whitespace may differ
        // inside a line, so try the whole quote first, then its first words.
        let words = quote.split(whereSeparator: \.isWhitespace)
        for candidate in [quote, words.prefix(4).joined(separator: " ")] where candidate.count >= 8 {
            if let point = document.find(candidate, nearTextOffset: hint), within.map({ abs(point.textOffset - hint) <= $0 }) ?? true {
                return document.cfiPath(at: point.textOffset)
            }
        }
        return nil
    }

    private func document(_ href: String) async -> CFIDocument? {
        if let cached = documents[href] { return cached }
        guard let data = try? await load(href), let document = try? CFIDocument(xhtml: data) else { return nil }
        documents[href] = document
        return document
    }
}
