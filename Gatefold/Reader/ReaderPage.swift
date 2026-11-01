import GatefoldCore
import ReadiumShared

/// What the reader model asks of the page on screen. `ReaderHostController` is the real one;
/// unit tests drive the model's landing, settling and sync bookkeeping through a scripted one.
@MainActor
protocol ReaderPage: AnyObject {
    /// Where the navigator is (the page boundary Readium reports).
    var currentLocation: Locator? { get }
    @discardableResult func go(to locator: Locator) async -> Bool
    func go(to link: ReadiumShared.Link) async
    /// What's on screen now: the resource, its progression range and the visible text.
    func visibleRange() async -> VisibleRange?
    /// Where `quote` is in the resource on screen, as a progression; nil when it isn't there.
    func progression(of quote: String) async -> Double?
    /// The first words on the page the reader is on.
    func currentAnchor() async -> (ReadingAnchor, Locator)?
}
