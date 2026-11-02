import CoreGraphics
import Foundation

// MARK: - Headings and titles

/// Softens shouting headings ("CHAPTER XIX." reads as "Chapter XIX") and keeps numerals.
public enum Headings {
    public static func tidy(_ s: String) -> String {
        var t = normalize(s)
        while let last = t.last, ".:;,".contains(last) { t.removeLast() }
        t = t.trimmingCharacters(in: .whitespaces)
        let isShouting = t == t.uppercased() && t != t.lowercased()
        let words = t.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        return words.enumerated().map { i, word in
            if isNumeral(word) { return word }
            if isShouting || (i == 0 && word.count > 1 && word == word.uppercased() && word != word.lowercased()) {
                return soften(word)
            }
            return word
        }.joined(separator: " ")
    }

    static func normalize(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func isNumeral(_ word: String) -> Bool {
        let core = word.trimmingCharacters(in: CharacterSet(charactersIn: ".:,;"))
        return !core.isEmpty && (core.allSatisfy { "IVXLCDM".contains($0) } || core.allSatisfy(\.isNumber))
    }

    /// "HARKER’S" → "Harker’s", "MOBY-DICK" → "Moby-Dick".
    static func soften(_ word: String) -> String {
        word.split(separator: "-", omittingEmptySubsequences: false).map { part in
            guard let first = part.first else { return String(part) }
            return String(first).uppercased() + part.dropFirst().lowercased()
        }.joined(separator: "-")
    }
}

extension BookTitle {
    /// The title a reader would say: no subtitle, no shouting, no trailing full stop.
    /// "Frankenstein; or, The modern Prometheus" → "Frankenstein".
    public static func display(_ title: String) -> String {
        var t = short(title)
        while let last = t.last, ".;:,".contains(last) { t.removeLast() }
        if t == t.uppercased() || t == t.lowercased() {
            t = t.split(separator: " ").map { Headings.soften(String($0)) }.joined(separator: " ")
        }
        return t
    }
}

// MARK: - Contents

/// Turns a publisher's table of contents into one a reader wants: it starts at the first chapter,
/// leaves out title pages, "Contents" and the licence, and names chapters plainly.
public enum ContentsCleaner {
    public struct Kept: Equatable, Sendable {
        /// Index into the entries given.
        public var index: Int
        public var title: String
    }

    public static func clean(_ entries: [ContentsIndex.Entry], bookTitle: String) -> [Kept] {
        let titleLetters = letters(bookTitle)
        var candidates: [Kept] = []
        for (i, entry) in entries.enumerated() {
            let raw = Headings.normalize(entry.title)
            if raw.isEmpty || raw.range(of: #"^\{[^}]*\}$"#, options: .regularExpression) != nil { continue }
            if BookEnd.isBackMatter(raw) { continue }
            let bare = raw.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
            if ["contents", "table of contents", "content"].contains(bare) { continue }
            let title = Headings.tidy(chapterHeading(raw))
            // The book's own title, or a piece of it ("Frankenstein;", "D R A C U L A").
            let l = letters(title)
            if l.count >= 4, titleLetters.contains(l) || l.contains(titleLetters) { continue }
            candidates.append(Kept(index: i, title: title))
        }
        if let first = candidates.firstIndex(where: { isChapterLike($0.title) }) {
            candidates.removeFirst(first)
        }
        return candidates
    }

    /// "I hope Mr. Bingley will like it. CHAPTER II." → "CHAPTER II."; "CHAPTERXXVII." → "CHAPTER XXVII.".
    static func chapterHeading(_ s: String) -> String {
        var t = s
        if let r = t.range(of: #"(?i)\bchapter(?=\s*[IVXLCDM\d])"#, options: .regularExpression), r.lowerBound != t.startIndex {
            t = String(t[r.lowerBound...])
        }
        if let r = t.range(of: #"(?i)^chapter(?=[IVXLCDM\d])"#, options: .regularExpression) {
            t.replaceSubrange(r, with: String(t[r]) + " ")
        }
        return t
    }

    static func isChapterLike(_ title: String) -> Bool {
        let patterns = [
            #"(?i)^(chapter|letter|book|part|volume|prologue|preface|introduction|foreword|epilogue|stave|canto)\b"#,
            #"^[IVXLCDM]+\.?(\s|$)"#,
            #"^\d+\.?(\s|$)"#,
        ]
        return patterns.contains { title.range(of: $0, options: .regularExpression) != nil }
    }

    static func letters(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.letters.contains($0) }.map(Character.init))
    }
}

/// Where the story ends, so turning past its last page closes the book with care instead of
/// wandering into the licence.
public enum BookEnd {
    /// The contents entry where back matter (a Project Gutenberg licence) begins, if any.
    public static func backMatter(in entries: [ContentsIndex.Entry]) -> ContentsIndex.Entry? {
        entries.first { isBackMatter($0.title) }
    }

    static func isBackMatter(_ title: String) -> Bool {
        title.range(of: #"(?i)licen[cs]e|gutenberg"#, options: .regularExpression) != nil
    }

    /// Without a marker, the last half percent of the book counts as its end.
    public static func isNearEnd(_ totalProgression: Double) -> Bool { totalProgression >= 0.995 }
}

// MARK: - Words for moments

/// "just now", "5 min ago", "2 h ago", "yesterday", "4 days ago".
public enum RelativeAge {
    public static func text(from date: Date, to now: Date) -> String {
        let s = max(0, now.timeIntervalSince(date))
        switch s {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(s / 60)) min ago"
        case ..<(24 * 3600): return "\(Int(s / 3600)) h ago"
        case ..<(48 * 3600): return "yesterday"
        default: return "\(Int(s / 86400)) days ago"
        }
    }
}

/// The paper slip that tells the reader the sync happened.
public struct SyncSlip: Equatable, Sendable {
    public var title: String
    public var detail: String?
    /// A few words of the other device's place.
    public var passage: String?

    /// The book opened on the other device's page.
    public static func landed(device: String, updated: Date, now: Date) -> SyncSlip {
        SyncSlip(title: "From your \(deviceWord(device)) · \(RelativeAge.text(from: updated, to: now))", detail: nil, passage: nil)
    }

    /// The other device is further on.
    public static func ahead(device: String, pagesAhead: Int?, percentAhead: Int?, chapter: String?, passage: String?) -> SyncSlip {
        let how: String
        if let pages = pagesAhead, pages > 0 {
            how = pages == 1 ? "1 page ahead" : "\(pages) pages ahead"
        } else if let percent = percentAhead, percent > 0 {
            how = "\(percent)% ahead"
        } else {
            how = "further ahead"
        }
        return SyncSlip(
            title: "Your \(deviceWord(device)) is \(how)",
            detail: chapter.map { "In \($0)" },
            passage: passage.flatMap(excerpt)
        )
    }

    static func deviceWord(_ device: String) -> String {
        JumpSuggestion.deviceKind(device)
    }

    /// The first words, cut at a word boundary, ending in an ellipsis.
    static func excerpt(_ text: String) -> String? {
        let words = Headings.normalize(text).split(separator: " ")
        guard !words.isEmpty else { return nil }
        var out = ""
        for word in words {
            let next = out.isEmpty ? String(word) : out + " " + word
            if next.count > 48 { break }
            out = next
        }
        if out.isEmpty { out = String(words[0].prefix(48)) }
        while let last = out.last, ",;:—-".contains(last) { out.removeLast() }
        return out.count < Headings.normalize(text).count ? out + "…" : out
    }
}

/// The line under "Library" when the shelf first arrives.
public enum ArrivalGreeting {
    public static func text(bookCount: Int, waitingTitle: String?, waitingPercent: Int?) -> String? {
        guard bookCount > 0 else { return nil }
        let books = bookCount == 1 ? "1 book" : "\(bookCount) books"
        if let title = waitingTitle, let percent = waitingPercent, percent > 0 {
            return "\(books) from your PocketBook. \(BookTitle.display(title)) is waiting at \(percent)%."
        }
        return "\(books) from your PocketBook, ready when you are."
    }
}

/// "Finished · 11 days, 9 sessions".
public enum FinishLine {
    public static func text(started: Date?, finished: Date, sessions: Int, calendar: Calendar = .current) -> String {
        guard let started else { return "Every last page, read" }
        if sessions <= 1 { return "Devoured in one sitting" }
        let days = (calendar.dateComponents([.day], from: calendar.startOfDay(for: started), to: calendar.startOfDay(for: finished)).day ?? 0) + 1
        let span = days <= 1 ? "in a day" : "\(days) days"
        return "Finished · \(span), \(sessions) sessions"
    }
}

// MARK: - Layout helpers

/// Keeps the reader's controls clear of what the system reports as occluded (the folded Duo's
/// cover-screen camera and status column), with 8 pt to spare.
public struct ChromeClearance: Equatable, Sendable {
    /// Extra inset for the top bar's leading and trailing edges.
    public var leading: CGFloat = 0
    public var trailing: CGFloat = 0
    /// The trailing corner is taken: Bookmark sits beside Close instead.
    public var bookmarkLeading: Bool { trailing > 0 }
    var containerWidth: CGFloat = 0

    public static let spare: CGFloat = 8
    /// Regions starting below this are not in the top bar's way.
    static let topBand: CGFloat = 120

    public init() {}

    public static func resolve(container: CGSize, occlusions: [CGRect]) -> ChromeClearance {
        var c = ChromeClearance()
        c.containerWidth = container.width
        for region in occlusions where region.minY < topBand && region.width > 0 && region.height > 0 {
            if region.midX > container.width / 2 {
                c.trailing = max(c.trailing, container.width - region.minX + spare)
            } else {
                c.leading = max(c.leading, region.maxX + spare)
            }
        }
        return c
    }

    /// Where the ribbon hangs: near the page's trailing edge, but never under an occlusion.
    public func ribbonX(pageMaxX: CGFloat, ribbonWidth: CGFloat) -> CGFloat {
        let preferred = pageMaxX - 54
        guard trailing > 0 else { return preferred }
        return min(preferred, containerWidth - trailing - ribbonWidth - Self.spare)
    }
}

/// A book's measure: lines of about 66 characters, the way a printed page sets them.
public enum Measure {
    /// The web view's body text at 100 %, and an average serif character's width in ems.
    static let baseFont: CGFloat = 16
    static let averageCharacter: CGFloat = 0.46
    /// Readium's own padding either side of the text.
    static let readiumPadding: CGFloat = 24
    public static let targetCharacters: CGFloat = 66

    static func characterWidth(_ fontScale: Double) -> CGFloat { baseFont * CGFloat(fontScale) * averageCharacter }

    /// Inset either side of a single column so its lines stay near `targetCharacters`.
    public static func sideInset(width: CGFloat, fontScale: Double) -> CGFloat {
        let column = targetCharacters * characterWidth(fontScale) + 2 * readiumPadding
        return max(0, ((width - column) / 2).rounded(.down))
    }

    public static func charactersPerLine(column: CGFloat, fontScale: Double) -> Int {
        Int(((column - 2 * readiumPadding) / characterWidth(fontScale)).rounded())
    }
}

extension ReaderPreferences {
    /// On a regular-width screen (iPad) the first book starts a step larger.
    public static func initialFontScale(forContentSizeRank rank: Int, regularWidth: Bool) -> Double {
        let base = initialFontScale(forContentSizeRank: rank)
        return regularWidth ? (base * 1.15 * 100).rounded() / 100 : base
    }
}

// MARK: - Colour

/// Gatefold's own colours (outside the reader's themes), light and dark.
public struct Brand: Sendable {
    public var ribbon: UInt32
    /// Labels on a ribbon-coloured fill.
    public var onRibbon: UInt32
    public var paper: UInt32
    public var ink: UInt32

    public static let light = Brand(ribbon: 0x9A3B26, onRibbon: 0xFFFFFF, paper: 0xF6F1E7, ink: 0x23201C)
    /// White on the dark ribbon is 2.6:1, so labels there are ink (about 6.6:1).
    public static let dark = Brand(ribbon: 0xE08A6A, onRibbon: 0x1B1A18, paper: 0x1B1A18, ink: 0xEDE6DA)
}

extension ThemePalette {
    /// WCAG 2 contrast ratio between two colours.
    public static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// The label colour for a button filled with the accent: white or ink, whichever reads better.
    public var onAccent: UInt32 {
        let white: UInt32 = 0xFFFFFF, ink: UInt32 = 0x1B1A18
        return Self.contrast(white, accent) >= Self.contrast(ink, accent) ? white : ink
    }
}
