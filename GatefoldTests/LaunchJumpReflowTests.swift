import Foundation
import GatefoldCore
import ReadiumShared
import Testing
@testable import Gatefold

/// A page a launch jump reaches in two steps, the way Readium does on a cold web view: the jump first
/// shows its file's first page and reports it, and only some reads later shows the place itself. A
/// rotation reflow (an iPad opened on its side) is under way when the jump begins and ends between the
/// two steps, from `midFlight`. Counted in reads of the page, never seconds.
@MainActor
final class TwoStepJumpPage: ReaderPage {
    var currentLocation: Locator?
    weak var model: ReaderModel?
    /// Reads of the page on screen before the jump shows its place.
    let readsToLand: Int
    /// Called once, at this read, while the jump is still short of its place.
    let midFlightRead: Int
    var midFlight: (@MainActor () async -> Void)?
    private var target: Locator?
    private var reads = 0
    private var landed = false

    init(at start: Locator, readsToLand: Int, midFlightRead: Int) {
        currentLocation = start
        self.readsToLand = readsToLand
        self.midFlightRead = midFlightRead
    }

    private func words(_ here: Locator) -> String { "words at \(here.href.string) \(here.locations.progression ?? -1) on down the page" }

    @discardableResult func go(to locator: Locator) async -> Bool {
        guard target == nil else { return true }
        target = locator
        // Readium's first step: the file's first page, reported as where it is.
        let fileStart = locator.copy(locations: {
            $0.totalProgression = ($0.totalProgression ?? 0) - 0.01
            $0.progression = 0
        })
        currentLocation = fileStart
        Task { await self.model?.locationDidChange(fileStart) }
        return true
    }

    func go(to link: ReadiumShared.Link) async {}

    func pageRange() async -> VisibleRange? {
        if let target, !landed {
            reads += 1
            if reads == midFlightRead, let midFlight { self.midFlight = nil; await midFlight() }
            if reads >= readsToLand {
                landed = true
                currentLocation = target
                Task { await self.model?.locationDidChange(target) }
            }
        }
        return await visibleRange()
    }

    func visibleRange() async -> VisibleRange? {
        guard let here = currentLocation else { return nil }
        let start = here.locations.progression ?? 0
        return VisibleRange(href: here.href.string, start: start, end: min(1, start + 0.03), text: words(here))
    }

    func progression(of quote: String) async -> Double? { currentLocation?.locations.progression }

    func currentAnchor() async -> (ReadingAnchor, Locator)? {
        guard let here = currentLocation else { return nil }
        let text = words(here)
        let anchor = ReadingAnchor(href: here.href.string, progression: here.locations.progression ?? 0, text: ReaderJS.normalize(text))
        return (anchor, here.copy(text: { $0 = Locator.Text(highlight: text) }))
    }
}

/// A launch jump's place is where it lands. A rotation reflow that ends while the jump is still on its
/// way keeps the move it held, and that move is the jump: kept at its file's first page, every reopen
/// came back a few pages early (main at 379fda7, iPad taps: `PageFurnitureUITests` reopened on the
/// chapter start, the log's "recorded the move a reflow held" 1.3 s before "the launch jump ... landed").
@MainActor @Suite(.serialized) struct LaunchJumpReflowTests {
    @Test func aReflowEndingMidJumpKeepsThePlaceTheJumpLandsOn() async throws {
        let defaults = UserDefaults.standard
        let savedGoTo = defaults.object(forKey: "GatefoldGoTo")
        defaults.set(0.31, forKey: "GatefoldGoTo")
        defer { if let savedGoTo { defaults.set(savedGoTo, forKey: "GatefoldGoTo") } else { defaults.removeObject(forKey: "GatefoldGoTo") } }

        let sync = StubSync()
        await sync.setLibrary(.success([ReaderSyncTests.frankenstein]))
        await sync.setRemote(nil)
        let app = AppModel(sync: sync, libraryRoot: URL.temporaryDirectory.appending(path: "launch-jump-reflow-\(UUID().uuidString)"))
        await app.library.refresh()
        let publication = try await ReaderSyncTests.publication()
        let book = try #require(app.library.book(ReaderSyncTests.frankenstein.fastHash))
        let first = publication.readingOrder[0].url().string
        let opening = Locator(href: try #require(AnyURL(string: first)), mediaType: .xhtml,
                              locations: .init(progression: 0, totalProgression: 0))
        // The reflow ends on the 2nd read, the jump shows its place on the 6th.
        let page = TwoStepJumpPage(at: opening, readsToLand: 6, midFlightRead: 2)
        let model = ReaderModel(book: book, publication: publication, app: app, page: page)
        page.model = model
        page.midFlight = { [weak model] in
            guard let model else { return }
            model.keeper.restoreDidComplete()
            model.reflowDidFinish(visible: await page.visibleRange())
        }
        // An iPad opened on its side: the rotation's reflow begins before the book has loaded.
        model.keeper.reflowWillBegin(.rotation)
        model.reflowDidBegin()

        let target = try #require(await ReaderSyncTests.locate(publication, 0.31))
        await model.load()
        // load() returns after the jump; the owed record and the landing's report run in their own
        // tasks. Waited on as events: until the owed place is settled (kept or given up), counted.
        func savedPlace() -> Locator? {
            app.library.book(ReaderSyncTests.frankenstein.fastHash)?.locatorJSON.flatMap { try? Locator(jsonString: $0) }
        }
        for _ in 0..<200 where savedPlace()?.locations.progression != target.locations.progression {
            try await Task.sleep(for: .milliseconds(25))
        }
        let saved = try #require(savedPlace(), "the launch jump kept no place")
        #expect(saved.href.string == target.href.string)
        #expect(saved.locations.progression == target.locations.progression,
                "kept at \(saved.locations.progression ?? -1) in its file, not where the jump landed (\(target.locations.progression ?? -1))")
        model.close()
    }
}
