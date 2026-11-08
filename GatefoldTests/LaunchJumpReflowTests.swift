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
    /// Off: the page shows the place, but Readium's own report stays on the file start, never catching up.
    var readiumCatchesUp = true
    /// The page on screen, when Readium names another.
    private var shown: Locator?
    private var target: Locator?
    private var reads = 0
    private var landed = false

    init(at start: Locator, readsToLand: Int, midFlightRead: Int = 0) {
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
                if readiumCatchesUp {
                    currentLocation = target
                    Task { await self.model?.locationDidChange(target) }
                } else {
                    shown = target
                }
            }
        }
        guard let here = shown ?? currentLocation else { return nil }
        let start = here.locations.progression ?? 0
        return VisibleRange(href: here.href.string, start: start, end: min(1, start + 0.03), text: words(here))
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
        let model = ReaderModel(book: book, publication: publication, app: app, page: page, goTo: 0.31,
                                jumpBeat: { await Task.yield() })
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
        for _ in 0..<200 where savedPlace()?.locations.progression != target.locations.progression || model.placeOwed {
            try await Task.sleep(for: .milliseconds(25))
        }
        // The owed record has nothing left to write: a later overwrite would show here.
        #expect(!model.placeOwed, "the reflow still owes a place")
        let saved = try #require(savedPlace(), "the launch jump kept no place")
        #expect(saved.href.string == target.href.string)
        #expect(saved.locations.progression == target.locations.progression,
                "kept at \(saved.locations.progression ?? -1) in its file, not where the jump landed (\(target.locations.progression ?? -1))")
        model.close()
    }

    /// Readium's own report never reaches the place the page shows: the jump runs out of reads, and the
    /// place kept is where he was sent, never the file start Readium still names.
    @Test func aJumpReadiumNeverCatchesUpKeepsItsTarget() async throws {
        let sync = StubSync()
        await sync.setLibrary(.success([ReaderSyncTests.frankenstein]))
        await sync.setRemote(nil)
        let app = AppModel(sync: sync, libraryRoot: URL.temporaryDirectory.appending(path: "launch-jump-stale-\(UUID().uuidString)"))
        await app.library.refresh()
        let publication = try await ReaderSyncTests.publication()
        let book = try #require(app.library.book(ReaderSyncTests.frankenstein.fastHash))
        let first = publication.readingOrder[0].url().string
        let opening = Locator(href: try #require(AnyURL(string: first)), mediaType: .xhtml,
                              locations: .init(progression: 0, totalProgression: 0))
        let page = TwoStepJumpPage(at: opening, readsToLand: 2)
        page.readiumCatchesUp = false
        let model = ReaderModel(book: book, publication: publication, app: app, page: page, goTo: 0.31,
                                jumpBeat: { await Task.yield() })
        page.model = model
        let target = try #require(await ReaderSyncTests.locate(publication, 0.31))
        await model.load()
        func savedPlace() -> Locator? {
            app.library.book(ReaderSyncTests.frankenstein.fastHash)?.locatorJSON.flatMap { try? Locator(jsonString: $0) }
        }
        let saved = try #require(savedPlace(), "the launch jump kept no place")
        #expect(saved.href.string == target.href.string)
        #expect(saved.locations.progression == target.locations.progression,
                "kept at \(saved.locations.progression ?? -1) in its file (Readium's stale file start), not the place he was sent to")
        // Only the place: the running head names what Readium shows until it reports again.
        #expect(model.location?.locations.progression == page.currentLocation?.locations.progression,
                "the running head named the unreached target")
        model.close()
    }

    /// The same jump, ending while a rotation's reflow still runs: the reflow owes the place, and pays it
    /// with where he was sent, not Readium's stale file start.
    @Test func aJumpThatNeverLandsUnderAReflowKeepsItsTarget() async throws {
        let sync = StubSync()
        await sync.setLibrary(.success([ReaderSyncTests.frankenstein]))
        await sync.setRemote(nil)
        let app = AppModel(sync: sync, libraryRoot: URL.temporaryDirectory.appending(path: "launch-jump-stale-reflow-\(UUID().uuidString)"))
        await app.library.refresh()
        let publication = try await ReaderSyncTests.publication()
        let book = try #require(app.library.book(ReaderSyncTests.frankenstein.fastHash))
        let first = publication.readingOrder[0].url().string
        let opening = Locator(href: try #require(AnyURL(string: first)), mediaType: .xhtml,
                              locations: .init(progression: 0, totalProgression: 0))
        let page = TwoStepJumpPage(at: opening, readsToLand: 2)
        page.readiumCatchesUp = false
        let model = ReaderModel(book: book, publication: publication, app: app, page: page, goTo: 0.31,
                                jumpBeat: { await Task.yield() })
        page.model = model
        model.keeper.reflowWillBegin(.rotation)
        model.reflowDidBegin()
        let target = try #require(await ReaderSyncTests.locate(publication, 0.31))
        await model.load()
        #expect(model.placeOwed, "the reflow under way owes the jump's place")
        model.keeper.restoreDidComplete()
        model.reflowDidFinish(visible: await page.visibleRange())
        func savedPlace() -> Locator? {
            app.library.book(ReaderSyncTests.frankenstein.fastHash)?.locatorJSON.flatMap { try? Locator(jsonString: $0) }
        }
        // Waited on as events: the owed record runs in its own task.
        for _ in 0..<200 where savedPlace()?.locations.progression != target.locations.progression || model.placeOwed {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(!model.placeOwed, "the reflow still owes a place")
        let saved = try #require(savedPlace(), "the launch jump kept no place")
        #expect(saved.href.string == target.href.string)
        #expect(saved.locations.progression == target.locations.progression,
                "kept at \(saved.locations.progression ?? -1) in its file, not the place he was sent to")
        model.close()
    }

    /// A touch under the reflow: one that only showed the controls, a slide or scroll (a touch that
    /// brought a report), or a slide and then a tap for the controls before the reflow ends.
    enum Touch { case controlsTap, slide, slideThenControlsTap }

    /// The jump that never lands, owed by a reflow, with a touch before the reflow ends.
    private func owedJumpAfterATouch(_ touch: Touch) async throws -> (saved: Locator, target: Locator, readium: Locator) {
        let sync = StubSync()
        await sync.setLibrary(.success([ReaderSyncTests.frankenstein]))
        await sync.setRemote(nil)
        let app = AppModel(sync: sync, libraryRoot: URL.temporaryDirectory.appending(path: "launch-jump-touch-\(UUID().uuidString)"))
        await app.library.refresh()
        let publication = try await ReaderSyncTests.publication()
        let book = try #require(app.library.book(ReaderSyncTests.frankenstein.fastHash))
        let first = publication.readingOrder[0].url().string
        let opening = Locator(href: try #require(AnyURL(string: first)), mediaType: .xhtml,
                              locations: .init(progression: 0, totalProgression: 0))
        let page = TwoStepJumpPage(at: opening, readsToLand: 2)
        page.readiumCatchesUp = false
        let model = ReaderModel(book: book, publication: publication, app: app, page: page, goTo: 0.31,
                                jumpBeat: { await Task.yield() })
        page.model = model
        model.keeper.reflowWillBegin(.rotation)
        model.reflowDidBegin()
        let target = try #require(await ReaderSyncTests.locate(publication, 0.31))
        await model.load()
        #expect(model.placeOwed, "the reflow under way owes the jump's place")
        let readium = try #require(page.currentLocation)
        await touchUnderTheReflow(touch, model: model, readium: readium)
        model.keeper.restoreDidComplete()
        model.reflowDidFinish(visible: await page.visibleRange())
        func savedPlace() -> Locator? {
            app.library.book(ReaderSyncTests.frankenstein.fastHash)?.locatorJSON.flatMap { try? Locator(jsonString: $0) }
        }
        let want = touch == .controlsTap ? target : readium
        for _ in 0..<200 where savedPlace()?.locations.progression != want.locations.progression || model.placeOwed {
            try await Task.sleep(for: .milliseconds(25))
        }
        let saved = try #require(savedPlace(), "the owed place was never kept")
        model.close()
        return (saved, target, readium)
    }

    private func touchUnderTheReflow(_ touch: Touch, model: ReaderModel, readium: Locator) async {
        model.noteInteraction()
        if touch != .controlsTap { await model.locationDidChange(readium) }
        if touch != .slide {
            if touch == .slideThenControlsTap { model.noteInteraction() }
            model.controlsTapped(visible: true)
        }
    }

    /// The same jump and touch, but he leaves before the reflow ends: what the reflow owes as he goes.
    private func owedOnLeavingAfterATouch(_ touch: Touch) async throws -> (owed: Locator, target: Locator, readium: Locator) {
        let sync = StubSync()
        await sync.setLibrary(.success([ReaderSyncTests.frankenstein]))
        await sync.setRemote(nil)
        let app = AppModel(sync: sync, libraryRoot: URL.temporaryDirectory.appending(path: "launch-jump-leave-\(UUID().uuidString)"))
        await app.library.refresh()
        let publication = try await ReaderSyncTests.publication()
        let book = try #require(app.library.book(ReaderSyncTests.frankenstein.fastHash))
        let first = publication.readingOrder[0].url().string
        let opening = Locator(href: try #require(AnyURL(string: first)), mediaType: .xhtml,
                              locations: .init(progression: 0, totalProgression: 0))
        let page = TwoStepJumpPage(at: opening, readsToLand: 2)
        page.readiumCatchesUp = false
        let model = ReaderModel(book: book, publication: publication, app: app, page: page, goTo: 0.31,
                                jumpBeat: { await Task.yield() })
        page.model = model
        model.keeper.reflowWillBegin(.rotation)
        model.reflowDidBegin()
        let target = try #require(await ReaderSyncTests.locate(publication, 0.31))
        await model.load()
        #expect(model.placeOwed, "the reflow under way owes the jump's place")
        let readium = try #require(page.currentLocation)
        await touchUnderTheReflow(touch, model: model, readium: readium)
        let owed = try #require(model.owedPlaceOnLeaving(), "leaving under the reflow owed nothing")
        model.close()
        return (owed, target, readium)
    }

    /// A tap that only shows the controls is no move: the reflow still pays where he was sent.
    @Test func aControlsTapUnderAReflowKeepsTheUnreachedJumpsTarget() async throws {
        let (saved, target, _) = try await owedJumpAfterATouch(.controlsTap)
        #expect(saved.href.string == target.href.string)
        #expect(saved.locations.progression == target.locations.progression,
                "kept at \(saved.locations.progression ?? -1), not the jump's target (\(target.locations.progression ?? -1))")
    }

    /// A slide or scroll (a touch that brought a report) is his own move: his page is the place, not the target.
    @Test func aSlideUnderAReflowKeepsHisPageNotTheTarget() async throws {
        let (saved, target, readium) = try await owedJumpAfterATouch(.slide)
        #expect(saved.locations.progression == readium.locations.progression,
                "kept at \(saved.locations.progression ?? -1), not his page (\(readium.locations.progression ?? -1))")
        #expect(saved.locations.progression != target.locations.progression)
    }

    /// A slide and then a tap for the controls, both under the reflow: the slide was his move, and the
    /// tap that follows doesn't bring back the target (the slide's report was dropped for the reflow).
    @Test func aSlideThenAControlsTapUnderAReflowKeepsHisPage() async throws {
        let (saved, target, readium) = try await owedJumpAfterATouch(.slideThenControlsTap)
        #expect(saved.locations.progression == readium.locations.progression,
                "kept at \(saved.locations.progression ?? -1), not his page (\(readium.locations.progression ?? -1))")
        #expect(saved.locations.progression != target.locations.progression)
    }

    /// Leaving under the reflow after a tap that only showed the controls owes the jump's target.
    @Test func leavingAfterAControlsTapUnderAReflowOwesTheJumpsTarget() async throws {
        let (owed, target, _) = try await owedOnLeavingAfterATouch(.controlsTap)
        #expect(owed.href.string == target.href.string)
        #expect(owed.locations.progression == target.locations.progression,
                "owed \(owed.locations.progression ?? -1), not the jump's target (\(target.locations.progression ?? -1))")
    }

    /// Leaving under the reflow after a slide and a controls tap owes his page, not the target.
    @Test func leavingAfterASlideThenAControlsTapUnderAReflowOwesHisPage() async throws {
        let (owed, target, readium) = try await owedOnLeavingAfterATouch(.slideThenControlsTap)
        #expect(owed.locations.progression == readium.locations.progression,
                "owed \(owed.locations.progression ?? -1), not his page (\(readium.locations.progression ?? -1))")
        #expect(owed.locations.progression != target.locations.progression)
    }
}
