import Foundation
import GatefoldCore
import ReadiumShared
import Testing
@testable import Gatefold

/// The saved place moves only on a deliberate turn or a jump he chose, and every jump that is not a
/// turn can be undone with one tap, without opening the controls (build 20: "fucked my location with
/// accidental navigation").
@MainActor @Suite(.serialized) struct PlaceInvariantTests {
    private typealias S = ReaderSyncTests
    private var bookID: String { S.frankenstein.fastHash }

    private func saved(_ f: S.Fixture) -> String? { f.app.library.book(bookID)?.locatorJSON }

    /// A first open with nothing ahead in the Cloud shows the book's own page. When the InkPad's place
    /// turns up later (the app coming back to the foreground), it is offered, never landed on: build 20
    /// moved the page and the saved place under him while he read.
    @Test func aCloudPlaceFoundAfterThePageShowsIsOfferedNotLanded() async throws {
        let f = try await S.make(remote: { _, _ in nil }, startAt: 0.02)
        await f.model.load()
        #expect(f.model.pageReady)
        let shown = try #require(f.page.currentLocation)
        let jumpsBefore = f.page.jumps.count
        let placeBefore = saved(f)

        // The InkPad reads on; the app comes back to the foreground and asks again.
        await f.sync.setRemote(try await S.inkPadPlace(f.publication, f.mapper, index: 12, percent: 40))
        await f.model.checkRemote()
        try await Task.sleep(for: .milliseconds(300))

        #expect(f.page.jumps.count == jumpsBefore, "the page jumped to the Cloud place without being asked")
        #expect(f.page.currentLocation?.href == shown.href, "the page he was reading moved")
        #expect(saved(f) == placeBefore, "the saved place moved without a turn or a chosen jump")
        #expect(f.model.suggestion != nil, "the Cloud place is offered instead")
        f.model.close()
    }

    /// A Cloud reply slower than the cover's patience: the page shows first (`forceReady`), he reads it
    /// without turning, and then the reply comes. It is offered; the page he is reading stays.
    @Test func aLateCloudReplyNeverMovesThePageHeIsReading() async throws {
        let f = try await S.make(remote: { pub, mapper in try await S.inkPadPlace(pub, mapper, index: 12, percent: 40) },
                                 book: { $0.remote = ReadingPosition(cfi: nil, totalProgression: 0.40, updated: Date(), source: .pocketBookNative) })
        await f.sync.setRemoteDelay(.milliseconds(1500))
        let loading = Task { await f.model.load() }
        for _ in 0..<200 where await f.sync.remoteReads == 0 { try await Task.sleep(for: .milliseconds(25)) }
        f.model.forceReady()
        for _ in 0..<200 where !f.model.pageReady { try await Task.sleep(for: .milliseconds(25)) }
        #expect(f.model.pageReady, "the page is showing while the Cloud is still answering")
        let reading = try #require(f.page.currentLocation)
        await loading.value
        #expect(f.page.jumps.isEmpty, "the late reply moved the page he was reading")
        #expect(f.page.currentLocation?.href == reading.href)
        #expect(saved(f) == nil, "the place was saved without a move of his")
        #expect(f.model.suggestion != nil, "the InkPad's place is offered instead")
        f.model.close()
    }

    /// Landing on the InkPad's place at a first open is a jump he didn't choose: the way back is on
    /// screen without the controls.
    @Test func theFirstOpenLandingCanBeUndone() async throws {
        let f = try await S.make(remote: { pub, mapper in try await S.inkPadPlace(pub, mapper, index: 12, percent: 40) })
        await f.model.load()
        #expect(!f.page.jumps.isEmpty, "the first open lands on the InkPad's place")
        #expect(f.model.backLocator != nil, "the Cloud landing has no way back")
        #expect(f.model.showJumpBack, "the way back needs the controls opened first")
        f.model.close()
    }

    enum Jump: String, CaseIterable, Sendable { case contents, link, highlight, scrubber }

    /// Every jump that is not a turn shows the way back without the controls.
    @Test(arguments: Jump.allCases) func everyJumpShowsTheWayBackWithoutTheControls(_ jump: Jump) async throws {
        let f = try await S.make(remote: { _, _ in nil }, startAt: 0.05)
        await f.model.load()
        let start = try #require(f.page.currentLocation)
        await f.model.locationDidChange(start)
        #expect(!f.model.chromeVisible)
        switch jump {
        case .contents:
            let entry = try #require(f.model.toc.last(where: { $0.progression > 0.3 }))
            await f.model.go(to: entry)
        case .link:
            await f.model.follow(f.publication.readingOrder[14])
        case .highlight:
            let far = try #require(await S.locate(f.publication, 0.6))
            await f.model.go(to: far, rememberBack: true)
        case .scrubber:
            await f.model.go(toProgression: 0.7, rememberBack: true)
        }
        #expect(f.model.backLocator != nil, "\(jump): no way back")
        #expect(f.model.showJumpBack, "\(jump): the way back is only in the controls")
        f.model.close()
    }

    /// The way back stays until he reads on (a few turns), not for a few seconds: a jump he didn't
    /// notice is still one tap to undo when he does.
    @Test func theWayBackStaysUntilHeReadsOn() async throws {
        let f = try await S.make(remote: { _, _ in nil }, startAt: 0.05)
        await f.model.load()
        await f.model.locationDidChange(try #require(f.page.currentLocation))
        await f.model.follow(f.publication.readingOrder[14])
        #expect(f.model.showJumpBack)
        for turn in 1...3 {
            let here = try #require(f.page.currentLocation)
            // An edge tap: a touch on the page, then the turn lands.
            f.model.noteInteraction()
            f.page.currentLocation = here.copy(locations: { $0.progression = ($0.progression ?? 0) + 0.04 })
            f.model.userTurnedPage()
            try await Task.sleep(for: .milliseconds(100))
            #expect(f.model.showJumpBack == (turn < 3), "after \(turn) turns")
        }
        f.model.close()
    }

    /// Slide mode: Readium's own swipes never call `userTurnedPage`, so the pill counts his swipes from
    /// the reports they bring. The jump's own landing report and taps that only show or hide the
    /// controls are not reading on.
    @Test func swipesRetireTheWayBackButTapsAndTheLandingDoNot() async throws {
        let f = try await S.make(remote: { _, _ in nil }, startAt: 0.05)
        f.model.setPreferences { $0.pageTurn = .slide }
        await f.model.load()
        await f.model.locationDidChange(try #require(f.page.currentLocation))
        await f.model.go(toProgression: 0.6, rememberBack: true)
        // The jump's landing, reported with no touch.
        await f.model.locationDidChange(try #require(f.page.currentLocation))
        #expect(f.model.showJumpBack, "the jump's own landing counted as reading on")
        // Taps that show and hide the controls: a touch each, then the layout reports the same page.
        for visible in [true, false, true, false] {
            f.model.noteInteraction()
            f.model.controlsTapped(visible: visible)
            await f.model.locationDidChange(try #require(f.page.currentLocation))
        }
        #expect(f.model.showJumpBack, "taps on the controls counted as reading on")
        for swipe in 1...3 {
            f.model.noteInteraction()
            let here = try #require(f.page.currentLocation)
            let next = here.copy(locations: { $0.progression = ($0.progression ?? 0) + 0.04; $0.totalProgression = ($0.totalProgression ?? 0) + 0.002 })
            f.page.currentLocation = next
            await f.model.locationDidChange(next)
            #expect(f.model.showJumpBack == (swipe < 3), "after \(swipe) swipes")
        }
        f.model.close()
    }

    /// Back is itself a jump: a stray tap on it is one tap to undo too.
    @Test func goingBackCanBeUndone() async throws {
        let f = try await S.make(remote: { _, _ in nil }, startAt: 0.05)
        await f.model.load()
        await f.model.locationDidChange(try #require(f.page.currentLocation))
        // Back tapped before Readium has reported the jump.
        f.page.reportsJumps = false
        await f.model.go(toProgression: 0.7, rememberBack: true)
        let jumped = try #require(f.page.currentLocation)
        await f.model.goBack()
        let back = try #require(f.model.backLocator, "Back left no way to return")
        #expect(abs((back.locations.totalProgression ?? 0) - (jumped.locations.totalProgression ?? 1)) < 0.01)
        #expect(f.model.showJumpBack)
        f.model.close()
    }

    /// Back never takes its own pill down while it goes back: on the Duo, a pill taken down under his
    /// finger and put up again never showed, so going back could not be undone. A second tap meanwhile
    /// is not a second jump.
    @Test func theWayBackStaysUpWhileItGoesBack() async throws {
        let f = try await S.make(remote: { _, _ in nil }, startAt: 0.05)
        await f.model.load()
        await f.model.locationDidChange(try #require(f.page.currentLocation))
        await f.model.go(toProgression: 0.7, rememberBack: true)
        #expect(f.model.showJumpBack)
        var midJump: [(shown: Bool, hasPlace: Bool)] = []
        f.page.onGo = { midJump.append((f.model.showJumpBack, f.model.backLocator != nil)) }
        // Reading the words after a jump takes a moment, as on a device: the second tap lands mid-way.
        f.page.anchorDelay = .milliseconds(150)
        let jumpsBefore = f.page.jumps.count
        async let first: Void = f.model.goBack()
        async let second: Void = f.model.goBack()
        _ = await (first, second)
        #expect(f.page.jumps.count == jumpsBefore + 1, "a second tap on Back made a second jump")
        #expect(!midJump.isEmpty && midJump.allSatisfy { $0.shown && $0.hasPlace }, "the pill went down while Back went back")
        #expect(f.model.showJumpBack && f.model.backLocator != nil)
        f.model.close()
    }

    /// A Back whose jump never comes back (a load that hangs) frees Back after its reads run out:
    /// the next tap goes back.
    @Test func aBackThatNeverLandsLeavesBackWorking() async throws {
        let f = try await S.make(remote: { _, _ in nil }, startAt: 0.05)
        await f.model.load()
        await f.model.locationDidChange(try #require(f.page.currentLocation))
        await f.model.go(toProgression: 0.7, rememberBack: true)
        f.model.backBeat = { await Task.yield() }
        f.page.holdsJumps = true
        let before = f.page.jumps.count
        let hung = Task { await f.model.goBack() }
        for _ in 0..<100 where f.page.jumps.count == before { await Task.yield() }
        #expect(f.page.jumps.count == before + 1 && f.model.isGoingBack, "Back's jump never started")
        for _ in 0..<(JumpLanding.reads * 4) where f.model.isGoingBack { await Task.yield() }
        #expect(!f.model.isGoingBack, "a hung Back left Back dead")
        f.page.holdsJumps = false
        await f.model.goBack()
        #expect(f.page.jumps.count == before + 2, "the next Back made no jump")
        #expect(f.model.showJumpBack && f.model.backLocator != nil)
        let wayBack = f.model.backLocator
        f.page.releaseJumps()
        await hung.value
        // The hung trip coming back late changes nothing: the newer Back's way back stands.
        #expect(f.model.backLocator == wayBack && f.model.showJumpBack, "a late Back undid the newer one")
        #expect(!f.model.isGoingBack)
        f.model.close()
    }

    /// A Back freed by its count, then a jump somewhere else, then the hung Back landing at last: the
    /// page ends where the newer jump took it, not on the stale Back's place.
    @Test func aBackThatLandsLateAfterAnotherJumpLeavesThatJumpsPage() async throws {
        let f = try await S.make(remote: { _, _ in nil }, startAt: 0.05)
        await f.model.load()
        await f.model.locationDidChange(try #require(f.page.currentLocation))
        await f.model.go(toProgression: 0.7, rememberBack: true)
        f.model.backBeat = { await Task.yield() }
        f.page.holdsJumps = true
        let hung = Task { await f.model.goBack() }
        for _ in 0..<(JumpLanding.reads * 4) where !f.model.isGoingBack { await Task.yield() }
        for _ in 0..<(JumpLanding.reads * 4) where f.model.isGoingBack { await Task.yield() }
        #expect(!f.model.isGoingBack, "the hung Back was never freed")
        f.page.holdsJumps = false
        // He jumps somewhere else meanwhile (Back would go to the same place as the hung one).
        await f.model.go(toProgression: 0.4, rememberBack: true)
        let chosen = try #require(f.page.currentLocation)
        // Readium lands on the very place it is sent (the put-back is exact, not one page boundary off).
        f.page.pageStartsBefore = 0
        f.page.releaseJumps()
        await hung.value
        let at = f.page.currentLocation?.locations.totalProgression ?? -1
        #expect(abs(at - (chosen.locations.totalProgression ?? 0)) < 0.00001, "the late Back left the page on its own place")
        f.model.close()
    }

    /// A Back freed by its count, then a turn or a swipe of his (no jump of ours), then the hung Back
    /// landing at last: the page ends on the page he turned to, and that is the place kept.
    @Test(arguments: [false, true]) func aBackThatLandsLateAfterHisTurnLeavesHisPage(swipe: Bool) async throws {
        let f = try await S.make(remote: { _, _ in nil }, startAt: 0.05)
        await f.model.load()
        await f.model.locationDidChange(try #require(f.page.currentLocation))
        await f.model.go(toProgression: 0.7, rememberBack: true)
        f.model.backBeat = { await Task.yield() }
        f.page.holdsJumps = true
        let hung = Task { await f.model.goBack() }
        for _ in 0..<(JumpLanding.reads * 4) where !f.model.isGoingBack { await Task.yield() }
        for _ in 0..<(JumpLanding.reads * 4) where f.model.isGoingBack { await Task.yield() }
        #expect(!f.model.isGoingBack, "the hung Back was never freed")
        // He turns (or swipes) to the next page meanwhile: Readium moves itself and tells the reader.
        let next = try #require(await S.locate(f.publication, 0.72))
        f.page.currentLocation = next
        if swipe {
            f.model.noteInteraction()
            await f.model.locationDidChange(next)
        } else {
            f.model.userTurnedPage()
            for _ in 0..<200 { await Task.yield() }
        }
        f.page.pageStartsBefore = 0
        f.page.holdsJumps = false
        f.page.releaseJumps()
        await hung.value
        for _ in 0..<200 { await Task.yield() }
        let at = f.page.currentLocation?.locations.totalProgression ?? -1
        #expect(abs(at - (next.locations.totalProgression ?? 0)) < 0.00001, "the late Back left the page on its own place")
        let kept = saved(f).flatMap { try? Locator(jsonString: $0) }?.locations.totalProgression ?? -1
        #expect(abs(kept - (next.locations.totalProgression ?? 0)) < 0.001, "the late Back's place was kept")
        f.model.close()
    }
}
