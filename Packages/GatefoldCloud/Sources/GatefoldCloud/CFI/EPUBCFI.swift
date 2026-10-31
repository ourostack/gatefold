import Foundation

/// A point EPUB CFI with one indirection, the only shape PocketBook stores:
/// `epubcfi(/6/16[item9]!/4/2[id]/2/1:0)`.
///
/// Parsing keeps assertions verbatim, so `description` reproduces the source string and a
/// CFI read from the Cloud is written back byte-for-byte.
public struct EPUBCFI: Sendable, Hashable, Comparable, CustomStringConvertible {
    public struct Step: Sendable, Hashable {
        public var index: Int
        public var assertion: String?
        public init(_ index: Int, assertion: String? = nil) {
            self.index = index
            self.assertion = assertion
        }
    }

    /// Steps before `!`: the `<spine>` step (usually `/6`) and the itemref step.
    public var packageSteps: [Step]
    /// Steps after `!`, relative to the content document's root element.
    public var documentSteps: [Step]
    /// Character offset (UTF-16 code units) into the terminal text node.
    public var offset: Int?
    public var offsetAssertion: String?

    public init(packageSteps: [Step], documentSteps: [Step], offset: Int? = nil, offsetAssertion: String? = nil) {
        self.packageSteps = packageSteps
        self.documentSteps = documentSteps
        self.offset = offset
        self.offsetAssertion = offsetAssertion
    }

    /// Parses `epubcfi(...)`, or any PocketBook anchor that ends in one
    /// (`#epubcfi(...)`, `pbr:/external##epubcfi(...)`, `pbr:/webkit?##epubcfi(...)`).
    public init?(_ raw: String) {
        guard let body = EPUBCFI.body(of: raw), !body.contains(",") else { return nil }
        guard let parsed = EPUBCFI.parsePath(body) else { return nil }
        self = parsed
    }

    /// Splits a range CFI `epubcfi(base,start,end)` into two point CFIs.
    public static func range(_ raw: String) -> (start: EPUBCFI, end: EPUBCFI)? {
        guard let body = body(of: raw) else { return nil }
        let parts = splitUnescaped(body, on: ",")
        guard parts.count == 3,
              let start = parsePath(parts[0] + parts[1]),
              let end = parsePath(parts[0] + parts[2]) else { return nil }
        return (start, end)
    }

    /// Builds a point CFI for a location in spine item `spineIndex` (0-based).
    public static func point(
        spineStep: Int = 6, spineIndex: Int, spineItemID: String?,
        documentSteps: [Step], offset: Int?
    ) -> EPUBCFI {
        EPUBCFI(
            packageSteps: [Step(spineStep), Step(2 * (spineIndex + 1), assertion: spineItemID)],
            documentSteps: documentSteps, offset: offset
        )
    }

    /// 0-based index into the OPF `<spine>`.
    public var spineIndex: Int? {
        guard packageSteps.count >= 2 else { return nil }
        return packageSteps[1].index / 2 - 1
    }

    /// The itemref `idref` assertion, when the CFI carries one.
    public var spineItemID: String? { packageSteps.count >= 2 ? packageSteps[1].assertion : nil }

    /// The in-document part after `!`, which Readium calls a partial CFI.
    public var partialCFI: String { EPUBCFI.render(documentSteps) + offsetString }

    public var description: String {
        "epubcfi(" + EPUBCFI.render(packageSteps) + "!" + partialCFI + ")"
    }

    /// epub.js ordering: package steps, then document steps, then the character offset.
    /// A shorter path that is a prefix of a longer one sorts first.
    public static func < (lhs: EPUBCFI, rhs: EPUBCFI) -> Bool {
        let l = lhs.packageSteps.map(\.index) + [-1] + lhs.documentSteps.map(\.index)
        let r = rhs.packageSteps.map(\.index) + [-1] + rhs.documentSteps.map(\.index)
        for (a, b) in zip(l, r) where a != b { return a < b }
        if l.count != r.count { return l.count < r.count }
        return (lhs.offset ?? -1) < (rhs.offset ?? -1)
    }

    /// Two CFIs that name the same location, ignoring assertions.
    public func isSameLocation(as other: EPUBCFI) -> Bool { !(self < other) && !(other < self) }

    // MARK: - Parsing

    private var offsetString: String {
        guard let offset else { return "" }
        return ":\(offset)" + (offsetAssertion.map { "[\($0)]" } ?? "")
    }

    private static func render(_ steps: [Step]) -> String {
        steps.map { "/\($0.index)" + ($0.assertion.map { "[\($0)]" } ?? "") }.joined()
    }

    /// The text between `epubcfi(` and its closing `)`, after any anchor prefix.
    static func body(of raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // PocketBook's anchor parser takes everything after the last `#`.
        let tail = trimmed.range(of: "#", options: .backwards).map { String(trimmed[$0.upperBound...]) } ?? trimmed
        guard tail.hasPrefix("epubcfi("), tail.hasSuffix(")") else { return nil }
        let body = String(tail.dropFirst("epubcfi(".count).dropLast())
        return body.isEmpty ? nil : body
    }

    private static func parsePath(_ path: String) -> EPUBCFI? {
        let halves = splitUnescaped(path, on: "!")
        guard halves.count == 2,
              let package = parseSteps(halves[0]), package.offset == nil, package.steps.count >= 2,
              let document = parseSteps(halves[1]) else { return nil }
        return EPUBCFI(packageSteps: package.steps, documentSteps: document.steps,
                       offset: document.offset, offsetAssertion: document.offsetAssertion)
    }

    private static func parseSteps(_ text: String) -> (steps: [Step], offset: Int?, offsetAssertion: String?)? {
        var steps: [Step] = []
        var offset: Int?
        var offsetAssertion: String?
        var chars = Array(text)
        var i = 0

        func readInt() -> Int? {
            var digits = ""
            while i < chars.count, chars[i].isASCII, chars[i].isNumber { digits.append(chars[i]); i += 1 }
            return Int(digits)
        }
        func readAssertion() -> String?? {
            guard i < chars.count, chars[i] == "[" else { return .some(nil) }
            i += 1
            var value = ""
            while i < chars.count {
                if chars[i] == "^", i + 1 < chars.count { value.append(chars[i]); value.append(chars[i + 1]); i += 2; continue }
                if chars[i] == "]" { i += 1; return .some(value) }
                value.append(chars[i]); i += 1
            }
            return nil // unterminated
        }

        while i < chars.count {
            switch chars[i] {
            case "/":
                guard offset == nil else { return nil }
                i += 1
                guard let index = readInt(), let assertion = readAssertion() else { return nil }
                steps.append(Step(index, assertion: assertion))
            case ":":
                i += 1
                guard let value = readInt(), let assertion = readAssertion() else { return nil }
                offset = value
                offsetAssertion = assertion
                // Temporal/spatial suffixes (`~`, `@`) never appear in PocketBook data; reject them.
                guard i == chars.count else { return nil }
            default:
                return nil
            }
        }
        chars.removeAll()
        guard !steps.isEmpty else { return nil }
        return (steps, offset, offsetAssertion)
    }

    private static func splitUnescaped(_ text: String, on separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var escaped = false
        var inAssertion = false
        for ch in text {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "^" { current.append(ch); escaped = true; continue }
            if ch == "[" { inAssertion = true }
            if ch == "]" { inAssertion = false }
            if ch == separator, !inAssertion { parts.append(current); current = ""; continue }
            current.append(ch)
        }
        parts.append(current)
        return parts
    }
}
