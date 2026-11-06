import Testing
@testable import GatefoldCore

/// The chapter's columns as the web view lays them out, with the navigator's habits that decide where
/// a reopened spread lands:
/// - it goes to a saved *progression* and snaps down to the spread that contains it, so a progression
///   saved in one layout names another page once a verso or a column break has added a column;
/// - after a rotation it applies its stored location again some time later, wherever the restore has
///   got to by then (`relayoutAt`, in surface calls).
/// Spreads are numbered from 0 and hold columns 2s and 2s+1. A verso adds a column before everything
/// and a column break at the words adds one at them (`pinnable` words sit well down their column).
@MainActor
private final class FakeSpreads: SpreadSurface {
    let naturalColumns: Int
    let wordsColumn: Int
    let pinnable: Bool
    let savedProgression: Double
    let relayoutAt: Int?
    var verso = false
    var pinned = false
    var spread: Int
    var ticks = 0
    var versoToggles = 0

    init(columns: Int, wordsColumn: Int, pinnable: Bool, startSpread: Int, relayoutAt: Int?) {
        naturalColumns = columns
        self.wordsColumn = wordsColumn
        self.pinnable = pinnable
        self.relayoutAt = relayoutAt
        // The place was saved as the words' own spread in this very layout.
        savedProgression = Double(wordsColumn / 2) / Double((columns + 1) / 2)
        spread = startSpread
    }

    var columns: Int { naturalColumns + (verso ? 1 : 0) + (pinned ? 1 : 0) }
    var spreadCount: Int { (columns + 1) / 2 }
    var column: Int { wordsColumn + (verso ? 1 : 0) + (pinned ? 1 : 0) }

    private func clamp() { spread = max(0, min(spreadCount - 1, spread)) }

    private func tick() {
        ticks += 1
        if ticks == relayoutAt { snapToSaved() }
    }

    private func snapToSaved() {
        spread = Int((savedProgression * Double(spreadCount) + 0.0007).rounded(.down))
        clamp()
    }

    func finish() { if let r = relayoutAt, ticks < r { snapToSaved() } }

    /// What a reader sees when the restore has ended: the words open the left page.
    var landed: Bool { column % 2 == 0 && spread == column / 2 }

    func wordsSide() async -> WordsSide? {
        tick()
        let c = column
        if c < 2 * spread { return .before }
        if c > 2 * spread + 1 { return .after }
        return c == 2 * spread ? .left : .right
    }

    func pinWords() async -> Bool {
        tick()
        guard pinnable, !pinned else { return false }
        pinned = true
        return true
    }

    func toggleVerso() async {
        tick()
        verso.toggle()
        versoToggles += 1
        clamp()
    }

    func goToSavedPlace() async { tick(); snapToSaved() }

    func goToWords() async { tick(); spread = column / 2; clamp() }

    func stepSpread(forward: Bool) async { tick(); spread += forward ? 1 : -1; clamp() }

    func stillness() async -> String? { tick(); return "\(spread)|\(columns)" }

    func beat() async { tick() }
}

/// The procedure before the converging one: each move judged from the page before it, and the saved
/// progression used to navigate. Kept to show the model reproduces the miss it left.
@MainActor
private func legacyKeepOnLeft(_ s: SpreadSurface) async -> Bool? {
    var now = await s.wordsSide()
    var stepped = false
    if now == .before || now == .after {
        await s.stepSpread(forward: now == .after)
        await s.beat()
        stepped = true
        now = await s.wordsSide()
    }
    var pinned = false
    if now == .left || now == .right, await s.pinWords() {
        pinned = true
        await s.beat()
        await s.goToSavedPlace()
        await s.beat()
        for _ in 0..<2 {
            switch await s.wordsSide() {
            case .after: await s.stepSpread(forward: true)
            case .before: await s.stepSpread(forward: false)
            default: break
            }
            await s.beat()
        }
        now = await s.wordsSide()
    }
    guard now == .right else { return stepped || pinned ? true : nil }
    await s.toggleVerso()
    await s.beat()
    await s.goToSavedPlace()
    await s.beat()
    for _ in 0..<2 {
        switch await s.wordsSide() {
        case .after: await s.stepSpread(forward: true)
        case .before: await s.stepSpread(forward: false)
        default: break
        }
        await s.beat()
    }
    return true
}

private struct Case: CustomStringConvertible {
    var columns: Int, wordsColumn: Int, pinnable: Bool, startSpread: Int, relayoutAt: Int?
    var description: String {
        "columns \(columns) words in column \(wordsColumn) pinnable \(pinnable) opened on spread \(startSpread) relayout at \(relayoutAt.map(String.init) ?? "never")"
    }
}

/// Every layout the reopen can meet: an even or odd column count, the words on either page of their
/// spread, near the top of their column or well down it, the navigator landing up to two spreads off,
/// and its relayout arriving at any point of the restore or not at all.
private let cases: [Case] = {
    var all: [Case] = []
    for columns in [50, 51, 52, 53] {
        for wordsColumn in 40...47 {
            for pinnable in [false, true] {
                for offset in -2...2 {
                    for relayout in [nil] + (1...6).map { Optional($0) } {
                        all.append(Case(columns: columns, wordsColumn: wordsColumn, pinnable: pinnable,
                                        startSpread: wordsColumn / 2 + offset, relayoutAt: relayout))
                    }
                }
            }
        }
    }
    return all
}()

@MainActor
struct SpreadSettlerTests {
    private func fake(_ c: Case) -> FakeSpreads {
        FakeSpreads(columns: c.columns, wordsColumn: c.wordsColumn, pinnable: c.pinnable,
                    startSpread: c.startSpread, relayoutAt: c.relayoutAt)
    }

    /// The reopen of the CI miss: words that open the left page of spread 22 of 26 (the chapter's
    /// first page) and the navigator's relayout arriving after the verso went in.
    @Test func aRelayoutAfterTheVersoDoesNotLeaveTheWordsBeside() async {
        let page = FakeSpreads(columns: 52, wordsColumn: 45, pinnable: false, startSpread: 22, relayoutAt: 8)
        _ = await SpreadSettler.keepOnLeft(page, current: { true })
        page.finish()
        #expect(page.landed)
    }

    @Test func theConvergingSettlerLandsTheWordsOnTheLeftInEveryLayout() async {
        var missed: [Case] = []
        for c in cases {
            let page = fake(c)
            _ = await SpreadSettler.keepOnLeft(page, current: { true })
            page.finish()
            if !page.landed { missed.append(c) }
        }
        print("SETTLER converging: missed \(missed.count) of \(cases.count)")
        #expect(missed.isEmpty, "first miss: \(missed.first.map(String.init(describing:)) ?? "")")
    }

    @Test func theEarlierProcedureLeftTheWordsBesideInSomeLayouts() async {
        var missed = 0
        var missedWithoutRelayout = 0
        for c in cases {
            let page = fake(c)
            _ = await legacyKeepOnLeft(page)
            page.finish()
            if !page.landed {
                missed += 1
                if c.relayoutAt == nil { missedWithoutRelayout += 1 }
            }
        }
        print("SETTLER earlier procedure: missed \(missed) of \(cases.count), \(missedWithoutRelayout) with no relayout")
        #expect(missed > 0)
    }

    @Test func probeCiShape() async {
        for r in 1...10 {
            let a = FakeSpreads(columns: 52, wordsColumn: 45, pinnable: false, startSpread: 22, relayoutAt: r)
            _ = await legacyKeepOnLeft(a); a.finish()
            let b = FakeSpreads(columns: 52, wordsColumn: 44, pinnable: false, startSpread: 22, relayoutAt: r)
            _ = await legacyKeepOnLeft(b); b.finish()
            print("PROBE relayout \(r): odd-words legacy landed \(a.landed) (spread \(a.spread) col \(a.column) cols \(a.columns)); even-words legacy landed \(b.landed) (spread \(b.spread) col \(b.column))")
        }
    }

    @Test func theVersoGoesInOnceForWordsOnTheRightPage() async {
        let page = FakeSpreads(columns: 52, wordsColumn: 45, pinnable: false, startSpread: 22, relayoutAt: nil)
        _ = await SpreadSettler.keepOnLeft(page, current: { true })
        #expect(page.landed)
        #expect(page.versoToggles == 1)
    }

    @Test func wordsAlreadyOnTheLeftAreLeftAlone() async {
        let page = FakeSpreads(columns: 52, wordsColumn: 44, pinnable: false, startSpread: 22, relayoutAt: nil)
        let moved = await SpreadSettler.keepOnLeft(page, current: { true })
        #expect(moved == nil)
        #expect(page.versoToggles == 0 && !page.pinned)
    }

    @Test func aRestoreThatHasBeenReplacedStopsTouchingThePage() async {
        let page = FakeSpreads(columns: 52, wordsColumn: 45, pinnable: false, startSpread: 22, relayoutAt: nil)
        _ = await SpreadSettler.keepOnLeft(page, current: { false })
        #expect(page.versoToggles == 0)
    }
}
