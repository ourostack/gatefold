/// One book counts its pages at a time, and the book on screen goes first.
///
/// A count lays every chapter out in several web views behind the page. Three books opened ahead of a
/// tap counted at once on CI's iPad (13, 17 and 32 chapters, 168 to 219 s each, all overlapping), and the
/// app stopped answering until a UI query timed out (gatefold#113). One count at a time takes no longer
/// in all, since the counts were sharing the same CPU, and the book he opens never waits on the others.
@MainActor
public final class CountingTurns {
    private struct Ask {
        weak var owner: AnyObject?
        let id: ObjectIdentifier
        var opened: Bool
        /// Order of the first ask, so a count that gave way keeps its place among the waiting ones.
        let order: Int
        var start: @MainActor () -> Void
        var yield: @MainActor () -> Void
    }

    private var holder: Ask?
    private var waiting: [Ask] = []
    private var asked = 0

    public init() {}

    /// The book counting now, if any.
    public var counting: ObjectIdentifier? { holder?.id }

    /// `start` runs now when no other book is counting, or once its turn comes. A book on screen
    /// (`opened`) goes ahead of the books behind the shelf: one of those counting gives way (`yield`, which
    /// stops its count, keeping what it counted) and starts again later. A second ask by the same book
    /// replaces its first; the book counting now starts again at once.
    public func ask(_ owner: AnyObject, opened: Bool, start: @escaping @MainActor () -> Void,
                    yield: @escaping @MainActor () -> Void = {}) {
        let id = ObjectIdentifier(owner)
        if var current = holder, current.id == id {
            current.opened = current.opened || opened
            current.start = start
            current.yield = yield
            holder = current
            start()
            return
        }
        var order: Int
        if let i = waiting.firstIndex(where: { $0.id == id }) {
            order = waiting[i].order
            waiting.remove(at: i)
        } else {
            asked += 1
            order = asked
        }
        waiting.append(Ask(owner: owner, id: id, opened: opened, order: order, start: start, yield: yield))
        next()
    }

    /// `owner` became the book on screen (he tapped a book opened ahead of the tap): its count goes first.
    public func opened(_ owner: AnyObject) {
        let id = ObjectIdentifier(owner)
        if holder?.id == id { holder?.opened = true; return }
        guard let i = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting[i].opened = true
        next()
    }

    /// `owner`'s count ended or stopped, or the book went: the next one waiting starts.
    public func done(_ owner: AnyObject) {
        let id = ObjectIdentifier(owner)
        waiting.removeAll { $0.id == id }
        if holder?.id == id {
            holder = nil
            next()
        }
    }

    private func next() {
        waiting.removeAll { $0.owner == nil }
        if let current = holder, current.owner == nil { holder = nil }
        guard let pick = waiting.indices.min(by: { rank(waiting[$0]) < rank(waiting[$1]) }) else { return }
        if let current = holder {
            // Only the book on screen takes the turn from a book behind the shelf.
            guard waiting[pick].opened, !current.opened else { return }
            holder = nil
            current.yield()
            waiting.append(current)
        }
        let chosen = waiting.remove(at: pick)
        holder = chosen
        chosen.start()
    }

    private func rank(_ ask: Ask) -> (Int, Int) { (ask.opened ? 0 : 1, ask.order) }
}
