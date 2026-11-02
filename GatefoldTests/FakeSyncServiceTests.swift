import Foundation
import GatefoldCore
import Testing
@testable import Gatefold

@Suite struct FakeSyncServiceTests {
    @Test func signInRejectsWrongPasswordAndUnknownEmail() async throws {
        let sync = FakeSyncService(latency: .zero)
        let store = FakeSyncService.stores[0]
        await #expect(throws: CloudError.invalidCredentials) {
            _ = try await sync.signIn(email: "a@b.c", password: "wrong", store: store)
        }
        await #expect(throws: CloudError.noAccount) {
            _ = try await sync.stores(forEmail: "nobody")
        }
        let account = try await sync.signIn(email: "a@b.c", password: "hunter2", store: store)
        #expect(account.store == store)
        #expect(await sync.account == account)
    }

    @Test func libraryListsSeedsWithCoversAndDownloadsEPUBs() async throws {
        let sync = FakeSyncService(signedIn: true, latency: .zero)
        let books = try await sync.library()
        #expect(books.count == FakeSyncService.seeds.count)
        let moby = try #require(books.first { $0.title == "Moby-Dick" })
        #expect(moby.coverURL != nil)
        let file = try await sync.download(moby)
        let data = try Data(contentsOf: file)
        #expect(data.prefix(2) == Data("PK".utf8))
    }

    @Test func remotePositionsAreTheInkPads() async throws {
        let sync = FakeSyncService(signedIn: true, latency: .zero)
        let moby = try #require(try await sync.library().first { $0.title == "Moby-Dick" })
        let position = try #require(try await sync.remotePosition(for: moby))
        #expect(position.totalProgression == 0.42)
        #expect(position.source == .pocketBookNative)
    }

    @Test func pushedPositionsAreBroadcast() async throws {
        let sync = FakeSyncService(signedIn: true, latency: .zero)
        let stream = sync.changes()
        await sync.simulateRemoteRead(bookID: "gutenberg-emma", totalProgression: 0.5)
        var it = stream.makeAsyncIterator()
        let change = await it.next()
        guard case let .remotePosition(id, p)? = change else {
            Issue.record("expected a position change, got \(String(describing: change))")
            return
        }
        #expect(id == "gutenberg-emma")
        #expect(p.totalProgression == 0.5)
    }
}

@MainActor @Suite struct LibraryStoreTests {
    private func makeStore(signedIn: Bool = true) -> (LibraryStore, URL) {
        let root = URL.temporaryDirectory.appending(path: "library-tests-\(UUID().uuidString)")
        return (LibraryStore(sync: FakeSyncService(signedIn: signedIn, latency: .zero), root: root), root)
    }

    @Test func refreshMergesCloudBooksAndRemotePositions() async {
        let (store, _) = makeStore()
        await store.refresh()
        #expect(store.books.count == FakeSyncService.seeds.count)
        let moby = store.books.first { $0.title == "Moby-Dick" }
        #expect(moby?.remote?.totalProgression == 0.42)
        #expect(moby?.displayProgression == 0.42)
        #expect(store.state(of: moby!) == .cloudOnly)
    }

    @Test func aSuccessfulRefreshStampsTheSyncAndRemembersTheInkPad() async throws {
        let (store, _) = makeStore()
        #expect(store.lastSynced == nil || store.lastSynced! <= .now)
        let before = Date.now
        await store.refresh()
        #expect(try #require(store.lastSynced) >= before)
        #expect(!store.cloudIsEmpty)
        let frankenstein = try #require(store.books.first { $0.title == "Frankenstein" })
        #expect(frankenstein.otherDevice == "InkPad")
        #expect(try #require(frankenstein.otherSince) < before, "the InkPad's own date, not the fetch time")
    }

    @Test func theShelfComesBackFromDiskBeforeAnyFetch() async throws {
        let (store, root) = makeStore()
        await store.refresh()
        let count = store.books.count
        let reopened = LibraryStore(sync: FakeSyncService(signedIn: true, latency: .seconds(60)), root: root)
        #expect(reopened.books.count == count, "the cached shelf is there at launch, no fetch needed")
    }

    @Test func downloadPutsTheBookOnDeviceAndSurvivesReload() async throws {
        let (store, root) = makeStore()
        await store.refresh()
        let emma = try #require(store.books.first { $0.title == "Emma" })
        await store.download(emma)
        let after = try #require(store.book(emma.id))
        #expect(store.state(of: after) == .onDevice)
        #expect(FileManager.default.fileExists(atPath: store.fileURL(of: after)!.path))

        let reopened = LibraryStore(sync: FakeSyncService(signedIn: true, latency: .zero), root: root)
        #expect(reopened.book(emma.id)?.isOnDevice == true)
    }

    @Test func recordingAPlaceMovesTheBookToReadingNow() async throws {
        let (store, _) = makeStore()
        await store.refresh()
        let emma = try #require(store.books.first { $0.title == "Emma" })
        store.recordPlace(bookID: emma.id, locatorJSON: "{}", totalProgression: 0.3, progression: 0.1)
        #expect(store.readingNow.first?.id == emma.id)
        #expect(store.book(emma.id)?.totalProgression == 0.3)
    }

    /// The InkPad left the book at 36 %; Readium counts the same words as 25 %. Landing there and
    /// reading three pages on must never shrink the shelf's bar or the Cloud's percent.
    @Test func landingOnACloudPlaceAndReadingOnNeverLowersThePercent() async throws {
        let sync = FakeSyncService(signedIn: true, latency: .zero)
        let store = LibraryStore(sync: sync, root: URL.temporaryDirectory.appending(path: "library-tests-\(UUID().uuidString)"))
        await store.refresh()
        let emma = try #require(store.books.first { $0.title == "Emma" })
        let cloud = try #require(emma.cloud)
        store.landedOnCloudPlace(bookID: emma.id, cloud: 0.36, landed: 0.25)
        store.recordPlace(bookID: emma.id, locatorJSON: "{}", totalProgression: 0.25, progression: 0.5)
        #expect(store.book(emma.id)?.displayPercent == 36)
        var last = 36
        for page in 1...3 {
            store.recordPlace(bookID: emma.id, locatorJSON: "{}", totalProgression: 0.25 + Double(page) * 0.002, progression: 0.5)
            let shown = try #require(store.book(emma.id)?.displayPercent)
            #expect(shown >= last, "page \(page): the shelf went from \(last) % to \(shown) %")
            last = shown
        }
        store.flushPushes()
        try await Task.sleep(for: .milliseconds(80))
        let pushed = try #require(try await sync.remotePosition(for: cloud)?.totalProgression)
        #expect(pushed >= 0.36, "the Cloud was sent \(pushed)")
        // The scale outlives a relaunch.
        let reopened = LibraryStore(sync: sync, root: store.root)
        #expect(reopened.book(emma.id)?.cloudScale == store.book(emma.id)?.cloudScale)
    }

    @Test func afterALandingTheReadersOwnPlaceStaysOnItsOwnScale() async throws {
        // The place this reader compares (for "your InkPad read on") stays Readium's: a later InkPad
        // place at Readium 30 % is ahead of our 26 %, even though the shelf shows 37 %.
        let (store, _) = makeStore()
        await store.refresh()
        let emma = try #require(store.books.first { $0.title == "Emma" })
        store.landedOnCloudPlace(bookID: emma.id, cloud: 0.36, landed: 0.25)
        store.recordPlace(bookID: emma.id, locatorJSON: "{}", totalProgression: 0.26, progression: 0.5)
        let book = try #require(store.book(emma.id))
        #expect(book.localSnapshot?.totalProgression == 0.26)
        #expect(book.displayPercent >= 36)
        #expect(JumpSuggestion.isAhead(remote: 0.30, percentOnly: false, local: book.localSnapshot?.totalProgression ?? 1))
    }

    @Test func aLandingWhoseCloudPercentIsBehindOursNeedsNoScale() async throws {
        let (store, _) = makeStore()
        await store.refresh()
        let emma = try #require(store.books.first { $0.title == "Emma" })
        store.landedOnCloudPlace(bookID: emma.id, cloud: 0.20, landed: 0.25)
        store.recordPlace(bookID: emma.id, locatorJSON: "{}", totalProgression: 0.25, progression: 0.5)
        #expect(store.book(emma.id)?.cloudScale == nil)
        #expect(store.book(emma.id)?.displayPercent == 25)
    }

    @Test func rapidPlacesLandInOrderLatestWins() async throws {
        let sync = FakeSyncService(signedIn: true, latency: .zero)
        let store = LibraryStore(sync: sync, root: URL.temporaryDirectory.appending(path: "library-tests-\(UUID().uuidString)"))
        await store.refresh()
        let emma = try #require(store.books.first { $0.title == "Emma" })
        let cloud = try #require(emma.cloud)
        for p in [0.31, 0.32, 0.33, 0.32] {
            store.recordPlace(bookID: emma.id, locatorJSON: "{}", totalProgression: p, progression: p)
        }
        try await Task.sleep(for: .milliseconds(900))
        #expect(try await sync.remotePosition(for: cloud)?.totalProgression == 0.32)
    }

    @Test func backgroundingSendsTheWaitingPlaceAtOnce() async throws {
        let sync = FakeSyncService(signedIn: true, latency: .zero)
        let store = LibraryStore(sync: sync, root: URL.temporaryDirectory.appending(path: "library-tests-\(UUID().uuidString)"))
        await store.refresh()
        let emma = try #require(store.books.first { $0.title == "Emma" })
        store.recordPlace(bookID: emma.id, locatorJSON: "{}", totalProgression: 0.44, progression: 0.44)
        store.flushPushes()
        try await Task.sleep(for: .milliseconds(80))
        #expect(try await sync.remotePosition(for: try #require(emma.cloud))?.totalProgression == 0.44)
    }

    @Test func importAddsALocalEPUB() async throws {
        let (store, _) = makeStore(signedIn: false)
        let source = try #require(Bundle.main.url(forResource: "frankenstein", withExtension: "epub"))
        let copy = URL.temporaryDirectory.appending(path: "import-\(UUID().uuidString).epub")
        try FileManager.default.copyItem(at: source, to: copy)
        let added = await store.importBooks(from: [copy])
        #expect(added.count == 1)
        #expect(added.first?.title.contains("Frankenstein") == true)
        #expect(added.first?.origin == .imported)
    }
}

/// How the app answers the sync service's change stream. The real `PocketBookCloud` announces
/// `.library` after every fetch, so answering a change with another fetch would never stop.
@MainActor @Suite struct SyncChangeTests {
    private func makeModel(_ sync: FakeSyncService) -> AppModel {
        AppModel(sync: sync, libraryRoot: URL.temporaryDirectory.appending(path: "changes-\(UUID().uuidString)"))
    }

    @Test func libraryAnnouncementsDoNotFetchAgain() async throws {
        let sync = FakeSyncService(signedIn: true, latency: .zero)
        let model = makeModel(sync)
        await model.start()
        try await Task.sleep(for: .milliseconds(600))
        #expect(await sync.libraryFetches == 1)
        #expect(model.library.books.count == FakeSyncService.seeds.count)
    }

    @Test func aRemovedCloudBookLeavesTheShelfUnlessItIsOnDevice() async throws {
        let sync = FakeSyncService(signedIn: true, latency: .zero)
        let model = makeModel(sync)
        await model.library.refresh()
        let emma = try #require(model.library.books.first { $0.title == "Emma" })
        let moby = try #require(model.library.books.first { $0.title == "Moby-Dick" })
        await model.library.download(emma)
        await model.apply(.bookRemoved(fastHash: moby.id))
        await model.apply(.bookRemoved(fastHash: emma.id))
        #expect(model.library.book(moby.id) == nil)
        #expect(model.library.book(emma.id)?.isOnDevice == true)
        #expect(model.library.book(emma.id)?.cloud == nil)
    }

    @Test func anAddedBookArrivesWithoutAFetch() async throws {
        let sync = FakeSyncService(signedIn: true, latency: .zero)
        let model = makeModel(sync)
        let book = CloudBook(fastHash: "new-book", title: "New Book", authors: "Someone", position: ReadingPosition(cfi: nil, totalProgression: 0.2, updated: Date(), source: .pocketBookNative))
        await model.apply(.signedIn(CloudAccount(email: "reader@example.com", store: FakeSyncService.stores[0])))
        await model.apply(.bookAdded(book))
        #expect(model.library.book("new-book")?.remote?.totalProgression == 0.2)
        #expect(await sync.libraryFetches == 0)
    }

    @Test func aLateLibraryAfterSignOutDoesNotRefillTheShelf() async throws {
        let sync = FakeSyncService(signedIn: true, latency: .zero)
        let model = makeModel(sync)
        await model.start()
        let books = await sync.cachedLibrary()
        await model.apply(.signedOut)
        await model.apply(.library(books))
        await model.apply(.bookAdded(books[0]))
        #expect(model.library.books.isEmpty)
    }

    @Test func expiredSignInAsksToConnectAgainAndKeepsBooks() async throws {
        let sync = FakeSyncService(signedIn: true, latency: .zero)
        let model = makeModel(sync)
        await model.start()
        let count = model.library.books.count
        await model.apply(.authenticationRequired)
        // The shelf and the account's name stay; the library offers to sign in again as that account.
        #expect(model.account?.email == "reader@example.com")
        #expect(model.needsReconnect == "reader@example.com")
        #expect(model.library.books.count == count)
    }
}
