import Foundation

/// What decides how a book cuts into screen pages: the page's size, columns a screen and the type.
/// The paper (theme) doesn't, so it isn't here. Sizes are kept to the point: a measured frame's
/// sub-point noise is the same layout.
public struct ScreenPageLayout: Codable, Hashable, Sendable {
    public var width: Int
    public var height: Int
    public var columnsPerScreen: Int
    /// Type scale and line height in hundredths, margins in thousandths of the page width.
    public var fontScale: Int
    public var lineHeight: Int
    public var margins: Int
    public var font: String
    public var justify: Bool

    public init(width: Double, height: Double, columnsPerScreen: Int, fontScale: Double, lineHeight: Double,
                margins: Double, font: String, justify: Bool) {
        self.width = Int(width.rounded())
        self.height = Int(height.rounded())
        self.columnsPerScreen = max(1, columnsPerScreen)
        self.fontScale = Int((fontScale * 100).rounded())
        self.lineHeight = Int((lineHeight * 100).rounded())
        self.margins = Int((margins * 1000).rounded())
        self.font = font
        self.justify = justify
    }

    /// A file-name-safe name for this layout.
    public var key: String {
        "\(width)x\(height)-c\(columnsPerScreen)-s\(fontScale)-l\(lineHeight)-m\(margins)-\(font)-\(justify ? "j" : "r")"
    }
}

/// The pages he sees, numbered through the book as Apple Books numbers them: each chapter's count of
/// screen columns at one layout, summed in reading order. A turn moves on one page (two on a
/// spread), a spread's numbers are consecutive, and a chapter that ends on a spread's left page
/// leaves its right page blank but counted, so the next chapter opens on a left page.
///
/// A number is known only once every chapter before it is counted; until then none is shown.
public struct ScreenPageMap: Codable, Equatable, Sendable {
    public let book: String
    public let layout: ScreenPageLayout
    public let readingOrder: [String]
    /// Columns each chapter lays out to, as measured.
    public private(set) var columns: [String: Int] = [:]

    public init(book: String, layout: ScreenPageLayout, readingOrder: [String]) {
        self.book = book
        self.layout = layout
        self.readingOrder = readingOrder
    }

    /// A chapter measured at this layout. Zero (a web view not laid out yet) is not a count.
    public mutating func record(href: String, columns count: Int) {
        guard count > 0, readingOrder.contains(href) else { return }
        columns[href] = count
    }

    /// The pages `href` takes, its blank last page on a spread included; nil until counted.
    public func pages(of href: String) -> Int? {
        guard let n = columns[href] else { return nil }
        let per = layout.columnsPerScreen
        return (n + per - 1) / per * per
    }

    /// The number of the page before `href`'s first; nil while a chapter before it is uncounted.
    private func pagesBefore(_ href: String) -> Int? {
        guard let index = readingOrder.firstIndex(of: href) else { return nil }
        var sum = 0
        for earlier in readingOrder[..<index] {
            guard let n = pages(of: earlier) else { return nil }
            sum += n
        }
        return sum
    }

    /// The numbers on the screen whose first column is `column` of `href`: one for a page, two for
    /// a spread. Nil when they aren't known yet, or the column isn't in the chapter.
    public func numbers(href: String, column: Int) -> [Int]? {
        guard column >= 0, let pages = pages(of: href), column < pages, let before = pagesBefore(href) else { return nil }
        let first = column / layout.columnsPerScreen * layout.columnsPerScreen
        return (0..<layout.columnsPerScreen).map { before + first + $0 + 1 }
    }

    /// The number of the page a place `progression` (0...1) into `href` falls on.
    public func number(href: String, progression: Double) -> Int? {
        guard let n = columns[href], let before = pagesBefore(href) else { return nil }
        let column = min(n - 1, max(0, Int((progression * Double(n)).rounded(.down))))
        return before + column + 1
    }

    /// The chapter's pages after the screen whose first column is `column` (a blank page not counted).
    public func pagesLeft(href: String, column: Int) -> Int? {
        guard let n = columns[href] else { return nil }
        let first = max(0, column) / layout.columnsPerScreen * layout.columnsPerScreen
        return max(0, n - first - layout.columnsPerScreen)
    }

    /// The column is the blank right page after a chapter that ends on a left one.
    public func isBlank(href: String, column: Int) -> Bool {
        guard let n = columns[href], let pages = pages(of: href) else { return false }
        return column >= n && column < pages
    }

    public var isComplete: Bool { readingOrder.allSatisfy { columns[$0] != nil } }

    public var total: Int? {
        isComplete ? readingOrder.reduce(0) { $0 + (pages(of: $1) ?? 0) } : nil
    }

    /// The chapters still to measure, in reading order.
    public var uncounted: [String] { readingOrder.filter { columns[$0] == nil } }

    public func fits(_ other: ScreenPageLayout) -> Bool { layout == other }
}

/// Where the web view is in its chapter, from its scroll geometry: Readium lays a reflowable chapter
/// out in columns side by side and scrolls a screen (one or two columns) per turn.
public struct ScreenPageGeometry: Equatable, Sendable {
    /// The chapter's width in columns, as laid out now.
    public let columns: Int
    /// The column at the screen's left edge.
    public let column: Int
    /// The unfold's blank verso is before the chapter's first page.
    public let verso: Bool
    /// The unfold started a column at his sentence, so the chapter lays out a little differently.
    public let pinned: Bool

    public init(scrollWidth: Double, scrollLeft: Double, viewportWidth: Double, columnsPerScreen: Int,
                verso: Bool = false, pinned: Bool = false) {
        let width = viewportWidth / Double(max(1, columnsPerScreen))
        self.verso = verso
        self.pinned = pinned
        guard width > 0 else { columns = 0; column = 0; return }
        columns = max(0, Int((scrollWidth / width).rounded()))
        column = max(0, Int((scrollLeft / width).rounded()))
    }

    /// Laid out as any reader would see the chapter, so its columns are the chapter's count.
    public var isClean: Bool { !verso && !pinned }
}

extension ScreenPageMap {
    /// Counts the chapter on screen, when it is laid out clean.
    public mutating func record(href: String, geometry: ScreenPageGeometry) {
        guard geometry.isClean else { return }
        record(href: href, columns: geometry.columns)
    }

    /// The numbers on the screen the web view shows, one a page; nil for a blank page (the unfold's
    /// verso, a chapter's last right page). Nil altogether until they're known.
    ///
    /// The verso shifts the chapter one page over, so its pages keep their numbers. A column the
    /// unfold started at his sentence can push the chapter's later words a page on; those pages
    /// stay consecutive and keep the chapter's numbers, so the next chapter's don't move.
    public func screen(href: String, geometry: ScreenPageGeometry) -> [Int?]? {
        guard let pages = pages(of: href), let first = numbers(href: href, column: 0)?.first else { return nil }
        let per = layout.columnsPerScreen
        let start = geometry.column / per * per
        return (start..<start + per).map { slot in
            let c = slot - (geometry.verso ? 1 : 0)
            guard c >= 0, c < pages else { return nil }
            // Clean, the counted columns are the words; after a pin, the columns laid out now are.
            let words = geometry.isClean ? (columns[href] ?? 0) : geometry.columns - (geometry.verso ? 1 : 0)
            return c < words ? first + c : nil
        }
    }
}

/// Keeps each book's counts on disk, one file a layout.
public struct ScreenPageStore: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// v2 (build 18): a count is taken only in the chapter it names. Earlier counts could hold the
    /// previous chapter's columns, so they are counted again rather than trusted.
    static let version = "v2"

    private func url(book: String, layout: ScreenPageLayout) -> URL {
        let safe = book.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? book
        return directory.appending(path: safe, directoryHint: .isDirectory).appending(path: "\(layout.key)-\(Self.version).json")
    }

    /// The counts kept for this book at this layout, or none yet.
    public func load(book: String, layout: ScreenPageLayout, readingOrder: [String]) -> ScreenPageMap {
        if let data = try? Data(contentsOf: url(book: book, layout: layout)),
           let map = try? JSONDecoder().decode(ScreenPageMap.self, from: data),
           map.book == book, map.layout == layout, map.readingOrder == readingOrder {
            return map
        }
        return ScreenPageMap(book: book, layout: layout, readingOrder: readingOrder)
    }

    public func save(_ map: ScreenPageMap) {
        let file = url(book: map.book, layout: map.layout)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(map) { try? data.write(to: file, options: .atomic) }
    }
}
