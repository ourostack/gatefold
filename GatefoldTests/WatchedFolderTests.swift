import Foundation
import GatefoldCore
import Testing
@testable import Gatefold

/// A folder the reader picked feeds the shelf, and carries places between the devices that watch it.
/// A local folder stands in for iCloud Drive: what crosses between devices is files in the folder.
@MainActor @Suite struct WatchedFolderTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// One device: its own shelf, its own saved state and its own random device ID.
    private struct Device {
        let store: LibraryStore
        let folder: WatchedFolder
        let root: URL
    }

    private func device(_ name: String = "iPhone", root: URL? = nil) -> Device {
        let root = root ?? URL.temporaryDirectory.appending(path: "folder-tests-\(UUID().uuidString)")
        let store = LibraryStore(sync: FakeSyncService(signedIn: false, latency: .zero), root: root)
        let folder = WatchedFolder(library: store, root: root, deviceName: name)
        folder.writeDelay = .zero
        return Device(store: store, folder: folder, root: root)
    }

    /// Makes `url` unreadable for the rest of `body`, the way a folder iCloud Drive can't reach answers.
    private func unreadable<T>(_ url: URL, _ body: () async throws -> T) async rethrows -> T {
        let before = try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
        try? FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: before ?? 0o755], ofItemAtPath: url.path) }
        return try await body()
    }

    private func shared() throws -> URL {
        let dir = URL.temporaryDirectory.appending(path: "folder-src-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func put(_ resource: String, in dir: URL, as name: String? = nil) throws {
        let source = try #require(Bundle.main.url(forResource: resource, withExtension: "epub"))
        let target = dir.appending(path: name ?? "\(resource).epub")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: target)
    }

    private func placeFiles(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.appending(path: FolderPlaces.directory).path)) ?? []).sorted()
    }

    private func locator(_ progression: Double) -> String { "{\"locations\":{\"totalProgression\":\(progression)}}" }

    @Test func watchingAFolderBringsItsBooksAndTheOnesPutThereLater() async throws {
        let phone = device()
        let dir = try shared()
        try put("emma", in: dir)
        try put("dracula", in: dir, as: "Gothic/Dracula.epub")
        try Data("%PDF-1.7".utf8).write(to: dir.appending(path: "scan.pdf"))

        let first = try await phone.folder.watch(dir)
        #expect(first.added.count == 2)
        #expect(phone.folder.name == dir.lastPathComponent)
        #expect(phone.store.books.allSatisfy { $0.source == .folder && $0.arrivalLabel == "From your folder" })

        // Nothing new: nothing is read again.
        #expect(await phone.folder.look() == LibraryStore.ImportResult())

        try put("frankenstein", in: dir)
        let later = await phone.folder.look()
        #expect(later.added.map(\.title).contains { $0.contains("Frankenstein") })
        #expect(phone.store.books.count == 3)
    }

    @Test func theFolderIsStillWatchedAfterARelaunch() async throws {
        let first = device()
        let dir = try shared()
        try put("emma", in: dir)
        try await first.folder.watch(dir)

        let relaunched = device(root: first.root)
        #expect(relaunched.folder.name == dir.lastPathComponent)
        #expect(relaunched.folder.deviceID == first.folder.deviceID)
        try put("moby-dick", in: dir)
        let look = await relaunched.folder.look()
        #expect(!relaunched.folder.isUnreachable)
        #expect(look.added.count == 1) // only the new one: Emma was already looked at
        #expect(look.alreadyHere.isEmpty)
    }

    @Test func theDeviceIDNeverTravelsInABackup() throws {
        let phone = device()
        let file = phone.root.appending(path: WatchedFolder.deviceIDFile)
        #expect(try String(contentsOf: file, encoding: .utf8) == phone.folder.deviceID)
        // A backup restored to a new iPhone would otherwise make two devices write one places file.
        #expect(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(device(root: phone.root).folder.deviceID == phone.folder.deviceID)
        #expect(device().folder.deviceID != phone.folder.deviceID)
    }

    @Test func aFolderThatCantBeReadKeepsWhatItKnew() async throws {
        let phone = device()
        let dir = try shared()
        try put("emma", in: dir)
        try await phone.folder.watch(dir)
        let look = await unreadable(dir) { await phone.folder.look() }
        #expect(look == LibraryStore.ImportResult())
        #expect(phone.folder.isUnreachable)
        // Reachable again: nothing is read twice, since nothing was forgotten.
        let again = await phone.folder.look()
        #expect(!phone.folder.isUnreachable)
        #expect(again == LibraryStore.ImportResult())
        #expect(phone.folder.folderDigests.count == 1)
    }

    @Test func aBookThatCouldntBeReadIsTriedAgainAtTheNextLook() async throws {
        let phone = device()
        let dir = try shared()
        try put("emma", in: dir)
        let emma = dir.appending(path: "emma.epub")
        let first = try await unreadable(emma) { try await phone.folder.watch(dir) }
        #expect(first.added.isEmpty)
        // Same size and date as before (iCloud Drive finished downloading it, say): read now all the same.
        let later = await phone.folder.look()
        #expect(later.added.count == 1)
    }

    @Test func stoppingWhileAFolderIsBeingLookedInStaysStopped() async throws {
        let phone = device()
        let dir = try shared()
        try put("emma", in: dir)
        try await phone.folder.watch(dir)
        try put("dracula", in: dir)
        let look = Task { await phone.folder.look() }
        while !phone.folder.isLooking { await Task.yield() }
        phone.folder.stopWatching()
        _ = await look.value
        #expect(phone.folder.name == nil)
        #expect(device(root: phone.root).folder.name == nil)
    }

    @Test func twoDevicesTradePlacesThroughTheFolderAndEachWritesOnlyItsOwnFile() async throws {
        let phone = device("iPhone"), pad = device("iPad")
        let dir = try shared()
        try put("emma", in: dir)
        try await phone.folder.watch(dir)
        let onPhone = try #require(phone.store.books.first)
        phone.store.recordPlace(bookID: onPhone.id, locatorJSON: locator(0.3), totalProgression: 0.3, progression: 0.5, at: t0)
        await phone.folder.look()

        // The iPad picks the same folder: Emma comes aboard there already open at the iPhone's page.
        try await pad.folder.watch(dir)
        let onPad = try #require(pad.store.books.first)
        #expect(onPad.locatorJSON == locator(0.3))
        #expect(onPad.totalProgression == 0.3)

        // Reading on: the iPad's newer place reaches the iPhone at its next look.
        pad.store.recordPlace(bookID: onPad.id, locatorJSON: locator(0.6), totalProgression: 0.6, progression: 0.2, at: t0.addingTimeInterval(600))
        await pad.folder.look()
        await phone.folder.look()
        #expect(phone.store.book(onPhone.id)?.locatorJSON == locator(0.6))

        // One file per device, so iCloud Drive never has two writers of one file.
        #expect(placeFiles(in: dir) == [FolderPlaces.fileName(deviceID: phone.folder.deviceID),
                                         FolderPlaces.fileName(deviceID: pad.folder.deviceID)].sorted())
    }

    @Test func anOlderPlaceFromTheFolderNeverMovesTheReaderBack() async throws {
        let phone = device("iPhone"), pad = device("iPad")
        let dir = try shared()
        try put("emma", in: dir)
        try await phone.folder.watch(dir)
        try await pad.folder.watch(dir)
        let onPhone = try #require(phone.store.books.first), onPad = try #require(pad.store.books.first)
        pad.store.recordPlace(bookID: onPad.id, locatorJSON: locator(0.2), totalProgression: 0.2, progression: 0, at: t0)
        await pad.folder.look()
        phone.store.recordPlace(bookID: onPhone.id, locatorJSON: locator(0.7), totalProgression: 0.7, progression: 0, at: t0.addingTimeInterval(60))
        await phone.folder.look()
        #expect(phone.store.book(onPhone.id)?.locatorJSON == locator(0.7))
    }

    @Test func theOpenBookIsNeverMovedUnderTheReader() async throws {
        let phone = device("iPhone"), pad = device("iPad")
        let dir = try shared()
        try put("emma", in: dir)
        try await phone.folder.watch(dir)
        try await pad.folder.watch(dir)
        let onPhone = try #require(phone.store.books.first), onPad = try #require(pad.store.books.first)
        pad.store.recordPlace(bookID: onPad.id, locatorJSON: locator(0.9), totalProgression: 0.9, progression: 0, at: t0.addingTimeInterval(60))
        await pad.folder.look()
        phone.store.recordPlace(bookID: onPhone.id, locatorJSON: locator(0.1), totalProgression: 0.1, progression: 0, at: t0)
        phone.folder.openBookID = { onPhone.id }
        await phone.folder.look()
        #expect(phone.store.book(onPhone.id)?.locatorJSON == locator(0.1))
    }

    @Test func aStaleOpenBookElsewhereNeverSendsTheReaderBack() async throws {
        let phone = device("iPhone"), pad = device("iPad")
        let dir = try shared()
        try put("emma", in: dir)
        try await phone.folder.watch(dir)
        try await pad.folder.watch(dir)
        let onPhone = try #require(phone.store.books.first), onPad = try #require(pad.store.books.first)
        // Both on the same page to begin with.
        pad.store.recordPlace(bookID: onPad.id, locatorJSON: locator(0.1), totalProgression: 0.1, progression: 0, at: t0)
        await pad.folder.look()
        await phone.folder.look()
        #expect(phone.store.book(onPhone.id)?.locatorJSON == locator(0.1))

        // The iPad has Emma open on that page. On the iPhone, he reads on to half way.
        pad.folder.openBookID = { onPad.id }
        phone.store.recordPlace(bookID: onPhone.id, locatorJSON: locator(0.5), totalProgression: 0.5, progression: 0, at: t0.addingTimeInterval(600))
        await phone.folder.look()
        await pad.folder.look()
        #expect(pad.store.book(onPad.id)?.locatorJSON == locator(0.1)) // never moved under the reader

        // Picking up the iPad, he turns one page there before closing it: newer, but further back.
        pad.store.recordPlace(bookID: onPad.id, locatorJSON: locator(0.11), totalProgression: 0.11, progression: 0, at: t0.addingTimeInterval(1200))
        await pad.folder.writeNow()
        await phone.folder.look()
        #expect(phone.store.book(onPhone.id)?.locatorJSON == locator(0.5))

        // Closed, the iPad's next look catches it up to the iPhone.
        pad.folder.openBookID = { nil }
        await pad.folder.look()
        #expect(pad.store.book(onPad.id)?.locatorJSON == locator(0.5))
    }

    @Test func goingBackToRereadOnOneDeviceReachesTheOther() async throws {
        let phone = device("iPhone"), pad = device("iPad")
        let dir = try shared()
        try put("emma", in: dir)
        try await phone.folder.watch(dir)
        try await pad.folder.watch(dir)
        let onPhone = try #require(phone.store.books.first), onPad = try #require(pad.store.books.first)
        phone.store.recordPlace(bookID: onPhone.id, locatorJSON: locator(0.6), totalProgression: 0.6, progression: 0, at: t0)
        await phone.folder.look()
        await pad.folder.look()
        #expect(pad.store.book(onPad.id)?.locatorJSON == locator(0.6))
        pad.store.recordPlace(bookID: onPad.id, locatorJSON: locator(0.2), totalProgression: 0.2, progression: 0, at: t0.addingTimeInterval(600))
        await pad.folder.look()
        await phone.folder.look()
        #expect(phone.store.book(onPhone.id)?.locatorJSON == locator(0.2))
    }

    @Test func aPlaceTakenFromTheFolderIsNeverWrittenBackAsANewOne() async throws {
        let phone = device("iPhone"), pad = device("iPad")
        let dir = try shared()
        try put("emma", in: dir)
        try await phone.folder.watch(dir)
        try await pad.folder.watch(dir)
        let onPhone = try #require(phone.store.books.first), onPad = try #require(pad.store.books.first)
        phone.store.recordPlace(bookID: onPhone.id, locatorJSON: locator(0.5), totalProgression: 0.5, progression: 0, at: t0.addingTimeInterval(100))
        await phone.folder.look()
        await pad.folder.look()
        #expect(pad.store.book(onPad.id)?.locatorJSON == locator(0.5))
        // The iPad wrote no copy of the iPhone's page, which the iPhone would take for the iPad reading.
        let padFile = dir.appending(path: FolderPlaces.directory).appending(path: FolderPlaces.fileName(deviceID: pad.folder.deviceID))
        #expect((try? FolderPlaces.decode(Data(contentsOf: padFile)))?.places.values.map(\.locator).contains(locator(0.5)) != true)

        // Back on the iPhone, he goes back to reread the opening: that stays, and reaches the iPad.
        phone.store.recordPlace(bookID: onPhone.id, locatorJSON: locator(0.05), totalProgression: 0.05, progression: 0, at: t0.addingTimeInterval(200))
        await phone.folder.look()
        #expect(phone.store.book(onPhone.id)?.locatorJSON == locator(0.05))
        await pad.folder.look()
        #expect(pad.store.book(onPad.id)?.locatorJSON == locator(0.05))
    }

    @Test func openingABookOnAPageTakenFromTheFolderDoesntWriteItBack() async throws {
        let phone = device("iPhone"), pad = device("iPad")
        let dir = try shared()
        try put("emma", in: dir)
        try await phone.folder.watch(dir)
        try await pad.folder.watch(dir)
        let onPhone = try #require(phone.store.books.first), onPad = try #require(pad.store.books.first)
        phone.store.recordPlace(bookID: onPhone.id, locatorJSON: locator(0.5), totalProgression: 0.5, progression: 0, at: t0.addingTimeInterval(10))
        await phone.folder.look()
        await pad.folder.look()
        // The iPhone goes back to reread; before the iPad hears of it, Emma is opened there on the page it took.
        phone.store.recordPlace(bookID: onPhone.id, locatorJSON: locator(0.1), totalProgression: 0.1, progression: 0, at: t0.addingTimeInterval(20))
        await phone.folder.look()
        pad.store.recordPlace(bookID: onPad.id, locatorJSON: locator(0.5), totalProgression: 0.5, progression: 0, at: t0.addingTimeInterval(25))
        await pad.folder.writeNow()
        await phone.folder.look()
        #expect(phone.store.book(onPhone.id)?.locatorJSON == locator(0.1), "opening the book on the iPad sent the iPhone back to its old page")
        await pad.folder.look()
        #expect(pad.store.book(onPad.id)?.locatorJSON == locator(0.1))
    }

    @Test func aDeviceWhoseFileCouldntBeReadOnceIsStillKnown() async throws {
        let phone = device("iPhone"), pad = device("iPad")
        let dir = try shared()
        try put("emma", in: dir)
        try await phone.folder.watch(dir)
        try await pad.folder.watch(dir)
        let onPhone = try #require(phone.store.books.first), onPad = try #require(pad.store.books.first)
        // The iPhone's clock runs an hour ahead of the iPad's.
        phone.store.recordPlace(bookID: onPhone.id, locatorJSON: locator(0.5), totalProgression: 0.5, progression: 0, at: t0.addingTimeInterval(3600))
        await phone.folder.look()
        await pad.folder.look()
        #expect(pad.store.book(onPad.id)?.locatorJSON == locator(0.5))
        pad.store.recordPlace(bookID: onPad.id, locatorJSON: locator(0.8), totalProgression: 0.8, progression: 0, at: t0.addingTimeInterval(30))
        let phoneFile = dir.appending(path: FolderPlaces.directory).appending(path: FolderPlaces.fileName(deviceID: phone.folder.deviceID))
        await unreadable(phoneFile) { await pad.folder.look() }
        await pad.folder.look()
        #expect(pad.store.book(onPad.id)?.locatorJSON == locator(0.8), "the iPhone's unchanged page, unread once, was taken for a new one")
    }

    @Test func aPageKeptBeforeTheFirstLookAfterARelaunchIsSettledFirst() async throws {
        let phone = device("iPhone"), pad = device("iPad")
        let dir = try shared()
        try put("emma", in: dir)
        try await phone.folder.watch(dir)
        try await pad.folder.watch(dir)
        let onPhone = try #require(phone.store.books.first), onPad = try #require(pad.store.books.first)
        pad.store.recordPlace(bookID: onPad.id, locatorJSON: locator(0.1), totalProgression: 0.1, progression: 0, at: t0)
        await pad.folder.look()
        await phone.folder.look()
        phone.store.recordPlace(bookID: onPhone.id, locatorJSON: locator(0.5), totalProgression: 0.5, progression: 0, at: t0.addingTimeInterval(600))
        await phone.folder.look()

        // The iPad relaunches straight into Emma, on its old page, and turns one page before any look.
        let relaunched = device("iPad", root: pad.root)
        relaunched.folder.openBookID = { onPad.id }
        relaunched.store.recordPlace(bookID: onPad.id, locatorJSON: locator(0.11), totalProgression: 0.11, progression: 0, at: t0.addingTimeInterval(1300))
        await relaunched.folder.writeNow()
        await phone.folder.look()
        #expect(phone.store.book(onPhone.id)?.locatorJSON == locator(0.5))
    }

    @Test func thePlacesFileIsWrittenOnlyWhenAPlaceChanged() async throws {
        let phone = device()
        let dir = try shared()
        try put("emma", in: dir)
        try await phone.folder.watch(dir)
        let book = try #require(phone.store.books.first)
        phone.store.recordPlace(bookID: book.id, locatorJSON: locator(0.4), totalProgression: 0.4, progression: 0, at: t0)
        await phone.folder.look()
        let file = dir.appending(path: FolderPlaces.directory).appending(path: FolderPlaces.fileName(deviceID: phone.folder.deviceID))
        let written = try #require(try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        try await Task.sleep(for: .milliseconds(1100))
        await phone.folder.look()
        var fresh = file
        fresh.removeAllCachedResourceValues()
        #expect(try fresh.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == written)
    }

    @Test func aPlaceStillWaitingIsWrittenWhenGatefoldLeaves() async throws {
        let phone = device()
        phone.folder.writeDelay = .seconds(600)
        let dir = try shared()
        try put("emma", in: dir)
        try await phone.folder.watch(dir)
        let book = try #require(phone.store.books.first)
        phone.store.onPlaceRecorded = { [weak folder = phone.folder] id in folder?.placeChanged(id) }
        phone.store.recordPlace(bookID: book.id, locatorJSON: locator(0.7), totalProgression: 0.7, progression: 0, at: t0)
        await phone.folder.writeNow()
        let file = dir.appending(path: FolderPlaces.directory).appending(path: FolderPlaces.fileName(deviceID: phone.folder.deviceID))
        #expect(try FolderPlaces.decode(Data(contentsOf: file)).places.values.map(\.locator) == [locator(0.7)])
    }

    @Test func aTurnedPageReachesTheFolderOnceThePageRests() async throws {
        let phone = device()
        let dir = try shared()
        try put("emma", in: dir)
        try await phone.folder.watch(dir)
        let book = try #require(phone.store.books.first)
        phone.store.onPlaceRecorded = { [weak folder = phone.folder] id in folder?.placeChanged(id) }
        phone.store.recordPlace(bookID: book.id, locatorJSON: locator(0.4), totalProgression: 0.4, progression: 0, at: t0)
        let file = dir.appending(path: FolderPlaces.directory).appending(path: FolderPlaces.fileName(deviceID: phone.folder.deviceID))
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: file.path) { try await Task.sleep(for: .milliseconds(20)) }
        let written = try FolderPlaces.decode(Data(contentsOf: file))
        #expect(written.places.values.map(\.locator) == [locator(0.4)])
        #expect(written.device == "iPhone")
    }

    @Test func stoppingKeepsTheBooksAndTheFolder() async throws {
        let phone = device()
        let dir = try shared()
        try put("emma", in: dir)
        try await phone.folder.watch(dir)
        phone.folder.stopWatching()
        #expect(phone.folder.name == nil)
        #expect(phone.store.books.count == 1)
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "emma.epub").path))
        #expect(await phone.folder.look() == LibraryStore.ImportResult())
        #expect(device(root: phone.root).folder.name == nil)
    }

    @Test func whatTheShelfSaysWhenAFolderIsWatched() {
        let none = ArrivalWords.watching("Books", result: .init())
        #expect(none.message == "Watching “Books”")
        #expect(none.description == "No books in it yet. Books you put in it later join your shelf.")
        #expect(none.bookID == nil)
    }
}
