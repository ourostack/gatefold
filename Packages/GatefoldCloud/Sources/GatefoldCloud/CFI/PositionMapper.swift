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

    public init(href: String, progression: Double? = nil, totalProgression: Double? = nil, cfi: String? = nil, textAfter: String? = nil) {
        let trimmed = href.hasPrefix("/") ? String(href.dropFirst()) : href
        self.href = trimmed.removingPercentEncoding ?? trimmed
        self.progression = progression
        self.totalProgression = totalProgression
        self.cfi = cfi
        self.textAfter = textAfter
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
        guard let document = await document(location.href),
              let path = document.cfiPath(atProgression: location.progression ?? 0) else {
            return ReadingPosition(cfi: nil, progression: location.progression, totalProgression: total, updated: date)
        }
        let cfi = EPUBCFI.point(spineStep: spine.spineStep, spineIndex: index, spineItemID: spine.items[index].idref,
                                documentSteps: path.steps, offset: path.offset)
        return ReadingPosition(cfi: cfi.description, progression: location.progression, totalProgression: total, updated: date)
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

    private func document(_ href: String) async -> CFIDocument? {
        if let cached = documents[href] { return cached }
        guard let data = try? await load(href), let document = try? CFIDocument(xhtml: data) else { return nil }
        documents[href] = document
        return document
    }
}
