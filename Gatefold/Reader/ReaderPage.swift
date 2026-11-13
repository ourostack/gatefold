import GatefoldCore
import ReadiumShared

/// What the reader model asks of the page on screen. `ReaderHostController` is the real one;
/// unit tests drive the model's landing, settling and sync bookkeeping through a scripted one.
@MainActor
protocol ReaderPage: AnyObject {
    /// Where the navigator is (the page boundary Readium reports).
    var currentLocation: Locator? { get }
    /// A page turn is animating: he chose it, though it hasn't landed yet.
    var isTurning: Bool { get }
    @discardableResult func go(to locator: Locator) async -> Bool
    /// The chapter on its way is still loading (Readium's spinner up, or a web view still loading): a jump
    /// there is waited for, not given up on.
    var isLoadingChapter: Bool { get }
    func go(to link: ReadiumShared.Link) async
    /// What's on screen now: the resource, its progression range and the visible text.
    func visibleRange() async -> VisibleRange?
    /// The page on screen, start and end from one live read, in the document it names (a jump's landing).
    func pageRange() async -> VisibleRange?
    /// Where `quote` is in the resource on screen, as a progression; nil when it isn't there.
    func progression(of quote: String) async -> Double?
    /// Where the element `id` starts in the resource on screen, as a progression, once the resource is
    /// laid out; nil when it isn't there or the layout isn't done.
    func progression(ofFragment id: String) async -> Double?
    /// The first words on the page the reader is on.
    func currentAnchor() async -> (ReadingAnchor, Locator)?
    /// The same words, read only: nothing on screen (the running head) takes them up.
    func wordsOnPage() async -> Locator?
    /// Starts loading `locator`'s page out of sight, so a jump there later is quick.
    func prepareStandby(at locator: Locator)
    func dropStandby()
    /// Shows the page `prepareStandby` loaded for `locator`; false when there is none.
    func promoteStandby(for locator: Locator) async -> Bool
    /// The chapter on screen and where the screen is in its columns, for page numbers.
    func screenGeometry() async -> (href: String, geometry: ScreenPageGeometry)?
    /// Lays `hrefs` out out of sight, one by one, at the page's layout, and hands back each one's columns;
    /// `finished` once the count has ended by itself (not when stopped).
    func countPages(_ hrefs: [String], record: @escaping @MainActor (String, Int) -> Void, finished: @escaping @MainActor () -> Void)
    func stopCounting()
    /// Puts `anchor`'s words back on the spread's left page if a late layout moved them; `stillWanted`
    /// turns false once the reader has moved or the page is gone.
    func keepWordsOnLeft(_ anchor: ReadingAnchor, stillWanted: @escaping @MainActor () -> Bool) async
    /// A jump's landing put on the spread a restore of its place would show (`SpreadSettler`, `.restore`).
    func settleLanding(_ anchor: ReadingAnchor, stillWanted: @escaping @MainActor () -> Bool) async
    /// A standby swap retired the page an open reflow was laying out: that reflow's cover, retries and
    /// generation end with it (the model ends its own side, `keeper` and the reflow's notes).
    func endReflowForSwap()
}

extension ReaderPage {
    func keepWordsOnLeft(_ anchor: ReadingAnchor, stillWanted: @escaping @MainActor () -> Bool) async {}
    func settleLanding(_ anchor: ReadingAnchor, stillWanted: @escaping @MainActor () -> Bool) async {}
    var isLoadingChapter: Bool { false }
    var isTurning: Bool { false }
    func wordsOnPage() async -> Locator? { await currentAnchor()?.1 }
    func prepareStandby(at locator: Locator) {}
    func dropStandby() {}
    func promoteStandby(for locator: Locator) async -> Bool { false }
    func screenGeometry() async -> (href: String, geometry: ScreenPageGeometry)? { nil }
    func pageRange() async -> VisibleRange? { await visibleRange() }
    func progression(ofFragment id: String) async -> Double? { nil }
    func countPages(_ hrefs: [String], record: @escaping @MainActor (String, Int) -> Void, finished: @escaping @MainActor () -> Void) {}
    func stopCounting() {}
    func endReflowForSwap() {}
}
