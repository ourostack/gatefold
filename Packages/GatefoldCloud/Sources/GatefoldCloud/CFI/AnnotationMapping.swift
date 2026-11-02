import Foundation

/// A highlighted passage in one resource, in the reader's terms (the words and a little of what
/// surrounds them, which Readium uses to find them in the page) and the Cloud's (two point CFIs).
public struct AnnotationRange: Sendable, Hashable {
    /// Container-relative path of the resource, as `SpineMap` names it.
    public var href: String
    public var spineIndex: Int
    public var begin: EPUBCFI
    /// Just past the last highlighted character.
    public var end: EPUBCFI
    /// The passage as the book's XHTML has it.
    public var text: String
    /// Up to `contextLength` characters on either side, for finding the passage again.
    public var before: String
    public var after: String
    /// Where the passage starts in its resource, 0...1.
    public var progression: Double

    public static let contextLength = 48

    public init(href: String, spineIndex: Int, begin: EPUBCFI, end: EPUBCFI, text: String, before: String, after: String, progression: Double) {
        self.href = href
        self.spineIndex = spineIndex
        self.begin = begin
        self.end = end
        self.text = text
        self.before = before
        self.after = after
        self.progression = progression
    }

    /// The passage with its whitespace runs folded to single spaces, as readers display and store it.
    public var displayText: String { AnnotationRange.fold(text) }

    static func fold(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

public extension PositionMapper {
    /// Where a Cloud highlight or note sits in this book. Resolves `quotation.begin`/`end`; when they
    /// don't resolve, or name different words than `quotation.text`, finds the quoted words instead
    /// (nearest the anchor, then anywhere in the book). Nil for bookmarks and passages not in this book.
    func range(for annotation: CloudAnnotation) async -> AnnotationRange? {
        guard annotation.kind.value != .bookmark, let quotation = annotation.quotation?.value else { return nil }
        let quote = AnnotationRange.fold(quotation.text)
        let beginCFI = PocketBookAnchor(quotation.begin).cfi
        if let beginCFI, let href = spine.href(for: beginCFI), let index = spine.index(ofHref: href), let doc = await document(href) {
            if let start = doc.resolve(beginCFI) {
                if let endCFI = PocketBookAnchor(quotation.end).cfi, spine.href(for: endCFI) == href,
                   let end = doc.resolve(endCFI), end.textOffset > start.textOffset,
                   quote.isEmpty || CFIDocument.squeeze(doc.text(from: start, count: end.textOffset - start.textOffset)) == CFIDocument.squeeze(quote) {
                    return makeRange(in: doc, href: href, index: index, start: start.textOffset, end: end.textOffset)
                }
                if let found = doc.findLoosely(quote, near: start.textOffset) {
                    return makeRange(in: doc, href: href, index: index, start: found.lowerBound, end: found.upperBound)
                }
            } else if let found = doc.findLoosely(quote, near: 0) {
                return makeRange(in: doc, href: href, index: index, start: found.lowerBound, end: found.upperBound)
            }
        }
        // A layout anchor (`pbr:/page?…`) or a CFI from another edition: look for the words themselves.
        guard CFIDocument.squeeze(quote).count >= 12 else { return nil }
        for (index, item) in spine.items.enumerated() {
            if let doc = await document(item.href), let found = doc.findLoosely(quote, near: 0) {
                return makeRange(in: doc, href: item.href, index: index, start: found.lowerBound, end: found.upperBound)
            }
        }
        return nil
    }

    /// The passage a reader selected, from what Readium reports: the resource, the selected words, a
    /// little of the text either side, and roughly where in the resource the page is.
    func range(href: String, highlight: String, before: String?, after: String?, progression: Double?) async -> AnnotationRange? {
        guard let index = spine.index(ofHref: href) else { return nil }
        let itemHref = spine.items[index].href
        guard let doc = await document(itemHref) else { return nil }
        let hint = Int((min(1, max(0, progression ?? 0)) * Double(doc.textLength)).rounded())
        guard let found = doc.findLoosely(highlight, near: hint, before: before, after: after) else { return nil }
        return makeRange(in: doc, href: itemHref, index: index, start: found.lowerBound, end: found.upperBound)
    }

    private func makeRange(in doc: CFIDocument, href: String, index: Int, start: Int, end: Int) -> AnnotationRange? {
        // The end CFI names the point just after the last character, inside that character's own text node.
        guard end > start, let begin = doc.cfiPath(at: start), var last = doc.cfiPath(at: end - 1) else { return nil }
        last.offset = (last.offset ?? 0) + 1
        let item = spine.items[index]
        let point = { (path: CFIDocument.Path) in
            EPUBCFI.point(spineStep: self.spine.spineStep, spineIndex: index, spineItemID: item.idref, documentSteps: path.steps, offset: path.offset)
        }
        let context = AnnotationRange.contextLength
        return AnnotationRange(
            href: href, spineIndex: index, begin: point(begin), end: point(last),
            text: doc.text(from: .init(textOffset: start), count: end - start),
            before: doc.text(from: .init(textOffset: max(0, start - context)), count: min(context, start)),
            after: doc.text(from: .init(textOffset: end), count: context),
            progression: doc.textLength == 0 ? 0 : Double(start) / Double(doc.textLength)
        )
    }
}

public extension CloudAnnotation {
    /// A new highlight (or, with a note, a note) on a passage, anchored the way PocketBook's web reader writes them.
    static func highlight(_ range: AnnotationRange, color: AnnotationColor = .yellow, note: String? = nil,
                          style: PocketBookAnchor.Style = .web, at date: Date) -> CloudAnnotation {
        let note = note.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        return .highlight(begin: PocketBookAnchor.string(for: range.begin, style: style),
                          end: PocketBookAnchor.string(for: range.end, style: style),
                          text: range.displayText, color: color, note: note, at: date)
    }

    /// The note's words, when there are any.
    var noteText: String? {
        guard let text = note?.value.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// Which client's anchor form the passage was written in.
    var anchorStyle: PocketBookAnchor.Style? {
        (quotation?.value.begin ?? mark?.value.anchor).flatMap { PocketBookAnchor($0).style }
    }

    /// Sets (or, with empty text, clears) the note. A highlight with a note is a "note" to PocketBook.
    mutating func setNote(_ text: String, at date: Date) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        note = .init(trimmed, updated: date)
        let kindValue: AnnotationKind = trimmed.isEmpty ? .highlight : .note
        if kind.value != kindValue { kind = .init(kindValue, updated: date) }
    }
}

extension CFIDocument {
    /// `s` without any whitespace, in UTF-16 units.
    static func squeeze(_ s: String) -> [UInt16] {
        s.utf16.filter { !isSpace($0) }
    }

    static func isSpace(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200B, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: true
        default: false
        }
    }

    /// The body-text offsets of `quote`, comparing without whitespace (the page and the file break lines
    /// differently). Of several matches, the one whose surroundings agree with `before`/`after`, then the
    /// one nearest `hint`.
    func findLoosely(_ quote: String, near hint: Int, before: String? = nil, after: String? = nil) -> Range<Int>? {
        let needle = Self.squeeze(quote)
        guard !needle.isEmpty else { return nil }
        var squeezed: [UInt16] = []
        var origin: [Int] = []
        squeezed.reserveCapacity(text.count)
        origin.reserveCapacity(text.count)
        for (i, unit) in text.enumerated() where !Self.isSpace(unit) {
            squeezed.append(unit)
            origin.append(i)
        }
        guard needle.count <= squeezed.count else { return nil }
        let prefix = Array(Self.squeeze(before ?? "").suffix(24))
        let suffix = Array(Self.squeeze(after ?? "").prefix(24))
        func agreement(_ at: Int) -> Int {
            var score = 0
            if !prefix.isEmpty, at >= prefix.count, Array(squeezed[(at - prefix.count)..<at]) == prefix { score += 1 }
            let end = at + needle.count
            if !suffix.isEmpty, end + suffix.count <= squeezed.count, Array(squeezed[end..<(end + suffix.count)]) == suffix { score += 1 }
            return score
        }
        var best: (at: Int, score: Int, distance: Int)?
        var i = 0
        let first = needle[0]
        while i <= squeezed.count - needle.count {
            if squeezed[i] == first, squeezed[i..<(i + needle.count)].elementsEqual(needle) {
                let candidate = (at: i, score: agreement(i), distance: abs(origin[i] - hint))
                if best == nil || candidate.score > best!.score || (candidate.score == best!.score && candidate.distance < best!.distance) {
                    best = candidate
                }
            }
            i += 1
        }
        guard let best else { return nil }
        return origin[best.at]..<(origin[best.at + needle.count - 1] + 1)
    }
}
