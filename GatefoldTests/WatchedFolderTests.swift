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
        let defaults: UserDefaults
    }

    private func device(_ name: String = "iPhone", root: URL? = nil, defaults: UserDefaults? = nil) -> Device {
        let root = root ?? URL.temporaryDirectory.appending(path: "folder-tests-\(UUID().uuidString)")
        let defaults = defaults ?? UserDefaults(suiteName: "folder-tests-\(UUID().uuidString)")!
        let store = LibraryStore(sync: FakeSyncService(signedIn: false, latency: .zero), root: root)
        let folder = WatchedFolder(library: store, root: root, defaults: defaults, deviceName: name)
        folder.writeDelay = .zero
        return Device(store: store, folder: folder, root: root, defaults: defaults)
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

        let relaunched = device(root: first.root, defaults: first.defaults)
        #expect(relaunched.folder.name == dir.lastPathComponent)
        #expect(relaunched.folder.deviceID == first.folder.deviceID)
        try put("moby-dick", in: dir)
        let look = await relaunched.folder.look()
        #expect(!relaunched.folder.isUnreachable)
        #expect(look.added.count == 1) // only the new one: Emma was already looked at
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
        #expect(device(root: phone.root, defaults: phone.defaults).folder.name == nil)
    }

    @Test func whatTheShelfSaysWhenAFolderIsWatched() {
        let none = ArrivalWords.watching("Books", result: .init())
        #expect(none.message == "Watching “Books”")
        #expect(none.description == "No books in it yet. Books you put in it later join your shelf.")
        #expect(none.bookID == nil)
    }
}
