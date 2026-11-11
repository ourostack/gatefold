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

    /// A first open whose shelf still holds an older listing (no Cloud place ahead on the record): the
    /// cover isn't held for a landing, and the InkPad's place, found only by the reader's own fetch, is
    /// offered, never jumped to (integrator ruling on #46: the slip is the fallback here).
    @Test func aFirstOpenFromAnOldListingOffersTheInkPadsPlace() async throws {
        let f = try await S.make(remote: { pub, mapper in try await S.inkPadPlace(pub, mapper, index: 12, percent: 40) },
                                 listed: false)
        await f.model.load()
        #expect(f.model.pageReady)
        #expect(f.page.jumps.isEmpty, "the page jumped to a Cloud place he didn't choose")
        #expect(saved(f) == nil, "the place was saved without a move of his")
        #expect(f.model.suggestion != nil, "the InkPad's place is offered instead")
        f.model.close()
    }

    /// A book he has read here, read further on the InkPad: reopened, it shows his own page and offers
    /// the InkPad's. Never lands on it (integrator ruling on #46: build 20 lost his place this way).
    @Test func aReopenedBookOffersTheInkPadsFurtherPlaceAndNeverLands() async throws {
        let pub = try await S.publication()
        let early = try #require(await S.locate(pub, 0.05))
        let json = try #require(try early.jsonString())
        let f = try await S.make(remote: { pub, mapper in try await S.inkPadPlace(pub, mapper, index: 12, percent: 40) },
                                 book: { $0.locatorJSON = json; $0.totalProgression = 0.05; $0.lastOpened = Date().addingTimeInterval(-3600) })
        await f.model.load()
        #expect(f.model.pageReady)
        #expect(f.page.jumps.isEmpty, "a reopened book jumped to the Cloud's place")
        #expect(f.page.currentLocation?.href == early.href, "his own page isn't the one showing")
        #expect(f.model.suggestion != nil, "the InkPad's further place is offered instead")
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

    enum Jump: String, CaseIterable, Sendable { case contents, link, highlight, bookmark, scrubber }

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
        case .bookmark:
            var marks = BookmarkList()
            let far = ReadingAnchor(href: f.publication.readingOrder[14].url().string, progression: 0, text: nil)
            _ = marks.toggle(at: far, visible: VisibleRange(href: far.href, start: 0, end: 0.03, text: nil), title: "a mark", totalProgression: 0.6)
            await f.model.go(to: try #require(marks.items.first))
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

    /// Back to a page partway through its chapter, taken by a web view still loading that opens the
    /// chapter's first page instead (CI's iPad at 8c5f294: Back after a Contents jump came back to the
    /// chapter's start, not his page). Back is sent again until his page is on screen.
    @Test func backReachesHisPageWhenTheFirstTryOpensTheChapterStart() async throws {
        let f = try await S.make(remote: { _, _ in nil }, startAt: 0.05)
        await f.model.load()
        let his = try #require(f.page.currentLocation)
        try #require((his.locations.progression ?? 0) > 0.05, "his page is partway through its chapter")
        await f.model.locationDidChange(his)
        await f.model.go(toProgression: 0.7, rememberBack: true)
        f.model.backBeat = { await Task.yield() }
        f.page.dropsPlaceInFile = 1
        await f.model.goBack()
        let want = his.locations.totalProgression ?? -1
        let at = f.page.currentLocation?.locations.totalProgression ?? -2
        #expect(f.page.currentLocation?.href == his.href, "Back went to another chapter")
        #expect(abs(at - want) < 0.005, "Back came back to \(at), not his page at \(want)")
        #expect(f.page.dropsPlaceInFile == 0, "the dropped jump was never tried")
        await Self.settle { abs((Self.kept(f) ?? -1) - want) < 0.001 }
        #expect(abs((Self.kept(f) ?? -1) - want) < 0.001, "the place kept is \(Self.kept(f) ?? -1), not his page at \(want)")
        f.model.close()
    }

    /// A place write still on its way for an older move never lands over a newer move's place. On CI at
    /// c4c3b6a the Contents jump's write, slow to map its position, landed after Back's and kept the
    /// jump's page (0.6996) as his place once Back had brought him home.
    @Test func aSlowWriteForAnOlderMoveNeverLandsOverANewerOnesPlace() async throws {
        let f = try await S.make(remote: { _, _ in nil }, startAt: 0.05)
        await f.model.load()
        let his = try #require(f.page.currentLocation)
        await f.model.locationDidChange(his)
        // The next write (the jump's) is held inside, before it maps its position, until the test lets it go.
        final class Gate { var armed = true; var held: CheckedContinuation<Void, Never>? }
        let gate = Gate()
        f.model.placeWriteWait = {
            guard gate.armed else { return }
            gate.armed = false
            await withCheckedContinuation { gate.held = $0 }
        }
        await f.model.go(toProgression: 0.7, rememberBack: true)
        for _ in 0..<10_000 where gate.held == nil { await Task.yield() }
        try #require(gate.held != nil, "the jump's write was never on its way")
        f.model.backBeat = { await Task.yield() }
        f.page.dropsPlaceInFile = 1
        await f.model.goBack()
        let want = his.locations.totalProgression ?? -1
        await Self.settle { abs((Self.kept(f) ?? -1) - want) < 0.001 }
        #expect(abs((Self.kept(f) ?? -1) - want) < 0.001, "Back's own write never kept his page")
        // The jump's write lands now, after Back's.
        gate.held?.resume()
        gate.held = nil
        await Self.settle { abs((Self.kept(f) ?? -1) - want) >= 0.001 }
        #expect(abs((Self.kept(f) ?? -1) - want) < 0.001, "the place kept is \(Self.kept(f) ?? -1), not his page at \(want)")
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

    /// A Back whose chapter is still loading waits for the load, not a fixed count of reads: a slow load
    /// (CI's iPad, job 129949744000, gatefold#170: Back gave up after 34 s and left him where he had
    /// jumped to) still takes him back, and his page is the place kept. The veil doesn't wait with it:
    /// at its limit it lets go (the chapter shows its own loading) while the trip goes on.
    @Test func aBackPastTheVeilsLimitLetsTheVeilGoAndStillLands() async throws {
        let f = try await S.make(remote: { _, _ in nil }, startAt: 0.05)
        await f.model.load()
        await f.model.locationDidChange(try #require(f.page.currentLocation))
        let first = try #require(f.page.currentLocation?.locations.totalProgression)
        await f.model.go(toProgression: 0.7, rememberBack: true)
        f.model.backBeat = { await Task.yield() }
        f.page.holdsJumps = true
        f.page.loadingChapter = true
        let trip = Task { await f.model.goBack() }
        for _ in 0..<(JumpLanding.reads * 4) where !f.model.isGoingBack { await Task.yield() }
        // Past the reads a trip may spend on a page that isn't loading: waited on as the event itself,
        // counted in yields as the trip's beats are (a fixed count raced them on a busy runner). Never
        // in sleeps: each beat is a yield, so a sleep spends the whole loading budget and Back rightly
        // gives up.
        for _ in 0..<(JumpLanding.reads * 20) where f.model.tripsPastTheVeil < 1 { await Task.yield() }
        try #require(f.model.tripsPastTheVeil >= 1, "the trip never got past its veil's limit")
        #expect(f.model.isGoingBack, "Back gave up while its chapter was still loading")
        #expect(f.model.tripsPastTheVeil == 1, "the veil held the screen past its limit")
        // The load comes in.
        f.page.loadingChapter = false
        f.page.holdsJumps = false
        f.page.releaseJumps()
        await trip.value
        // The place is written on its own task after the landing's report: waited on as an event.
        await Self.settle { abs((Self.kept(f) ?? -1) - first) < 0.03 }
        let at = try #require(f.page.currentLocation?.locations.totalProgression)
        #expect(abs(at - first) < 0.03, "Back did not take him back")
        #expect(abs((Self.kept(f) ?? -1) - first) < 0.03, "his page is not the place kept")
        #expect(f.model.backLabel == "Back to where you were")
        f.model.close()
    }

    /// A move of his while Back is still on its way (past the veil's limit, the chapter still loading)
    /// ends the trip quietly: no "couldn't go back", and when the hung jump comes back at last his page
    /// stands and is the place kept (gatefold#170).
    @Test func aTurnWhileBackIsStillOnItsWayEndsItQuietly() async throws {
        let f = try await S.make(remote: { _, _ in nil }, startAt: 0.05)
        await f.model.load()
        await f.model.locationDidChange(try #require(f.page.currentLocation))
        await f.model.go(toProgression: 0.7, rememberBack: true)
        let wayBack = try #require(f.model.backLocator)
        f.model.backBeat = { await Task.yield() }
        f.page.holdsJumps = true
        f.page.loadingChapter = true
        let trip = Task { await f.model.goBack() }
        for _ in 0..<(JumpLanding.reads * 4) where !f.model.isGoingBack { await Task.yield() }
        for _ in 0..<(JumpLanding.reads * 2) where f.model.tripsPastTheVeil == 0 { await Task.yield() }
        #expect(f.model.isGoingBack && f.model.tripsPastTheVeil == 1, "the trip wasn't still on its way past the veil's limit")
        // He turns to the next page meanwhile: Readium moves itself and tells the reader.
        let next = try #require(await S.locate(f.publication, 0.72))
        f.page.currentLocation = next
        f.model.userTurnedPage()
        await Self.settle { abs((Self.kept(f) ?? -1) - (next.locations.totalProgression ?? 0)) < 0.001 }
        for _ in 0..<(JumpLanding.reads) where f.model.isGoingBack { await Task.yield() }
        #expect(!f.model.isGoingBack, "his turn didn't end the trip")
        #expect(f.model.backLabel != "Couldn't go back. Try again", "a trip he ended by turning said it couldn't go back")
        // The hung jump comes back at last: his page stands.
        f.page.loadingChapter = false
        f.page.holdsJumps = false
        f.page.pageStartsBefore = 0
        f.page.releaseJumps()
        await trip.value
        await Self.settle { abs((f.page.currentLocation?.locations.totalProgression ?? -1) - (next.locations.totalProgression ?? 0)) < 0.00001 }
        #expect(abs((f.page.currentLocation?.locations.totalProgression ?? -1) - (next.locations.totalProgression ?? 0)) < 0.00001, "the late Back moved the page off his turn")
        #expect(abs((Self.kept(f) ?? -1) - (next.locations.totalProgression ?? 0)) < 0.001, "the place kept isn't his turn")
        #expect(f.model.backLocator == wayBack, "the ended trip's late jump put up a way back to a page he had left")
        f.model.close()
    }

    /// Any veiled jump, not only Back, under a chapter load that never ends: at the veil's limit
    /// (`JumpLanding.reads` beats) the veil lets go and the chapter shows its own loading, and the jump
    /// still lands when the load comes in (gatefold#173: a Contents jump held the screen 43 s and more).
    @Test func aJumpPastTheVeilsLimitLetsTheVeilGoAndStillLands() async throws {
        let f = try await S.make(remote: { _, _ in nil }, startAt: 0.05, jumpBeat: { await Task.yield() })
        await f.model.load()
        await f.model.locationDidChange(try #require(f.page.currentLocation))
        f.page.holdsJumps = true
        f.page.loadingChapter = true
        let jump = Task { await f.model.go(toProgression: 0.7, rememberBack: true) }
        await Self.settle { f.model.jumpsPastTheVeil == 1 }
        #expect(f.model.jumpsPastTheVeil == 1, "the veil held the screen past its limit")
        // The load comes in.
        f.page.loadingChapter = false
        f.page.holdsJumps = false
        f.page.releaseJumps()
        await jump.value
        await Self.settle { abs((Self.kept(f) ?? -1) - 0.7) < 0.03 }
        #expect(abs((f.page.currentLocation?.locations.totalProgression ?? -1) - 0.7) < 0.03, "the jump never landed")
        #expect(abs((Self.kept(f) ?? -1) - 0.7) < 0.03, "the place kept isn't where the jump landed")
        #expect(f.model.showJumpBack, "the jump has no way back")
        f.model.close()
    }

    /// A turn or a swipe of his while a jump is still on its way past the veil's limit ends it quietly:
    /// when the hung jump comes back at last, his page stands and is the place kept, and no way back
    /// is offered for a jump he never saw land (gatefold#173).
    /// "tap, then swipe": a report with no touch (the layout one the controls bring) comes first, so the
    /// swipe has no jump of ours since that report; it still ends the jump (gatefold#173 re-review).
    @Test(arguments: ["turn", "swipe", "tap, then swipe"]) func aMoveWhileAJumpIsPastTheVeilsLimitEndsItQuietly(how: String) async throws {
        let f = try await S.make(remote: { _, _ in nil }, startAt: 0.05, jumpBeat: { await Task.yield() })
        await f.model.load()
        await f.model.locationDidChange(try #require(f.page.currentLocation))
        f.page.holdsJumps = true
        f.page.loadingChapter = true
        let jump = Task { await f.model.go(toProgression: 0.7, rememberBack: true) }
        await Self.settle { f.model.jumpsPastTheVeil == 1 }
        #expect(f.model.jumpsPastTheVeil == 1, "the jump wasn't still on its way past the veil's limit")
        // He moves on meanwhile: Readium moves itself and tells the reader. A tap first reports the page
        // he is still on (it moves nothing).
        let next = try #require(await S.locate(f.publication, 0.06))
        if how == "tap, then swipe" {
            f.model.controlsTapped(visible: true)
            await f.model.locationDidChange(try #require(f.page.currentLocation))
        }
        f.page.currentLocation = next
        if how == "turn" {
            f.model.userTurnedPage()
        } else {
            f.model.noteInteraction()
            await f.model.locationDidChange(next)
        }
        await Self.settle { abs((Self.kept(f) ?? -1) - (next.locations.totalProgression ?? 0)) < 0.001 }
        // The hung jump comes back at last: his page stands.
        f.page.loadingChapter = false
        f.page.holdsJumps = false
        f.page.pageStartsBefore = 0
        f.page.releaseJumps()
        await jump.value
        await Self.settle { abs((f.page.currentLocation?.locations.totalProgression ?? -1) - (next.locations.totalProgression ?? 0)) < 0.00001 }
        #expect(abs((f.page.currentLocation?.locations.totalProgression ?? -1) - (next.locations.totalProgression ?? 0)) < 0.00001, "the late jump moved the page off his \(how)")
        #expect(abs((Self.kept(f) ?? -1) - (next.locations.totalProgression ?? 0)) < 0.001, "the place kept isn't his \(how)")
        #expect(!f.model.showJumpBack, "a way back is offered for a jump he never saw land")
        f.model.close()
    }

    /// A slow catch-up to the Cloud's place (a percent, so the landing's own percent step runs inside its
    /// veil) that outlives the veil, with no move of his, counts once and is not put back: it is where the
    /// page belongs (gatefold#173 review).
    @Test func aSlowLandingOfOursPastTheVeilIsNotPutBack() async throws {
        let f = try await S.make(remote: { _, _ in ReadingPosition(cfi: nil, totalProgression: 0.7, updated: Date(), source: .pocketBookNative) },
                                 book: { $0.totalProgression = 0.05; $0.lastOpened = Date().addingTimeInterval(-600) },
                                 startAt: 0.05, jumpBeat: { await Task.yield() })
        await f.model.load()
        await f.model.locationDidChange(try #require(f.page.currentLocation))
        await f.model.checkRemote()
        try #require(f.model.suggestion != nil, "the Cloud's place is offered")
        // The first page shown, as the host's reveal does (no host here). This only bounds the reveal: it
        // never kept these catch-ups from going (the loaded standby did, below).
        f.model.forceReady()
        for _ in 0..<1_000 where !f.model.pageReady { try? await Task.sleep(for: .milliseconds(10)) }
        try #require(f.model.pageReady, "the first page never showed")
        // The Cloud place's page loading behind this one never loads either: the host drops it 1.5 s
        // after the tap and jumps the plain way. Left in place, the catch-up swaps it in, sends no jump
        // and never meets the hung load (every run of these tests before this line).
        f.page.dropStandby()
        f.page.holdsJumps = true
        f.page.loadingChapter = true
        let taking = Task { await f.model.acceptSuggestion() }
        await Self.settle { f.model.jumpsPastTheVeil >= 1 }
        #expect(f.model.jumpsPastTheVeil == 1, "the catch-up wasn't on its way past the veil's limit (jumps sent \(f.page.jumps.count), page ready \(f.model.pageReady))")
        f.page.loadingChapter = false
        f.page.holdsJumps = false
        f.page.releaseJumps()
        await taking.value
        #expect(f.model.jumpsPastTheVeil == 1, "one catch-up counted \(f.model.jumpsPastTheVeil) times past the veil")
        #expect(f.model.jumpsPutBack == 0, "a landing nobody overtook was put back")
        #expect(abs((f.page.currentLocation?.locations.totalProgression ?? -1) - 0.7) < 0.03, "the landing didn't stand")
        f.model.close()
    }

    /// A touch that went nowhere while a catch-up is past its veil (no tap, no swipe) leaves the landing's
    /// own report looking touched. Readium reporting the landed page before the jump returns is still the
    /// landing's, not a swipe of his: nothing is put back and its way back is offered (gatefold#173 re-review).
    /// "exact, two steps": the jump first names its file's first page (Readium on a loading web view), then
    /// the place; both reports are the landing's.
    /// `counted`: the book's screen pages are counted, as on a real iPad once the count is done, so the
    /// screen page decides what is the landing's own page; else Readium's positions do.
    @Test(arguments: ["percent", "exact, two steps"], [false, true]) func aStrayTouchPastTheVeilLeavesTheCatchUpItsOwnReport(place: String, counted: Bool) async throws {
        let f = try await S.make(remote: { pub, mapper in
            place == "percent" ? ReadingPosition(cfi: nil, totalProgression: 0.7, updated: Date(), source: .pocketBookNative)
                : try await S.inkPadPlace(pub, mapper, index: 12, percent: 40)
        }, book: { $0.totalProgression = 0.05; $0.lastOpened = Date().addingTimeInterval(-600) },
           startAt: 0.05, jumpBeat: { await Task.yield() })
        defer { f.model.close() }
        // Before the open loads its counts.
        if counted { try await Self.countsLikeADevice(f) }
        await f.model.load()
        await f.model.locationDidChange(try #require(f.page.currentLocation))
        await f.model.checkRemote()
        try #require(f.model.suggestion != nil, "the Cloud's place is offered")
        f.model.forceReady()
        for _ in 0..<1_000 where !f.model.pageReady { try? await Task.sleep(for: .milliseconds(10)) }
        try #require(f.model.pageReady, "the first page never showed")
        if counted { try await Self.countScreens(f) }
        f.page.dropStandby()
        f.page.reportsBeforeReturn = true
        // Readium reports the start of the page it lands on: here, the place itself.
        f.page.pageStartsBefore = 0
        if place != "percent" { f.page.dropsPlaceInFile = 1 }
        f.page.holdsJumps = true
        f.page.loadingChapter = true
        let taking = Task { await f.model.acceptSuggestion() }
        await Self.settle { f.model.jumpsPastTheVeil >= 1 }
        try #require(f.model.jumpsPastTheVeil == 1, "the catch-up wasn't on its way past the veil's limit")
        // A touch that began and went nowhere: no tap clears it, no swipe reports it.
        f.model.noteInteraction()
        f.page.loadingChapter = false
        f.page.holdsJumps = false
        f.page.releaseJumps()
        await taking.value
        let aim = try #require(f.page.jumps.last?.locations.totalProgression, "the catch-up sent no jump")
        await Self.settle { abs((Self.kept(f) ?? -1) - aim) < 0.03 }
        #expect(f.model.jumpsPutBack == 0, "the catch-up's own report was taken for a swipe of his and the page put back (\(place))")
        #expect(abs((f.page.currentLocation?.locations.totalProgression ?? -1) - aim) < 0.03, "the catch-up didn't stand (\(place))")
        #expect(abs((Self.kept(f) ?? -1) - aim) < 0.03, "the place kept isn't the catch-up's: \(Self.kept(f) ?? -1) (\(place))")
        #expect(f.model.showJumpBack, "the catch-up landed but offers no way back (\(place))")
    }

    /// The common catch-up: the Cloud's place three pages on in the file he is reading. Past its veil, a
    /// swipe of his one page on is his move, not the landing's own report: his page stands and is kept,
    /// and no way back is offered (gatefold#173 re-review: a bound in fractions of the book swallowed it).
    @Test(arguments: [false, true]) func aSwipeAPageOnPastACatchUpThreePagesAheadIsHis(counted: Bool) async throws {
        let f = try await S.make(remote: { pub, mapper in
            nonisolated(unsafe) let p = pub
            let positions = try await p.positions().get()
            let k = try #require(positions.firstIndex { ($0.locations.totalProgression ?? 0) > 0.05 })
            let aim = positions[k + 2]
            let made = try #require(await mapper.position(for: BookLocation(href: aim.href.string, progression: aim.locations.progression ?? 0), at: Date()))
            return ReadingPosition(cfi: try #require(made.cfi), pointer: "pbr:/external##" + (made.cfi ?? ""),
                                   totalProgression: aim.locations.totalProgression ?? 0, updated: Date(), source: .pocketBookNative)
        }, book: { $0.totalProgression = 0.05; $0.lastOpened = Date().addingTimeInterval(-600) },
           startAt: 0.05, jumpBeat: { await Task.yield() })
        defer { f.model.close() }
        // Before the open loads its counts.
        if counted { try await Self.countsLikeADevice(f) }
        await f.model.load()
        await f.model.locationDidChange(try #require(f.page.currentLocation))
        await f.model.checkRemote()
        try #require(f.model.suggestion != nil, "the Cloud's place is offered")
        nonisolated(unsafe) let p = f.publication
        let positions = try await p.positions().get()
        let here = try #require(f.page.currentLocation)
        let at = try #require(positions.lastIndex { ($0.locations.totalProgression ?? 0) <= (here.locations.totalProgression ?? 0) })
        let next = positions[at + 1]
        let aim = positions[at + 3]
        try #require(next.href == here.href && aim.href == here.href, "his page, the next and the Cloud's aren't one file")
        // At two positions a column, an even count keeps his next page and the Cloud's a whole column apart.
        if counted { try #require(positions.filter { $0.href == here.href }.count % 2 == 0, "an odd count can put his next page on the Cloud's") }
        f.model.forceReady()
        for _ in 0..<1_000 where !f.model.pageReady { try? await Task.sleep(for: .milliseconds(10)) }
        try #require(f.model.pageReady, "the first page never showed")
        if counted { try await Self.countScreens(f) }
        f.page.dropStandby()
        f.page.holdsJumps = true
        f.page.loadingChapter = true
        let taking = Task { await f.model.acceptSuggestion() }
        await Self.settle { f.model.jumpsPastTheVeil >= 1 }
        try #require(f.model.jumpsPastTheVeil == 1, "the catch-up wasn't on its way past the veil's limit")
        // He swipes a page on: Readium moves itself and tells the reader.
        f.page.currentLocation = next
        f.model.noteInteraction()
        await f.model.locationDidChange(next)
        f.page.loadingChapter = false
        f.page.holdsJumps = false
        f.page.pageStartsBefore = 0
        f.page.releaseJumps()
        await taking.value
        let mine = next.locations.totalProgression ?? 0
        await Self.settle { abs((f.page.currentLocation?.locations.totalProgression ?? -1) - mine) < 0.00001 }
        #expect(abs((f.page.currentLocation?.locations.totalProgression ?? -1) - mine) < 0.00001, "the late catch-up moved the page off his swipe")
        #expect(abs((Self.kept(f) ?? -1) - mine) < 0.001, "the place kept isn't his swipe: \(Self.kept(f) ?? -1), his \(mine), the Cloud's \(aim.locations.totalProgression ?? -1)")
        #expect(!f.model.showJumpBack, "a way back is offered for a catch-up he never saw land")
    }

    /// The same past a file's end: the Cloud's place a few pages into the next chapter, and his swipe from
    /// this file's last page onto the next file's first page. That first page is not the landing's first
    /// step (a jump names its file's first page first): his page before it was the file just before, so
    /// the swipe is his (gatefold#173 re-review).
    @Test func aSwipeOntoTheNextChapterPastACatchUpThereIsHis() async throws {
        let f = try await S.make(remote: { pub, mapper in
            nonisolated(unsafe) let p = pub
            let positions = try await p.positions().get()
            let j = try #require(positions.indices.first { $0 > 0 && (positions[$0].locations.totalProgression ?? 0) > 0.05 && positions[$0].href != positions[$0 - 1].href })
            let aim = positions[j + 2]
            let made = try #require(await mapper.position(for: BookLocation(href: aim.href.string, progression: aim.locations.progression ?? 0), at: Date()))
            return ReadingPosition(cfi: try #require(made.cfi), pointer: "pbr:/external##" + (made.cfi ?? ""),
                                   totalProgression: aim.locations.totalProgression ?? 0, updated: Date(), source: .pocketBookNative)
        }, book: { $0.totalProgression = 0.05; $0.lastOpened = Date().addingTimeInterval(-600) },
           startAt: 0.05, jumpBeat: { await Task.yield() })
        defer { f.model.close() }
        await f.model.load()
        await f.model.locationDidChange(try #require(f.page.currentLocation))
        nonisolated(unsafe) let p = f.publication
        let positions = try await p.positions().get()
        let j = try #require(positions.indices.first { $0 > 0 && (positions[$0].locations.totalProgression ?? 0) > 0.05 && positions[$0].href != positions[$0 - 1].href })
        let last = positions[j - 1], first = positions[j]
        try #require((first.locations.progression ?? 1) == 0 && positions[j + 2].href == first.href, "the next file's first page and the Cloud's place aren't one file")
        // He has read on to this file's last page.
        f.page.currentLocation = last
        f.model.noteInteraction()
        await f.model.locationDidChange(last)
        await f.model.checkRemote()
        try #require(f.model.suggestion != nil, "the Cloud's place is offered")
        f.model.forceReady()
        for _ in 0..<1_000 where !f.model.pageReady { try? await Task.sleep(for: .milliseconds(10)) }
        try #require(f.model.pageReady, "the first page never showed")
        f.page.dropStandby()
        f.page.holdsJumps = true
        f.page.loadingChapter = true
        let taking = Task { await f.model.acceptSuggestion() }
        await Self.settle { f.model.jumpsPastTheVeil >= 1 }
        try #require(f.model.jumpsPastTheVeil == 1, "the catch-up wasn't on its way past the veil's limit")
        // He swipes on, onto the next chapter's first page.
        f.page.currentLocation = first
        f.model.noteInteraction()
        await f.model.locationDidChange(first)
        f.page.loadingChapter = false
        f.page.holdsJumps = false
        f.page.pageStartsBefore = 0
        f.page.releaseJumps()
        await taking.value
        let mine = first.locations.totalProgression ?? 0
        await Self.settle { abs((f.page.currentLocation?.locations.totalProgression ?? -1) - mine) < 0.00001 }
        #expect(abs((f.page.currentLocation?.locations.totalProgression ?? -1) - mine) < 0.00001, "the late catch-up moved the page off his swipe onto the next chapter")
        #expect(abs((Self.kept(f) ?? -1) - mine) < 0.001, "the place kept isn't his swipe: \(Self.kept(f) ?? -1), his \(mine)")
        #expect(!f.model.showJumpBack, "a way back is offered for a catch-up he never saw land")
    }

    /// A catch-up overtaken by a turn or a swipe of his while it is past the veil's limit offers no way
    /// back (he never saw it land) and writes nothing of the Cloud's when it comes back late: no Cloud
    /// place kept, no Cloud scale noted (gatefold#173 re-review). A swipe counts no move, so the landing
    /// must give way to his steps too. The Cloud's place as a percent and as exact words.
    @Test(arguments: ["percent", "exact"], ["turn", "swipe"]) func aCatchUpEndedQuietlyOffersNoWayBack(place: String, how: String) async throws {
        let f = try await S.make(remote: { pub, mapper in
            place == "percent" ? ReadingPosition(cfi: nil, totalProgression: 0.7, updated: Date(), source: .pocketBookNative)
                : try await S.inkPadPlace(pub, mapper, index: 12, percent: 40)
        }, book: { $0.totalProgression = 0.05; $0.lastOpened = Date().addingTimeInterval(-600) },
           startAt: 0.05, jumpBeat: { await Task.yield() })
        await f.model.load()
        await f.model.locationDidChange(try #require(f.page.currentLocation))
        await f.model.checkRemote()
        try #require(f.model.suggestion != nil, "the Cloud's place is offered")
        // The first page shown, as the host's reveal does (no host here). This only bounds the reveal: it
        // never kept these catch-ups from going (the loaded standby did, below).
        f.model.forceReady()
        for _ in 0..<1_000 where !f.model.pageReady { try? await Task.sleep(for: .milliseconds(10)) }
        try #require(f.model.pageReady, "the first page never showed")
        // The Cloud place's page loading behind this one never loads either: the host drops it 1.5 s
        // after the tap and jumps the plain way. Left in place, the catch-up swaps it in, sends no jump
        // and never meets the hung load (every run of these tests before this line).
        f.page.dropStandby()
        f.page.holdsJumps = true
        f.page.loadingChapter = true
        let taking = Task { await f.model.acceptSuggestion() }
        await Self.settle { f.model.jumpsPastTheVeil >= 1 }
        #expect(f.model.jumpsPastTheVeil == 1, "the catch-up wasn't on its way past the veil's limit (jumps sent \(f.page.jumps.count), page ready \(f.model.pageReady))")
        let next = try #require(await S.locate(f.publication, 0.06))
        f.page.currentLocation = next
        if how == "turn" {
            f.model.userTurnedPage()
        } else {
            f.model.noteInteraction()
            await f.model.locationDidChange(next)
        }
        await Self.settle { abs((Self.kept(f) ?? -1) - (next.locations.totalProgression ?? 0)) < 0.001 }
        f.page.loadingChapter = false
        f.page.holdsJumps = false
        f.page.pageStartsBefore = 0
        f.page.releaseJumps()
        await taking.value
        #expect(f.app.library.book(bookID)?.cloudScale == nil, "the late catch-up noted the Cloud's scale over his \(how)")
        await Self.settle { abs((f.page.currentLocation?.locations.totalProgression ?? -1) - (next.locations.totalProgression ?? 0)) < 0.00001 }
        #expect(abs((Self.kept(f) ?? -1) - (next.locations.totalProgression ?? 0)) < 0.001, "the place kept isn't his turn")
        #expect(!f.model.showJumpBack, "a way back is offered for a catch-up he never saw land (\(how))")
        f.model.close()
    }

    /// A jump of his made while another is still on its way past the veil's limit gets a limit of its
    /// own: a second load that never ends doesn't hold the screen either (gatefold#173 re-review).
    /// `reportsFirst`: Readium reports each jump's page before the jump returns, so the first jump's late
    /// report comes before anything knows it was overtaken.
    @Test(arguments: [false, true]) func aSecondJumpWhileOneIsPastTheVeilsLimitHasItsOwnLimit(reportsFirst: Bool) async throws {
        let f = try await S.make(remote: { _, _ in nil }, startAt: 0.05, jumpBeat: { await Task.yield() })
        await f.model.load()
        await f.model.locationDidChange(try #require(f.page.currentLocation))
        f.page.reportsBeforeReturn = reportsFirst
        f.page.holdsJumps = true
        f.page.loadingChapter = true
        let first = Task { await f.model.go(toProgression: 0.7, rememberBack: true) }
        await Self.settle { f.model.jumpsPastTheVeil == 1 }
        #expect(f.model.jumpsPastTheVeil == 1, "the first jump wasn't past the veil's limit")
        let second = Task { await f.model.go(toProgression: 0.5, rememberBack: true) }
        await Self.settle { f.model.jumpsPastTheVeil == 2 }
        #expect(f.model.jumpsPastTheVeil == 2, "the second hung jump held the screen with no limit")
        f.page.loadingChapter = false
        f.page.holdsJumps = false
        f.page.releaseJumps()
        await first.value
        await second.value
        // The newer jump's page stands and is kept; the first, overtaken, leaves no way back of its own.
        await Self.settle { abs((Self.kept(f) ?? -1) - 0.5) < 0.03 }
        #expect(abs((f.page.currentLocation?.locations.totalProgression ?? -1) - 0.5) < 0.03, "the second jump's page didn't stand")
        #expect(abs((Self.kept(f) ?? -1) - 0.5) < 0.03, "the place kept isn't the second jump's")
        #expect(f.model.showJumpBack && abs((f.model.backLocator?.locations.totalProgression ?? -1) - 0.05) < 0.03,
                "the way back isn't to the page he left")
        f.model.close()
    }

    /// Readium reports each jump's page before it returns, and the overtaken first jump's report is slow
    /// to write: the newest jump, back past its veil, keeps its page, and the slow write yields to it.
    @Test func aSlowLateReportWriteYieldsToTheNewestJumpPastTheVeil() async throws {
        let f = try await S.make(remote: { _, _ in nil }, startAt: 0.05, jumpBeat: { await Task.yield() })
        await f.model.load()
        await f.model.locationDidChange(try #require(f.page.currentLocation))
        f.page.reportsBeforeReturn = true
        f.page.holdsJumps = true
        f.page.loadingChapter = true
        let first = Task { await f.model.go(toProgression: 0.7, rememberBack: true) }
        await Self.settle { f.model.jumpsPastTheVeil == 1 }
        let second = Task { await f.model.go(toProgression: 0.5, rememberBack: true) }
        await Self.settle { f.model.jumpsPastTheVeil == 2 }
        try #require(f.model.jumpsPastTheVeil == 2, "the jumps weren't both past the veil's limit")
        // The next write (the first jump's late report) is held before it maps its position. The page
        // can't be measured, so that write keeps its own report (0.7) rather than taking the second
        // jump's as the page on screen: only the write order can stop it.
        f.page.pageUnmeasured = true
        final class Gate { var armed = true; var held: CheckedContinuation<Void, Never>? }
        let gate = Gate()
        defer { gate.held?.resume(); f.model.close() }
        f.model.placeWriteWait = {
            guard gate.armed else { return }
            gate.armed = false
            await withCheckedContinuation { gate.held = $0 }
        }
        f.page.loadingChapter = false
        f.page.holdsJumps = false
        f.page.releaseJumps()
        for _ in 0..<10_000 where gate.held == nil { await Task.yield() }
        try #require(gate.held != nil, "the late report's write was never on its way")
        // Bounded, never awaited: if the held write were the newest jump's own, waiting on it would hang.
        await Self.settle { abs((Self.kept(f) ?? -1) - 0.5) < 0.03 }
        let keptBeforeRelease = Self.kept(f) ?? -1
        gate.held?.resume()
        gate.held = nil
        await second.value
        await first.value
        #expect(abs(keptBeforeRelease - 0.5) < 0.03, "the newest jump's keep didn't land while the late write was held: \(keptBeforeRelease)")
        await Self.settle { abs((Self.kept(f) ?? -1) - 0.5) >= 0.03 }
        #expect(abs((f.page.currentLocation?.locations.totalProgression ?? -1) - 0.5) < 0.03, "the second jump's page didn't stand")
        #expect(abs((Self.kept(f) ?? -1) - 0.5) < 0.03, "the slow late write kept \(Self.kept(f) ?? -1) over the second jump")
    }

    /// A bookmark's jump ended quietly by a move of his offers no way back, as any other jump
    /// (gatefold#173 re-review).
    @Test func aBookmarkJumpEndedQuietlyOffersNoWayBack() async throws {
        let f = try await S.make(remote: { _, _ in nil }, startAt: 0.05, jumpBeat: { await Task.yield() })
        await f.model.load()
        await f.model.locationDidChange(try #require(f.page.currentLocation))
        let mark = try JSONDecoder().decode(Bookmark.self, from: Data("""
            {"id":"\(UUID().uuidString)","anchor":{"href":"x","progression":0.5},"title":"t","totalProgression":0.7,"created":0}
            """.utf8))
        f.page.holdsJumps = true
        f.page.loadingChapter = true
        let jump = Task { await f.model.go(to: mark) }
        await Self.settle { f.model.jumpsPastTheVeil == 1 }
        #expect(f.model.jumpsPastTheVeil == 1, "the bookmark's jump wasn't past the veil's limit")
        let next = try #require(await S.locate(f.publication, 0.06))
        f.page.currentLocation = next
        f.model.userTurnedPage()
        await Self.settle { abs((Self.kept(f) ?? -1) - (next.locations.totalProgression ?? 0)) < 0.001 }
        f.page.loadingChapter = false
        f.page.holdsJumps = false
        f.page.pageStartsBefore = 0
        f.page.releaseJumps()
        await jump.value
        await Self.settle { abs((f.page.currentLocation?.locations.totalProgression ?? -1) - (next.locations.totalProgression ?? 0)) < 0.00001 }
        #expect(abs((Self.kept(f) ?? -1) - (next.locations.totalProgression ?? 0)) < 0.001, "the place kept isn't his turn")
        #expect(!f.model.showJumpBack, "a way back is offered for a bookmark jump he never saw land")
        f.model.close()
    }

    /// A Back that does give up (a load that died: no load under way, or one that never ends, or a jump
    /// that comes back but never shows his page) says so on the pill and leaves it up, pointing at his
    /// page, so one more tap tries again; it never just stops (gatefold#170).
    @Test(arguments: ["hung, not loading", "loading forever", "came back short"]) func aBackThatGivesUpSaysSoAndStaysUp(how: String) async throws {
        let f = try await S.make(remote: { _, _ in nil }, startAt: 0.05)
        await f.model.load()
        await f.model.locationDidChange(try #require(f.page.currentLocation))
        await f.model.go(toProgression: 0.7, rememberBack: true)
        let wayBack = try #require(f.model.backLocator)
        f.model.backBeat = { await Task.yield() }
        // Came back short: every jump opens its file's first page, never his page in it.
        if how == "came back short" { f.page.dropsPlaceInFile = 100_000 } else { f.page.holdsJumps = true }
        f.page.loadingChapter = how == "loading forever"
        let hung = Task { await f.model.goBack() }
        for _ in 0..<(JumpLanding.reads * 4) where !f.model.isGoingBack { await Task.yield() }
        for _ in 0..<(JumpLanding.reads * 20) where f.model.isGoingBack { await Task.yield() }
        #expect(!f.model.isGoingBack, "a Back whose load died was never given up")
        #expect(f.model.backLabel == "Couldn't go back. Try again", "Back gave up without saying so")
        #expect(f.model.showJumpBack && f.model.backLocator == wayBack, "the way back went away when Back gave up")
        if how == "came back short" {
            await hung.value
            #expect(f.model.backLabel == "Couldn't go back. Try again", "a Back that never showed his page said it got there")
            #expect(f.model.backLocator == wayBack, "the way back now points at the page Back was left on")
            f.page.dropsPlaceInFile = 0
        }
        // One more tap tries again, and the pill says where it goes once more.
        f.page.loadingChapter = false
        f.page.holdsJumps = false
        let before = f.page.jumps.count
        await f.model.goBack()
        #expect(f.page.jumps.count == before + 1, "the next Back made no jump")
        #expect(f.model.backLabel != "Couldn't go back. Try again")
        f.page.releaseJumps()
        await hung.value
        f.model.close()
    }

    /// The pill's "didn't go" clears once it is out of date: on a new jump of his, and when the given-up
    /// trip lands late with no move of his since (the next Back is `aBackThatGivesUpSaysSoAndStaysUp`).
    @Test(arguments: ["a new jump", "the late landing"]) func aGivenUpBacksWordsClear(on what: String) async throws {
        let f = try await S.make(remote: { _, _ in nil }, startAt: 0.05)
        await f.model.load()
        await f.model.locationDidChange(try #require(f.page.currentLocation))
        await f.model.go(toProgression: 0.7, rememberBack: true)
        f.model.backBeat = { await Task.yield() }
        f.page.holdsJumps = true
        let hung = Task { await f.model.goBack() }
        for _ in 0..<(JumpLanding.reads * 4) where !f.model.isGoingBack { await Task.yield() }
        for _ in 0..<(JumpLanding.reads * 20) where f.model.isGoingBack { await Task.yield() }
        #expect(f.model.backLabel == "Couldn't go back. Try again", "Back gave up without saying so")
        f.page.holdsJumps = false
        if what == "a new jump" {
            await f.model.go(toProgression: 0.4, rememberBack: true)
            #expect(f.model.backLabel != "Couldn't go back. Try again", "a new jump's way back still said Back didn't go")
            f.page.releaseJumps()
            await hung.value
        } else {
            f.page.releaseJumps()
            await hung.value
            #expect(f.model.backLabel != "Couldn't go back. Try again", "Back got there late and still said it didn't")
        }
        #expect(f.model.backLabel != "Couldn't go back. Try again")
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
    /// landing at last: the page ends on the page he turned to, and that is the place kept. Also with
    /// a tap meanwhile that brought no report (swallowed under a veil): the late report is no swipe,
    /// even when Readium reports the page before the jump returns.
    @Test(arguments: ["turn", "swipe", "turn, then a swallowed tap", "turn, then a swallowed tap, reported early",
                      "turn, then a swallowed tap, put back slowly"]) func aBackThatLandsLateAfterHisTurnLeavesHisPage(move: String) async throws {
        let swipe = move == "swipe"
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
            // The turn records its place on its own task: wait for that write, in bounded reads.
            await Self.settle { abs((Self.kept(f) ?? -1) - (next.locations.totalProgression ?? 0)) < 0.001 }
        }
        if move.contains("tap") { f.model.noteInteraction() }
        f.page.reportsBeforeReturn = move.hasSuffix("early")
        f.page.pageStartsBefore = 0
        // Put back slowly: the late Back's report comes while the page is still being put back.
        f.page.holdsJumps = move.hasSuffix("slowly")
        f.page.releaseJumps()
        if move.hasSuffix("slowly") {
            for _ in 0..<200 { await Task.yield() }
            f.page.holdsJumps = false
            f.page.releaseJumps()
        }
        await hung.value
        await Self.settle {
            abs((f.page.currentLocation?.locations.totalProgression ?? -1) - (next.locations.totalProgression ?? 0)) < 0.00001
                && abs((Self.kept(f) ?? -1) - (next.locations.totalProgression ?? 0)) < 0.001
        }
        let at = f.page.currentLocation?.locations.totalProgression ?? -1
        #expect(abs(at - (next.locations.totalProgression ?? 0)) < 0.00001, "the late Back left the page on its own place")
        let kept = saved(f).flatMap { try? Locator(jsonString: $0) }?.locations.totalProgression ?? -1
        #expect(abs(kept - (next.locations.totalProgression ?? 0)) < 0.001, "the late Back's place was kept")
        f.model.close()
    }

    /// A Back freed by its count that lands late with nothing done since is just his Back, late: the
    /// page and the place kept are where it went, even when Readium reported it before the jump returned.
    @Test func aFreedBackWithNothingSinceKeepsItsPlace() async throws {
        let f = try await S.make(remote: { _, _ in nil }, startAt: 0.05)
        await f.model.load()
        await f.model.locationDidChange(try #require(f.page.currentLocation))
        await f.model.go(toProgression: 0.7, rememberBack: true)
        let target = try #require(f.model.backLocator)
        f.model.backBeat = { await Task.yield() }
        f.page.holdsJumps = true
        let hung = Task { await f.model.goBack() }
        for _ in 0..<(JumpLanding.reads * 4) where !f.model.isGoingBack { await Task.yield() }
        for _ in 0..<(JumpLanding.reads * 4) where f.model.isGoingBack { await Task.yield() }
        #expect(!f.model.isGoingBack, "the hung Back was never freed")
        f.page.holdsJumps = false
        f.page.reportsBeforeReturn = true
        f.page.pageStartsBefore = 0
        f.page.releaseJumps()
        await hung.value
        let want = target.locations.totalProgression ?? -1
        await Self.settle {
            abs((f.page.currentLocation?.locations.totalProgression ?? -2) - want) < 0.00001 && abs((Self.kept(f) ?? -1) - want) < 0.001
        }
        let at = f.page.currentLocation?.locations.totalProgression ?? -2
        #expect(abs(at - want) < 0.00001, "the page is not where Back went")
        let kept = saved(f).flatMap { try? Locator(jsonString: $0) }?.locations.totalProgression ?? -1
        #expect(abs(kept - want) < 0.001, "the late Back's place was not kept")
        f.model.close()
    }

    /// The place kept for the book, as a total progression.
    private static func kept(_ f: S.Fixture) -> Double? {
        f.app.library.book(S.frankenstein.fastHash)?.locatorJSON.flatMap { try? Locator(jsonString: $0) }?.locations.totalProgression
    }

    /// A screen page holding two of Readium's positions, as on a device (one to two each), counted into a
    /// store of this reader's own: counts saved to the shared one would reach every other fixture.
    private static func countsLikeADevice(_ f: ReaderSyncTests.Fixture) async throws {
        nonisolated(unsafe) let p = f.publication
        let positions = try await p.positions().get()
        let perFile = Dictionary(grouping: positions, by: { $0.href.string }).mapValues { max(1, $0.count / 2) }
        f.page.countsColumns = { perFile[$0] ?? 1 }
    }

    /// The book's screen pages counted (the page counts each chapter at once): waited on in reads.
    private static func countScreens(_ f: ReaderSyncTests.Fixture) async throws {
        for _ in 0..<500 where f.model.screenPages?.isComplete != true { try? await Task.sleep(for: .milliseconds(10)) }
        try #require(f.model.screenPages?.isComplete == true, "the screen pages were never counted")
        let here = try #require(f.page.currentLocation?.locations.totalProgression)
        try #require(f.model.screenPage(atTotal: here) != nil, "no screen page for his page")
    }

    /// Work that runs on its own tasks (a turn's write, a late Back's report) lands in its own time: wait
    /// until `done` holds, in reads 10 ms apart for at most 2 s, then a quiet 100 ms more so a late
    /// wrong write still shows in the checks that follow.
    private static func settle(_ done: () -> Bool) async {
        for _ in 0..<200 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
        try? await Task.sleep(for: .milliseconds(100))
    }
}
