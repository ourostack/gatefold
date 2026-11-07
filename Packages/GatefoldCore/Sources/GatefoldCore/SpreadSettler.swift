/// Where a place's first words sit in the spread on screen.
public enum WordsSide: Int, Sendable {
    case before = -1
    case left = 0
    case right = 1
    case after = 2
}

/// The page the spread is laid out on, as the settler sees it. The reader's web view answers these
/// from the page; a test answers them from a model of columns.
@MainActor
public protocol SpreadSurface: AnyObject {
    /// Which page of the spread the place's words start on; nil when they are not in this chapter.
    func wordsSide() async -> WordsSide?
    /// Starts a new column at the words when they sit well down their column; true when a break went in.
    func pinWords() async -> Bool
    /// Puts the blank verso in or takes it out: every page moves one side over.
    func toggleVerso() async
    /// Navigates to the progression the place was saved with, which is the old layout's.
    func goToSavedPlace() async
    /// Navigates to the spread that holds the words, by where they are in this layout.
    func goToWords() async
    func stepSpread(forward: Bool) async
    /// A value that changes while the layout or the page is still moving.
    func stillness() async -> String?
    /// One short wait.
    func beat() async
    /// True while something stands over the page (a reflow's cover, the reopen picture, a jump's veil,
    /// a turn's leaf), so a move is not seen. False on a spread the reader is reading. Asked before
    /// every move, since a cover can lift while the settle runs.
    var isCovered: Bool { get }
    /// Puts a picture of the page as it is over it, so the moves that follow are not seen one by one;
    /// false when no picture could be taken.
    func hold() async -> Bool
    /// Takes the picture away. `landed`: onto the page as the moves left it, as one change; otherwise
    /// (the settle was overtaken) at once, so the reader's own move is never hidden under it.
    func release(landed: Bool) async
}

public extension SpreadSurface {
    var isCovered: Bool { true }
    func hold() async -> Bool { true }
    func release(landed: Bool) async {}
}

/// Brings a spread opened on a place so the place's words start its left page. Every move is judged by
/// measuring the page again once it has stopped moving, because the navigator's own relayout and the
/// restore's edits to the page land in any order.
public enum SpreadSettler {
    /// How many reads of `stillness` one settle may make, across all its passes. Counted in reads, not
    /// seconds: each read is a script on the page, and on a busy device eight passes of twelve reads ran
    /// past the reflow's 12 s watchdog, which started the restore (and this) again, three times an open.
    public static let readBudget = 32

    /// Waits until two reads of `stillness` agree, up to `reads` reads.
    @MainActor
    /// Returns how many reads it made.
    @discardableResult
    static func waitStill(_ s: SpreadSurface, current: () -> Bool, reads: Int = 12) async -> Int {
        guard reads > 0 else { return 0 }
        var last = await s.stillness()
        var made = 1
        while made < reads {
            await s.beat()
            guard current() else { return made }
            let now = await s.stillness()
            made += 1
            if now == last { return made }
            last = now
        }
        return made
    }

    /// True when the page was moved, nil when the words were already right or are not here.
    ///
    /// Each pass waits for the page to stand still, then measures where the words are and makes one
    /// move. It ends only on a measurement taken after a still page finds the words on the left, and a
    /// move is always followed by one more such measurement. A move is never judged from the page as it
    /// was before the move, or from the progression the place was saved with (that is the old
    /// layout's, and means another page once a verso or a column break has gone in).
    ///
    /// On a spread he is reading (`isCovered` false) it never puts a column break in: his words already
    /// on the left page stay where he is reading them. Any moves it does make there are held behind a
    /// picture of the page and shown as one change (build 20: a late look for his words moved the
    /// spread under his eyes, the verso's in-between spread and then his own).
    @MainActor
    public static func keepOnLeft(_ s: SpreadSurface, current: () -> Bool, maxPasses: Int = 8) async -> Bool? {
        var held = false
        let result = await settle(s, current: current, maxPasses: maxPasses) {
            // Before every move: a cover that was up when the settle began may have lifted since.
            guard !held, !s.isCovered else { return }
            held = await s.hold()
        }
        if held { await s.release(landed: current()) }
        return result
    }

    @MainActor
    private static func settle(_ s: SpreadSurface, current: () -> Bool, maxPasses: Int,
                               beforeMove: () async -> Void) async -> Bool? {
        var moved = false
        var pinTried = false
        var confirmed = false
        var readsLeft = readBudget
        for _ in 0..<maxPasses {
            guard current(), readsLeft > 0 else { return current() && moved ? true : nil }
            readsLeft -= await waitStill(s, current: current, reads: min(12, readsLeft))
            guard current(), let side = await s.wordsSide() else { return moved ? true : nil }
            switch side {
            case .before, .after:
                await beforeMove()
                await s.goToWords()
            case .left, .right:
                if !pinTried {
                    pinTried = true
                    // Only out of sight: on a page he is reading, words on the left page stay put.
                    if s.isCovered, await s.pinWords() {
                        await s.goToWords()
                        moved = true
                        confirmed = false
                        continue
                    }
                }
                if side == .left {
                    if !moved || confirmed { return moved ? true : nil }
                    confirmed = true
                    continue
                }
                await beforeMove()
                await s.toggleVerso()
                await s.goToWords()
            }
            moved = true
            confirmed = false
        }
        return moved ? true : nil
    }
}
