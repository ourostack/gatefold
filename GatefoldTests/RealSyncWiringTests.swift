import Foundation
import Testing
@testable import Gatefold

/// A scripted Cloud: returns what the test says and records what the app sends.
actor StubSync: SyncService {
    var libraryResult: Result<[CloudBook], CloudError> = .success([])
    var signedInAccount: CloudAccount? = CloudAccount(email: "reader@example.com", store: FakeSyncService.stores[0])
    private(set) var pushed: [(ReadingPosition, String)] = []
    private(set) var flushes = 0

    /// What `remotePosition` answers: the other device's place.
    var remote: ReadingPosition?
    private(set) var remoteReads = 0

    func setLibrary(_ result: Result<[CloudBook], CloudError>) { libraryResult = result }
    func setRemote(_ position: ReadingPosition?) { remote = position }

    var account: CloudAccount? { signedInAccount }
    func stores(forEmail email: String) async throws -> [CloudStore] { FakeSyncService.stores }
    func signIn(email: String, password: String, store: CloudStore) async throws -> CloudAccount { signedInAccount! }
    func signOut() async { signedInAccount = nil }
    func cachedLibrary() async -> [CloudBook] { [] }
    func library() async throws -> [CloudBook] { try libraryResult.get() }
    func download(_ book: CloudBook) async throws -> URL { throw CloudError.notFound }
    func upload(fileAt url: URL) async throws -> CloudBook { throw CloudError.notFound }
    func delete(_ book: CloudBook) async throws {}
    func remotePosition(for book: CloudBook) async throws -> ReadingPosition? {
        remoteReads += 1
        return remote
    }
    func push(_ position: ReadingPosition, for book: CloudBook) async { pushed.append((position, book.fastHash)) }
    private(set) var markedRead: [String] = []
    func markRead(_ book: CloudBook) async { markedRead.append(book.fastHash) }
    func annotations(for book: CloudBook) async throws -> [CloudAnnotation] { [] }
    func save(_ annotation: CloudAnnotation, for book: CloudBook) async {}
    func deleteAnnotation(_ annotation: CloudAnnotation, for book: CloudBook) async {}
    func pendingChanges() async -> Int { 0 }
    func flushOutbox() async { flushes += 1 }
    nonisolated func changes() -> AsyncStream<CloudChange> { AsyncStream { $0.finish() } }
}

@MainActor @Suite struct RealSyncWiringTests {
    let frankenstein = CloudBook(fastHash: "56f8619536655be4a1541a40c5702d32", name: "pg84.epub", title: "Frankenstein", authors: "Mary Shelley")

    private func makeStore(_ sync: StubSync) -> (LibraryStore, URL) {
        let root = URL.temporaryDirectory.appending(path: "wiring-tests-\(UUID().uuidString)")
        return (LibraryStore(sync: sync, root: root), root)
    }

    @Test func demoBooksLeaveARealAccountsShelf() async throws {
        let sync = StubSync()
        let (store, root) = makeStore(sync)
        // A shelf left over from the fake Cloud, one demo book downloaded.
        let demo = try await FakeSyncService(signedIn: true, latency: .zero).library()
        await store.merge(demo)
        let file = root.appending(path: "Books/gutenberg-emma.epub")
        try Data("PK".utf8).write(to: file)
        store.update("gutenberg-emma") { $0.fileName = "gutenberg-emma.epub" }

        await sync.setLibrary(.success([frankenstein]))
        await store.refresh()
        #expect(store.books.map(\.id) == [frankenstein.fastHash])
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aBookGoneFromTheCloudStaysIfDownloaded() async throws {
        let sync = StubSync()
        let (store, root) = makeStore(sync)
        let other = CloudBook(fastHash: "aaaa", name: "a.epub", title: "Gone")
        await sync.setLibrary(.success([frankenstein, other]))
        await store.refresh()
        try Data("PK".utf8).write(to: root.appending(path: "Books/aaaa.epub"))
        store.update("aaaa") { $0.fileName = "aaaa.epub" }

        await sync.setLibrary(.success([other]))
        await store.refresh()
        #expect(store.book(frankenstein.fastHash) == nil, "cloud-only and gone: off the shelf")
        await sync.setLibrary(.success([]))
        await store.refresh()
        #expect(store.book("aaaa")?.isOnDevice == true)
        #expect(store.book("aaaa")?.cloud == nil, "kept, unlinked from the Cloud")
    }

    @Test func offlineIsAQuietLineNotAnAlert() async {
        let sync = StubSync()
        let (store, _) = makeStore(sync)
        await sync.setLibrary(.failure(.offline))
        await store.refresh()
        #expect(store.syncProblem == .offline)
        #expect(store.lastError == nil)
        await sync.setLibrary(.success([frankenstein]))
        await store.refresh()
        #expect(store.syncProblem == nil)
    }

    @Test func anExpiredSignInAsksToReconnectAndKeepsTheShelf() async {
        let sync = StubSync()
        let app = AppModel(sync: sync, libraryRoot: URL.temporaryDirectory.appending(path: "wiring-app-\(UUID().uuidString)"))
        await sync.setLibrary(.success([frankenstein]))
        await app.start()
        #expect(app.library.books.count == 1)

        await sync.setLibrary(.failure(.authenticationRequired))
        await app.refresh()
        #expect(app.needsReconnect == "reader@example.com")
        #expect(app.account != nil, "still the same account, just needs its password again")
        #expect(app.library.books.count == 1)

        await app.apply(.signedIn(CloudAccount(email: "reader@example.com", store: FakeSyncService.stores[0])))
        #expect(app.needsReconnect == nil)
    }

    @Test func theOutboxAskingForSignInAlsoAsksToReconnect() async {
        let sync = StubSync()
        let app = AppModel(sync: sync, libraryRoot: URL.temporaryDirectory.appending(path: "wiring-app-\(UUID().uuidString)"))
        await app.start()
        await app.apply(.authenticationRequired)
        #expect(app.needsReconnect == "reader@example.com")
    }

    @Test func thePlaceGoesOutWithItsExactCFIAndIsSentOnClose() async throws {
        let sync = StubSync()
        let (store, _) = makeStore(sync)
        await sync.setLibrary(.success([frankenstein]))
        await store.refresh()
        let cfi = "epubcfi(/6/16[item9]!/4/2[pgepubid00007]/4/1:0)"
        let exact = ReadingPosition(cfi: cfi, progression: 0.01, totalProgression: 0.09, updated: .distantPast, source: .unknown)
        let now = Date()
        store.recordPlace(bookID: frankenstein.fastHash, locatorJSON: "{}", totalProgression: 0.09, progression: 0.01, position: exact, at: now)

        let pending = try #require(store.pendingPush(for: frankenstein.fastHash))
        #expect(pending.cfi == cfi)
        #expect(pending.source == .gatefold)
        #expect(pending.updated == now)

        await store.sendPendingPushes()
        let pushed = await sync.pushed
        #expect(pushed.count == 1)
        #expect(pushed.first?.0.cfi == cfi)
        #expect(await sync.flushes == 1, "closing the book sends at once instead of after the debounce")
    }

    @Test func aBookWithoutAMapperStillSyncsItsPercent() async throws {
        let sync = StubSync()
        let (store, _) = makeStore(sync)
        await sync.setLibrary(.success([frankenstein]))
        await store.refresh()
        store.recordPlace(bookID: frankenstein.fastHash, locatorJSON: "{}", totalProgression: 0.4, progression: 0.2)
        let pending = try #require(store.pendingPush(for: frankenstein.fastHash))
        #expect(pending.cfi == nil)
        #expect(pending.totalProgression == 0.4)
    }

    @Test func finishingABookMovesItToFinishedAndCountsSessions() async throws {
        let sync = StubSync()
        let (store, _) = makeStore(sync)
        await sync.setLibrary(.success([frankenstein]))
        await store.refresh()
        let id = frankenstein.fastHash
        let start = Date(timeIntervalSince1970: 1_000_000)
        store.noteSession(id, at: start)
        store.noteSession(id, at: start.addingTimeInterval(3600))
        store.recordPlace(bookID: id, locatorJSON: "{}", totalProgression: 0.5, progression: 0.5, at: start)
        #expect(store.readingNow.map(\.id) == [id])
        #expect(store.finishedBooks.isEmpty)

        store.markFinished(id, at: start.addingTimeInterval(86_400 * 3))
        let book = try #require(store.book(id))
        #expect(book.started == start)
        #expect(book.sessions == 2)
        #expect(book.isFinished)
        #expect(store.readingNow.isEmpty, "a finished book leaves Reading Now")
        #expect(store.finishedBooks.map(\.id) == [id])
    }

    @Test func markFinishedOnInkPadPushesAHundredPercentAndMarksRead() async throws {
        let sync = StubSync()
        let (store, _) = makeStore(sync)
        await sync.setLibrary(.success([frankenstein]))
        await store.refresh()
        await store.markFinishedInCloud(frankenstein.fastHash)
        let pushed = await sync.pushed
        #expect(pushed.last?.0.totalProgression == 1)
        #expect(pushed.last?.0.source == .gatefold)
        #expect(await sync.markedRead == [frankenstein.fastHash])
        #expect(await sync.flushes >= 1)
        #expect(store.book(frankenstein.fastHash)?.finished != nil)
    }

    @Test func aBookTheCloudSaysIsReadIsFinished() async throws {
        let sync = StubSync()
        let (store, _) = makeStore(sync)
        var read = frankenstein
        read.readStatus = "read"
        await sync.setLibrary(.success([read]))
        await store.refresh()
        #expect(store.finishedBooks.map(\.id) == [frankenstein.fastHash])
    }

    @Test func theRealCloudIsTheDefault() {
        #expect(AppModel.makeSyncService() is PocketBookCloud)
    }
}

@Suite struct ContainerXMLTests {
    @Test func findsThePackageDocument() {
        let xml = #"<container version="1.0"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>"#
        #expect(BookPositions.packagePath(inContainerXML: Data(xml.utf8)) == "OEBPS/content.opf")
        #expect(BookPositions.packagePath(inContainerXML: Data("<container/>".utf8)) == nil)
    }
}
