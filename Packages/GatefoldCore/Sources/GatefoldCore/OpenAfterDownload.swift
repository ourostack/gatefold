/// One tap on a book still in the Cloud means "read this": the book downloads and then opens, without a second tap
/// (Ari, 2026-11-27). It opens only if he is still waiting for it when it lands: on the shelf, with nothing over it,
/// the app in front, and no other book tapped or opened since. Once he has gone elsewhere, the book lands quietly
/// instead, ready on the shelf for his next tap, so a download never pulls him away from what he went to do.
public struct OpenAfterDownload: Equatable, Sendable {
    public enum Landing: Equatable, Sendable {
        /// He is still waiting for it: open it now.
        case open
        /// He asked for it and went elsewhere: show it ready on the shelf.
        case ready
        /// Nobody asked for this download (a stopped one that landed anyway, or one the app started itself).
        case nothing
    }

    /// The book he is waiting to open, if any.
    public private(set) var awaited: String?
    /// Books he asked for whose download is still under way.
    private var asked: Set<String> = []
    /// Books he asked for that landed while he was elsewhere, not opened since.
    private var ready: Set<String> = []

    public init() {}

    /// He tapped a book in the Cloud: it is the one he waits for now, in place of any he tapped before.
    public mutating func tapped(_ id: String) {
        awaited = id
        asked.insert(id)
        ready.remove(id)
    }

    /// He went elsewhere: another screen or sheet, or the app into the background.
    public mutating func left() { awaited = nil }

    /// He stopped the download: nothing to open, nothing to show ready.
    public mutating func stopped(_ id: String) {
        asked.remove(id)
        if awaited == id { awaited = nil }
    }

    /// The download failed. The shelf says so; a Try Again tap asks again.
    public mutating func failed(_ id: String) { stopped(id) }

    /// A book opened, by any way in: he isn't waiting for another, and this one is no longer news.
    public mutating func opened(_ id: String) {
        awaited = nil
        ready.remove(id)
    }

    /// A download landed. `shelfInFront`: the app is in front with the shelf showing and nothing over it.
    public mutating func landed(_ id: String, shelfInFront: Bool) -> Landing {
        guard asked.remove(id) != nil else { return .nothing }
        if awaited == id {
            awaited = nil
            if shelfInFront { return .open }
        }
        ready.insert(id)
        return .ready
    }

    /// Landed while he was elsewhere and not opened since.
    public func isReady(_ id: String) -> Bool { ready.contains(id) }
}
