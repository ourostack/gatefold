import Foundation

/// One device's place in a book.
public struct ProgressSnapshot: Equatable, Sendable {
    public var totalProgression: Double
    public var updated: Date
    public var device: String

    public init(totalProgression: Double, updated: Date, device: String) {
        self.totalProgression = totalProgression
        self.updated = updated
        self.device = device
    }
}

/// Every whole percent Gatefold sends or shows: the Cloud's `offs` and `read_percent`, the shelf's
/// "percent read" and the banner's "% through". PocketBook's readers write `ceil(100 × progress)`, so a
/// started book never reads 0%; using their rule everywhere means our numbers match theirs.
///
/// The other two numbers have one meaning each: `totalProgression` is Readium's whole-book scale, 0...1
/// (another device's place is moved onto it with `ReadingScale` when its CFI resolves), and a page is
/// `ChapterMap.page(at:)`.
public enum ReadingPercent {
    public static func whole(_ totalProgression: Double) -> Int {
        guard totalProgression.isFinite else { return 0 }
        let percent = min(1, max(0, totalProgression)) * 100
        // Floating-point noise (0.07 × 100 = 7.000000000000001) must not add a percent.
        return min(100, max(0, Int((percent - 1e-9).rounded(.up))))
    }

    /// The place a Cloud percent stands for.
    public static func fraction(_ percent: Double) -> Double {
        guard percent.isFinite else { return 0 }
        return min(1, max(0, percent / 100))
    }
}

/// "Your e-reader is further ahead — jump?"
public struct JumpSuggestion: Equatable, Sendable {
    public var headline: String
    public var detail: String
    public var targetProgression: Double

    /// Ignore differences smaller than this (about a page in a long book).
    public static let threshold = 0.002

    /// Whether another device's place is further on than ours. A place the Cloud only knows as a whole
    /// percent is ahead only when its percent is: our own 30.1% reads back as 31%, which is where we are.
    public static func isAhead(remote: Double, percentOnly: Bool, local: Double) -> Bool {
        if percentOnly { return ReadingPercent.whole(remote) > ReadingPercent.whole(local) }
        return remote > local + threshold
    }

    public static func make(local: ProgressSnapshot?, remote: ProgressSnapshot?, totalPages: Int?, remotePercentOnly: Bool = false) -> JumpSuggestion? {
        guard let remote, remote.totalProgression > threshold else { return nil }
        if let local {
            guard remote.updated > local.updated,
                  isAhead(remote: remote.totalProgression, percentOnly: remotePercentOnly, local: local.totalProgression) else { return nil }
        }
        let place: String
        if let totalPages, totalPages > 0 {
            let page = ChapterMap(chapters: [], positionCount: totalPages).page(at: remote.totalProgression)
            place = "Page \(page) of \(totalPages)."
        } else {
            place = "\(ReadingPercent.whole(remote.totalProgression))% through."
        }
        return JumpSuggestion(
            headline: "Your \(deviceKind(remote.device)) is further ahead",
            detail: "\(place) Jump there?",
            targetProgression: remote.totalProgression
        )
    }

    /// His own saved place, found only after the page was already in view: offered, never jumped to.
    public static func ownPlace(at totalProgression: Double, page: Int?) -> JumpSuggestion {
        JumpSuggestion(headline: "Where you stopped reading",
                       detail: page.map { "Page \($0). Jump there?" } ?? "Jump there?",
                       targetProgression: totalProgression)
    }

    /// A plain name for the other device: "e-reader", "web reader". Never a model or brand name:
    /// the App Store listing can't show a third party's trademark (#253).
    public static func deviceKind(_ device: String) -> String {
        let d = device.lowercased()
        if d.contains("web") { return "web reader" }
        if d.isEmpty { return "other device" }
        return "e-reader"
    }
}

/// Chapters and positions behind the scrubber.
public struct ChapterMap: Equatable, Sendable {
    public struct Chapter: Equatable, Sendable {
        public var title: String
        /// Total progression where the chapter starts, 0...1.
        public var start: Double
        public init(title: String, start: Double) {
            self.title = title
            self.start = start
        }
    }

    public let chapters: [Chapter]
    /// Readium positions in the book; we call each one a page.
    public let positionCount: Int

    public init(chapters: [Chapter], positionCount: Int) {
        self.chapters = chapters.sorted { $0.start < $1.start }
        self.positionCount = max(1, positionCount)
    }

    public func chapterIndex(at progression: Double) -> Int? {
        guard let last = chapters.lastIndex(where: { $0.start <= progression + 1e-9 }) else { return chapters.isEmpty ? nil : 0 }
        // Chapters that share a file share a start; the page is somewhere in the first of them or later,
        // and only the web view knows which, so name the first rather than jumping ahead.
        return chapters.firstIndex { abs($0.start - chapters[last].start) < 1e-9 } ?? last
    }

    public func chapter(at progression: Double) -> Chapter? {
        chapterIndex(at: progression).map { chapters[$0] }
    }

    public func page(at progression: Double) -> Int {
        min(positionCount, Int((progression * Double(positionCount)).rounded(.down)) + 1)
    }

    public func pagesLeftInChapter(at progression: Double) -> Int {
        let here = Int((progression * Double(positionCount)).rounded(.down))
        // The next chapter that starts later (chapters sharing a file count as one stretch).
        let end: Double = chapterIndex(at: progression).flatMap { i in
            chapters[(i + 1)...].first { $0.start > chapters[i].start + 1e-9 }?.start
        } ?? 1.0
        return max(0, Int((end * Double(positionCount)).rounded()) - here)
    }

    public func crossesChapter(from a: Double, to b: Double) -> Bool {
        chapterIndex(at: a) != chapterIndex(at: b)
    }

    public var ticks: [Double] {
        chapters.dropFirst().map(\.start)
    }
}

public struct Bookmark: Equatable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var anchor: ReadingAnchor
    public var title: String
    public var totalProgression: Double
    public var created: Date
}

public struct BookmarkList: Equatable, Codable, Sendable {
    public enum Change: Equatable, Sendable { case added, removed }

    public private(set) var items: [Bookmark] = []

    public init() {}

    public func isMarked(_ visible: VisibleRange) -> Bool {
        items.contains { visible.contains(ReadingAnchor(href: $0.anchor.href, progression: $0.anchor.progression, text: nil)) }
    }

    public mutating func toggle(at anchor: ReadingAnchor, visible: VisibleRange, title: String, totalProgression: Double, now: Date = Date()) -> Change {
        let onPage = items.filter { visible.contains(ReadingAnchor(href: $0.anchor.href, progression: $0.anchor.progression, text: nil)) }
        if !onPage.isEmpty {
            items.removeAll { mark in onPage.contains { $0.id == mark.id } }
            return .removed
        }
        items.append(Bookmark(id: UUID(), anchor: anchor, title: title, totalProgression: totalProgression, created: now))
        items.sort { $0.totalProgression < $1.totalProgression }
        return .added
    }

    public mutating func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
    }
}

/// An entry the Reading Now shelf can consider.
public struct ShelfItem: Equatable, Sendable {
    public var id: String
    public var progression: Double
    public var lastOpened: Date?
    /// When another device last moved this book's place.
    public var remoteUpdated: Date?

    public init(id: String, progression: Double, lastOpened: Date?, remoteUpdated: Date? = nil) {
        self.id = id
        self.progression = progression
        self.lastOpened = lastOpened
        self.remoteUpdated = remoteUpdated
    }

    var recency: Date? {
        switch (lastOpened, remoteUpdated) {
        case let (a?, b?): max(a, b)
        case let (a?, nil): a
        case let (nil, b?): b
        case (nil, nil): nil
        }
    }
}

public enum ReadingNow {
    /// Started, unfinished books, newest activity on any device first.
    public static func shelf(_ items: [ShelfItem], limit: Int = 10) -> [ShelfItem] {
        Array(
            items
                .filter { $0.progression > 0 && $0.progression < 0.995 && $0.recency != nil }
                .sorted { ($0.recency ?? .distantPast) > ($1.recency ?? .distantPast) }
                .prefix(limit)
        )
    }
}

/// Two readers can count the same place differently: PocketBook's percent and Readium's whole-book
/// progression weigh chapters their own ways. After landing on a Cloud place whose percent is ahead of
/// Readium's number for the same words, this keeps every number we show or send on the Cloud's scale:
/// the landed place reads as the Cloud's percent, and reading on adds to it, reaching 100 % only at the
/// end. Going back before the landed place never shows less than the Cloud did.
public struct CloudScale: Codable, Equatable, Sendable {
    /// The Cloud's progress at the landed place, 0...1.
    public var cloud: Double
    /// Readium's whole-book progression at the same place, 0...1.
    public var landed: Double

    /// Nil when no scale is needed (our number is already at or above the Cloud's) or the numbers are bad.
    public init?(cloud: Double, landed: Double) {
        guard cloud.isFinite, landed.isFinite, (0...1).contains(cloud), (0..<1).contains(landed), cloud > landed else { return nil }
        self.cloud = cloud
        self.landed = landed
    }

    /// Readium's `local` progression, as the Cloud would count it: in proportion before the landed place, and
    /// from the Cloud's number to the end after it.
    public func onCloudScale(_ local: Double) -> Double {
        guard local.isFinite else { return cloud }
        let local = min(1, max(0, local))
        // Before the landed place, in proportion: a jump back to chapter 1 is an early place, never
        // the landed percent. The two sides meet at the landed place, so the scale never steps.
        guard local > landed else { return landed > 0 ? cloud * local / landed : cloud }
        return min(1, cloud + (local - landed) * (1 - cloud) / (1 - landed))
    }
}
