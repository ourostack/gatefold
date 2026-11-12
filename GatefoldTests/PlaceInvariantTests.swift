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
        // Judged in reads: a contents jump inside its file reads for its place, and each beat only yields.
        let f = try await S.make(remote: { _, _ in nil }, startAt: 0.05, jumpBeat: { await Task.yield() })
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

    /// A contents entry partway through its file lands on its own page, and that page is the place kept:
    /// never the file's first page, which a web view still laying out opens instead (gatefold#166: "Chapter
    /// XL", 0.80 into its file, was kept at the file's start, an earlier chapter).
    /// Also when the file's layout is still settling as it is first read (CI run 42852464361: one read
    /// gave 0 for a place 0.79 into the file, and the jump kept the file's start).
    @Test(arguments: [false, true]) func aContentsJumpLandsOnTheChapterInsideItsFile(settling: Bool) async throws {
        let f = try await S.make(remote: { _, _ in nil }, startAt: 0.05)
        await f.model.load()
        await f.model.locationDidChange(try #require(f.page.currentLocation))
        let entry = try #require(f.model.toc.last(where: { $0.progression > 0.3 && $0.link.url().fragment != nil }))
        let fragment = try #require(entry.link.url().fragment)
        nonisolated(unsafe) let publication = f.publication
        let opened = try #require(await publication.locate(entry.link))
        let fileStart = opened.copy(locations: { $0.fragments = []; $0.progression = 0 }, text: { $0 = Locator.Text() })
        f.page.linkOpens = fileStart
        f.page.fragmentAt[fragment] = 0.6
        if settling { f.page.fragmentFirstReads = [0] }

        await f.model.go(to: entry)
        // The write runs in its own task after the report: waited on as an event, counted.
        for _ in 0..<200 where (saved(f).flatMap { try? Locator(jsonString: $0) }?.locations.progression ?? 0) < 0.5 {
            await Task.yield()
        }

        let kept = try #require(saved(f).flatMap { try? Locator(jsonString: $0) }, "the jump kept no place")
        #expect(ContentsIndex.sameResource(kept.href.string, fileStart.href.string), "the place is in another file")
        #expect((kept.locations.progression ?? 0) > 0.5, "the place kept is the file's start, not the chapter he chose")
        #expect((f.page.currentLocation?.locations.progression ?? 0) > 0.5, "the page stayed on the file's start")
        #expect(f.model.showJumpBack, "the jump has no way back")
        f.model.close()
    }

    /// A file that never lays out in columns (every read of the anchor's place comes back empty): the
    /// jump ends within its reads, keeps Readium's landing in that file and lets its veil go, never a
    /// read loop that outlives its budget (gatefold#172 asked whether 1f50a36's empty reads could hang).
    @Test func aContentsJumpWhoseAnchorIsNeverReadEndsWithinItsReads() async throws {
        // Judged in reads: each beat only yields.
        let f = try await S.make(remote: { _, _ in nil }, startAt: 0.05, jumpBeat: { await Task.yield() })
        await f.model.load()
        await f.model.locationDidChange(try #require(f.page.currentLocation))
        let entry = try #require(f.model.toc.last(where: { $0.progression > 0.3 && $0.link.url().fragment != nil }))
        nonisolated(unsafe) let publication = f.publication
        let opened = try #require(await publication.locate(entry.link))
        let fileStart = opened.copy(locations: { $0.fragments = []; $0.progression = 0 }, text: { $0 = Locator.Text() })
        f.page.linkOpens = fileStart
        // The first two sends never reach the file (a web view still loading); then no place for the
        // anchor, ever: every read is empty.
        f.page.linkRefusals = 2
        f.page.fragmentAt = [:]
        // The opening's own write is settled first.
        for _ in 0..<20 { await Task.yield() }
        let before = saved(f)

        await f.model.go(to: entry)
        for _ in 0..<200 where saved(f) == before { await Task.yield() }
        let kept = try #require(saved(f).flatMap { try? Locator(jsonString: $0) }, "the jump kept no place")
        #expect(saved(f) != before, "the jump that found no anchor kept no place of its own")
        #expect(ContentsIndex.sameResource(kept.href.string, fileStart.href.string), "the place kept is in another file")
        #expect((kept.locations.progression ?? 1) < 0.001, "the place kept is not Readium's landing at the file's start")
        #expect(f.model.showJumpBack, "the jump has no way back")
        #expect(f.page.fragmentReads <= JumpLanding.reads, "\(f.page.fragmentReads) reads, past the budget of \(JumpLanding.reads)")
        #expect(f.page.linkJumps == 3, "sent \(f.page.linkJumps) times: the refused sends weren't sent again, or the reads kept sending")
        f.model.close()
    }

    /// A contents jump inside its file can be overtaken while its file is still laying out (another jump
    /// of his, from the veil's moment): the newer move's page is the place, never the file's first page the
    /// contents jump passed through.
    @Test func aMoveMadeWhileAContentsJumpIsOnItsWayKeepsItsOwnPlace() async throws {
        let f = try await S.make(remote: { _, _ in nil }, startAt: 0.05)
        await f.model.load()
        await f.model.locationDidChange(try #require(f.page.currentLocation))
        let entry = try #require(f.model.toc.last(where: { $0.progression > 0.3 && $0.link.url().fragment != nil }))
        nonisolated(unsafe) let publication = f.publication
        let opened = try #require(await publication.locate(entry.link))
        let fileStart = opened.copy(locations: { $0.fragments = []; $0.progression = 0 }, text: { $0 = Locator.Text() })
        // The file never finishes laying out on its own: the fragment's place is not found.
        f.page.linkOpens = fileStart

        let jump = Task { await f.model.go(to: entry) }
        for _ in 0..<200 where f.page.currentLocation?.href != fileStart.href { await Task.yield() }
        let far = try #require(await S.locate(f.publication, 0.15))
        // The newer move is still on its way when the contents jump gives way: a write of the contents
        // jump's page then would stand, since the newer move's report counts as already kept.
        f.page.holdsJumps = true
        let newer = Task { await f.model.go(to: far, rememberBack: true) }
        for _ in 0..<200 where f.page.jumps.last != far { await Task.yield() }
        await jump.value
        f.page.holdsJumps = false
        f.page.releaseJumps()
        await newer.value
        for _ in 0..<200 where !(saved(f).flatMap { try? Locator(jsonString: $0) }.map { ContentsIndex.sameResource($0.href.string, far.href.string) } ?? false) {
            await Task.yield()
        }

        let kept = try #require(saved(f).flatMap { try? Locator(jsonString: $0) }, "no place kept")
        #expect(ContentsIndex.sameResource(kept.href.string, far.href.string), "the place kept is the overtaken contents jump's, not his newer move's")
        f.model.close()
    }

    /// A contents jump still on its way with no veil over the page (one that let go, or a jump that ran
    /// unveiled) gives way to him: once he turns, touches the page or opens Contents, the chapter's place
    /// arriving later moves nothing, and his page stands (gatefold#254: a page that jumps once he's reading
    /// is the spazz). Judged in beats: his input comes on the second, the chapter's place right after.
    @Test(arguments: ["turn", "touch", "contents"]) func aContentsJumpWithNoVeilGivesWayToHim(_ input: String) async throws {
        final class Beats { var count = 0; var act: (@MainActor () -> Void)? }
        let beats = Beats()
        let f = try await S.make(remote: { _, _ in nil }, startAt: 0.05, jumpBeat: { @MainActor in
            beats.count += 1
            if beats.count == 2 { beats.act?() }
            await Task.yield()
        })
        await f.model.load()
        await f.model.locationDidChange(try #require(f.page.currentLocation))
        let entry = try #require(f.model.toc.last(where: { $0.progression > 0.3 && $0.link.url().fragment != nil }))
        let fragment = try #require(entry.link.url().fragment)
        nonisolated(unsafe) let publication = f.publication
        let opened = try #require(await publication.locate(entry.link))
        let fileStart = opened.copy(locations: { $0.fragments = []; $0.progression = 0 }, text: { $0 = Locator.Text() })
        f.page.linkOpens = fileStart
        // The file is still laying out: no place for the chapter until after his input.
        f.page.fragmentAt = [:]
        beats.act = {
            switch input {
            case "turn": f.model.userTurnedPage()
            case "touch": f.model.noteInteraction()
            default: f.model.contentsOpened()
            }
            f.page.fragmentAt[fragment] = 0.6
        }
        let sent = f.page.jumps.count

        await f.model.go(to: entry)

        #expect(beats.count >= 2, "his input never came: the jump ended first")
        #expect(f.page.jumps.count == sent, "the page was sent to the chapter after he took it (\(input))")
        #expect((f.page.currentLocation?.locations.progression ?? 1) < 0.5, "the page moved off where he was (\(input))")
        if input != "turn" {
            // The trip he took over keeps the page he is on, never the chapter it didn't reach.
            for _ in 0..<200 where !(saved(f).flatMap { try? Locator(jsonString: $0) }.map { ContentsIndex.sameResource($0.href.string, fileStart.href.string) } ?? false) {
                await Task.yield()
            }
            let kept = try #require(saved(f).flatMap { try? Locator(jsonString: $0) }, "no place kept")
            #expect(ContentsIndex.sameResource(kept.href.string, fileStart.href.string), "the place kept isn't the page he is on (\(input))")
            #expect((kept.locations.progression ?? 1) < 0.5, "the place kept is the chapter he never reached (\(input))")
        }
        f.model.close()
    }

    /// A chapter whose load outlasts the flat budget of reads (Back's #170 case, here for a contents jump,
    /// gatefold#254): the reads made while it loads come from their own count, so the jump still reaches
    /// the chapter, and keeps it, once the load comes in. Judged in beats.
    @Test func aContentsJumpWaitsOutASlowChapterLoad() async throws {
        final class Beats { var count = 0; var act: (@MainActor (Int) -> Void)? }
        let beats = Beats()
        let f = try await S.make(remote: { _, _ in nil }, startAt: 0.05, jumpBeat: { @MainActor in
            beats.count += 1
            beats.act?(beats.count)
            await Task.yield()
        })
        await f.model.load()
        await f.model.locationDidChange(try #require(f.page.currentLocation))
        let entry = try #require(f.model.toc.last(where: { $0.progression > 0.3 && $0.link.url().fragment != nil }))
        let fragment = try #require(entry.link.url().fragment)
        nonisolated(unsafe) let publication = f.publication
        let opened = try #require(await publication.locate(entry.link))
        let fileStart = opened.copy(locations: { $0.fragments = []; $0.progression = 0 }, text: { $0 = Locator.Text() })
        f.page.linkOpens = fileStart
        f.page.fragmentAt = [:]
        f.page.loadingChapter = true
        // The load comes in only after more beats than the flat budget has reads.
        let loadsAt = JumpLanding.reads + 20
        beats.act = { beat in
            if beat == loadsAt {
                f.page.loadingChapter = false
                f.page.fragmentAt[fragment] = 0.6
            }
        }

        await f.model.go(to: entry)
        for _ in 0..<200 where (saved(f).flatMap { try? Locator(jsonString: $0) }?.locations.progression ?? 0) < 0.5 {
            await Task.yield()
        }

        #expect(beats.count >= loadsAt, "the jump ended before the load came in, after \(beats.count) beats")
        #expect((f.page.currentLocation?.locations.progression ?? 0) > 0.5, "the page stayed on the file's start")
        let kept = try #require(saved(f).flatMap { try? Locator(jsonString: $0) }, "no place kept")
        #expect((kept.locations.progression ?? 0) > 0.5, "the place kept is the file's start, not the chapter he chose")
        f.model.close()
    }

    /// He leaves while a contents jump is still on its way (its chapter loading): the place kept is the
    /// chapter he chose, at the entry's placed total progression, never the place before the jump and
    /// never its file's first page (gatefold#259). Gone inactive, the jump goes on, and where it lands is
    /// the place once it does, also when it lands while the target is still being written ("inactive,
    /// landing at once"). Judged in beats: he leaves on the second, the chapter's place comes later.
    @Test(arguments: ["close", "inactive", "inactive, landing at once"]) func aContentsJumpLeftOnItsWayKeepsTheChapterHeChose(_ how: String) async throws {
        final class Beats { var count = 0; var act: (@MainActor (Int) -> Void)? }
        let beats = Beats()
        let f = try await S.make(remote: { _, _ in nil }, startAt: 0.05, jumpBeat: { @MainActor in
            beats.count += 1
            beats.act?(beats.count)
            await Task.yield()
        })
        await f.model.load()
        await f.model.locationDidChange(try #require(f.page.currentLocation))
        let entry = try #require(f.model.toc.last(where: { $0.progression > 0.3 && $0.link.url().fragment != nil }))
        let fragment = try #require(entry.link.url().fragment)
        nonisolated(unsafe) let publication = f.publication
        let opened = try #require(await publication.locate(entry.link))
        let fileStart = opened.copy(locations: { $0.fragments = []; $0.progression = 0 }, text: { $0 = Locator.Text() })
        // The open's own reflow (the iPad turned on its side) has ended, leaving the page marked as the
        // layout's: the leave's write must still keep the chapter (CI run 43218442143 dropped it).
        f.model.keeper.reflowWillBegin(.rotation)
        f.model.reflowDidBegin()
        f.model.reflowDidFinish(visible: await f.page.visibleRange())
        for _ in 0..<20 { await Task.yield() }
        f.page.linkOpens = fileStart
        f.page.fragmentAt = [:]
        f.page.loadingChapter = true
        if how == "inactive, landing at once" {
            // The chapter comes in once the target is written, and the jump lands before the leave is done:
            // the leave's last step then finds a landing it didn't write.
            f.model.afterLeaveWrite = { @MainActor in
                f.model.afterLeaveWrite = nil
                f.page.loadingChapter = false
                f.page.fragmentAt[fragment] = 0.6
                for _ in 0..<400 where (f.page.currentLocation?.locations.progression ?? 0) < 0.5 { await Task.yield() }
                for _ in 0..<50 { await Task.yield() }
            }
        }
        for _ in 0..<20 { await Task.yield() }
        let before = saved(f)
        final class Kept { var onLeaving: String?; var leave: Task<Void, Never>? }
        let kept = Kept()
        beats.act = { beat in
            if beat == 2 {
                if how == "close" { f.model.close() } else if let owed = f.model.owedPlaceOnLeaving() {
                    f.model.keepShownPageNow(owed)
                    kept.leave = Task { await f.model.keepOwedPlace(owed) }
                }
            }
            // The first place written after he left is the leave's own: the chapter's place comes later.
            if kept.onLeaving == nil, saved(f) != before { kept.onLeaving = saved(f) }
            if beat == 30, how != "inactive, landing at once" {
                f.page.loadingChapter = false
                f.page.fragmentAt[fragment] = 0.6
            }
        }

        await f.model.go(to: entry)
        await kept.leave?.value
        for _ in 0..<200 where saved(f) == before { await Task.yield() }

        if how == "inactive, landing at once" {
            for _ in 0..<200 where (saved(f).flatMap { try? Locator(jsonString: $0) }?.locations.progression ?? 0) < 0.5 { await Task.yield() }
            for _ in 0..<50 { await Task.yield() }
            let landed = try #require(saved(f).flatMap { try? Locator(jsonString: $0) }, "no place kept")
            #expect((landed.locations.progression ?? 0) > 0.5, "the target written as he left stood over the page the jump landed on")
            f.model.close()
            return
        }
        let leftAt = try #require((how == "close" ? saved(f) : kept.onLeaving).flatMap { try? Locator(jsonString: $0) }, "leaving kept no place")
        #expect((how == "close" ? saved(f) : kept.onLeaving) != before, "leaving kept the place from before the jump (\(how))")
        #expect(ContentsIndex.sameResource(leftAt.href.string, fileStart.href.string), "the place kept on leaving is in another file (\(how))")
        #expect(abs((leftAt.locations.totalProgression ?? -1) - entry.progression) < 0.001, "the place kept on leaving is not the entry's place (\(how))")
        #expect((leftAt.locations.progression ?? 0) > 0.01, "the place kept on leaving is the file's first page (\(how))")
        if how == "inactive" {
            for _ in 0..<200 where (saved(f).flatMap { try? Locator(jsonString: $0) }?.locations.progression ?? 0) < 0.5 { await Task.yield() }
            let landed = try #require(saved(f).flatMap { try? Locator(jsonString: $0) }, "no place kept")
            #expect((landed.locations.progression ?? 0) > 0.5, "the jump that went on after he left didn't keep where it landed")
            f.model.close()
        }
    }

    /// A contents anchor the file doesn't have: Readium's landing stands at once, without waiting out
    /// the reads behind the veil.
    @Test func aContentsAnchorTheFileLacksKeepsReadiumsLanding() async throws {
        let f = try await S.make(remote: { _, _ in nil }, startAt: 0.05)
        await f.model.load()
        await f.model.locationDidChange(try #require(f.page.currentLocation))
        let entry = try #require(f.model.toc.last(where: { $0.progression > 0.3 && $0.link.url().fragment != nil }))
        nonisolated(unsafe) let publication = f.publication
        let opened = try #require(await publication.locate(entry.link))
        let fileStart = opened.copy(locations: { $0.fragments = []; $0.progression = 0 }, text: { $0 = Locator.Text() })
        f.page.linkOpens = fileStart
        f.page.fragmentAbsent = true
        let jumps = f.page.jumps.count

        await f.model.go(to: entry)
        for _ in 0..<200 where saved(f) == nil { await Task.yield() }

        #expect(f.page.jumps.count == jumps, "the page was sent on from Readium's landing")
        let kept = try #require(saved(f).flatMap { try? Locator(jsonString: $0) }, "no place kept")
        #expect(ContentsIndex.sameResource(kept.href.string, fileStart.href.string), "the jump's file isn't the place")
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

    /// Back goes to the page he was reading, even when "where he is" still names the chapter's start
    /// (gatefold#143: on CI a slow opening landed on his page while `location` stayed at the chapter's
    /// first page, so Back remembered that start and took him there).
    @Test func backGoesToThePageOnScreenWhenWhereHeIsLagsAtTheChaptersStart() async throws {
        let f = try await S.make(remote: { _, _ in nil }, startAt: 0.05)
        await f.model.load()
        let his = try #require(f.page.currentLocation)
        try #require((his.locations.progression ?? 0) > 0.05, "his page is partway through its chapter")
        // "Where he is" is the chapter's start; the page has moved on to his, and its report hasn't come
        // in when he jumps (a report keeps `location` off words before the page, see the test below).
        let start = S.boundary(of: his)
        f.page.anchorText = "words-on-the-chapter-start"
        f.page.currentLocation = start
        await f.model.locationDidChange(start, hisMove: true)
        f.page.currentLocation = his
        let lagging = f.model.location?.locations.progression ?? -1
        try #require(lagging < 0.001, "where he is lags at the chapter's start (it reads \(lagging))")
        await f.model.go(toProgression: 0.7, rememberBack: true)
        f.model.backBeat = { await Task.yield() }
        await f.model.goBack()
        let want = his.locations.totalProgression ?? -1
        let at = f.page.currentLocation?.locations.totalProgression ?? -2
        #expect(f.page.currentLocation?.href == his.href, "Back went to another chapter")
        #expect((f.page.currentLocation?.locations.progression ?? 0) > 0.01, "Back landed on the chapter's start")
        #expect(abs(at - want) < 0.005, "Back came back to \(at), not his page at \(want)")
        f.model.close()
    }

    /// gatefold#143's root: after the slow launch landing, a report that isn't his move put "where he
    /// is" back on words read on the chapter's start while his page stayed on screen. The running head
    /// (its chapter), the scrubber and the Cloud's "here" (`JumpSuggestion.isAhead`) all read `location`,
    /// so all three named the chapter's start. They follow the page on screen.
    @Test func whereHeIsFollowsThePageOnScreenAfterTheSlowLaunchLanding() async throws {
        let f = try await S.make(remote: { _, _ in nil }, startAt: 0.05)
        await f.model.load()
        let his = try #require(f.page.currentLocation)
        try #require((his.locations.progression ?? 0) > 0.05, "his page is partway through its chapter")
        await f.model.locationDidChange(his)
        // Words read on the chapter's start and kept with a move (here a swipe; on CI, the launch landing),
        // then his page on screen with no move of his: the report is the move already kept, and the anchor
        // isn't read again. His page's own first words differ from the start's, as they do on a device
        // (the same words would be the layout's report, his words still first on screen).
        let start = S.boundary(of: his)
        f.page.anchorText = "words-on-the-chapter-start"
        f.page.currentLocation = start
        f.model.noteInteraction()
        await f.model.locationDidChange(start)
        let kept = try #require(saved(f), "the swipe kept no place")
        let keptAt = Self.kept(f) ?? -1, startAt = start.locations.totalProgression ?? -2
        try #require(abs(keptAt - startAt) < 0.001, "the place kept (\(keptAt)) isn't the swipe's (\(startAt))")
        f.page.anchorText = "words-on-his-page"
        f.page.currentLocation = his
        await f.model.locationDidChange(his)
        // The place moves only on his move: the report with none leaves it where the swipe put it.
        #expect(saved(f) == kept, "a report with no move of his moved the saved place")
        let want = his.locations.totalProgression ?? -1
        #expect(f.model.location?.href == his.href, "where he is names another chapter")
        #expect((f.model.location?.locations.progression ?? 0) > 0.01, "where he is lags at the chapter's start")
        #expect(abs(f.model.totalProgression - want) < 0.005, "the scrubber and the Cloud's here read \(f.model.totalProgression), not his page at \(want)")
        // His words are read again from his page, so a reflow's restore or the landing check can't take
        // the page back to the chapter's start.
        let anchor = f.model.keeper.anchor?.progression ?? -1
        #expect(anchor > 0.01, "his words stay those read on the chapter's start (\(anchor))")
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
        // Waited on as the event, in yields as the trip's beats are (a fixed count raced them).
        for _ in 0..<(JumpLanding.reads * 20) where f.model.tripsPastTheVeil < 1 { await Task.yield() }
        try #require(f.model.tripsPastTheVeil >= 1, "the trip never got past its veil's limit")
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

    /// A report of the page he has left, delivered late (after his jump's page is on screen, before the
    /// jump's own report), is not his move: his jump's page is the place kept. On CI's iPad (job
    /// 130027739780) a report of the book's first file came 36 ms after a jump landed at 0.309 and was
    /// written as his move; the jump's own report then found the move kept, and the place stayed at 0.
    @Test func aLateReportOfThePageHeLeftIsNotKeptOverHisJump() async throws {
        let f = try await S.make(remote: { _, _ in nil }, startAt: 0.05)
        await f.model.load()
        let left = try #require(f.page.currentLocation)
        await f.model.locationDidChange(left)
        f.page.reportsOnGo = false
        await f.model.go(toProgression: 0.7, rememberBack: true)
        let landed = try #require(f.page.currentLocation)
        try #require(abs((landed.locations.totalProgression ?? -1) - 0.7) < 0.03, "the jump didn't land")
        // Readium's report of the page he left comes late, then the jump's own.
        await f.model.locationDidChange(left)
        await f.model.locationDidChange(landed)
        await Self.settle { abs((Self.kept(f) ?? -1) - 0.7) < 0.03 }
        #expect(abs((Self.kept(f) ?? -1) - 0.7) < 0.03, "a late report of the page he left was kept over his jump, at \(Self.kept(f) ?? -1)")
        f.model.close()
    }

    /// Two jumps before the first is kept: a late report of the first page he left still isn't his move.
    @Test func aLateReportOfThePageLeftBeforeTwoJumpsIsNotKept() async throws {
        let f = try await S.make(remote: { _, _ in nil }, startAt: 0.05)
        await f.model.load()
        let left = try #require(f.page.currentLocation)
        await f.model.locationDidChange(left)
        f.page.reportsOnGo = false
        await f.model.go(toProgression: 0.4, rememberBack: true)
        await f.model.go(toProgression: 0.7, rememberBack: true)
        let landed = try #require(f.page.currentLocation)
        await f.model.locationDidChange(left)
        await f.model.locationDidChange(landed)
        let at = landed.locations.totalProgression ?? -1
        await Self.settle { abs((Self.kept(f) ?? -1) - at) < 0.001 }
        #expect(abs((Self.kept(f) ?? -1) - at) < 0.001, "a late report of the first page left was kept, at \(Self.kept(f) ?? -1)")
        f.model.close()
    }

    /// The late-report rule (gatefold#174) never drops a real move of his. It names only an exact page a
    /// jump left, while Readium names another, before the jump is kept, with no touch. Each case has the
    /// page's own geometry (`pageRange`) lagging on the page he left:
    /// - "turn": a turn of his right after the jump, reported before the geometry caught up;
    /// - "new file": the jump's first report is its new file;
    /// - "scroll": scroll mode, two scrolls of his, each touch with its report;
    /// - "scroll back": scroll mode, his scroll straight back to the exact page the jump left;
    /// - "Readium names it": no touch, and Readium itself names the page left (a jump that stayed on it),
    ///   so only the rule's own check on Readium's page keeps it.
    @Test(arguments: ["turn", "new file", "scroll", "scroll back", "Readium names it"])
    func aMoveOfHisAfterAJumpIsStillKept(how: String) async throws {
        let f = try await S.make(remote: { _, _ in nil }, startAt: 0.05)
        if how.hasPrefix("scroll") { f.model.setPreferences { $0.pageTurn = .scroll } }
        await f.model.load()
        let left = try #require(f.page.currentLocation)
        await f.model.locationDidChange(left)
        f.page.reportsOnGo = false
        await f.model.go(toProgression: 0.7, rememberBack: true)
        let landed = try #require(f.page.currentLocation)
        f.page.shownLocation = left
        let want: Locator
        switch how {
        case "turn":
            want = try #require(await S.locate(f.publication, 0.71))
            f.page.currentLocation = want
            f.model.userTurnedPage()
            await f.model.locationDidChange(want)
        case "new file":
            #expect(landed.href != left.href, "the jump stayed in the file he left")
            want = landed
            await f.model.locationDidChange(landed)
        case "scroll":
            let first = try #require(await S.locate(f.publication, 0.72))
            want = try #require(await S.locate(f.publication, 0.73))
            f.page.currentLocation = first
            f.model.noteInteraction()
            await f.model.locationDidChange(first)
            f.page.currentLocation = want
            f.model.noteInteraction()
            await f.model.locationDidChange(want)
        case "scroll back":
            want = left
            f.page.currentLocation = left
            f.model.noteInteraction()
            await f.model.locationDidChange(left)
        default:
            want = left
            f.page.currentLocation = left
            await f.model.locationDidChange(left)
        }
        let at = want.locations.totalProgression ?? -1
        await Self.settle { abs((Self.kept(f) ?? -1) - at) < 0.001 }
        #expect(abs((Self.kept(f) ?? -1) - at) < 0.001, "his \(how) wasn't kept: \(Self.kept(f) ?? -1), not \(at)")
        f.model.close()
    }

    /// The place kept for the book, as a total progression.
    private static func kept(_ f: S.Fixture) -> Double? {
        f.app.library.book(S.frankenstein.fastHash)?.locatorJSON.flatMap { try? Locator(jsonString: $0) }?.locations.totalProgression
    }

    /// Work that runs on its own tasks (a turn's write, a late Back's report) lands in its own time: wait
    /// until `done` holds, in reads 10 ms apart for at most 2 s, then a quiet 100 ms more so a late
    /// wrong write still shows in the checks that follow.
    private static func settle(_ done: () -> Bool) async {
        for _ in 0..<200 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
        try? await Task.sleep(for: .milliseconds(100))
    }
}
