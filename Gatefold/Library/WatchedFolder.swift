import Foundation
import GatefoldCore
import Observation
import UIKit

/// A folder the reader picked, in iCloud Drive or anywhere Files reaches, that feeds the shelf: every
/// EPUB in it comes aboard, and books put in it later (on a Mac, say) follow at the next look. Places for
/// those books travel through the folder too (`FolderPlaces`), so the same folder picked on an iPhone and
/// an iPad keeps both on the same page. No iCloud entitlement: the folder is the person's own, reached
/// through a bookmark the document picker grants.
@MainActor @Observable
final class WatchedFolder {
    /// The folder's name, for the shelf and the Add menu; nil when none is watched.
    private(set) var name: String?
    private(set) var isLooking = false
    /// The folder can't be reached (moved, deleted, or iCloud Drive signed out). Shown quietly in the menu.
    private(set) var isUnreachable = false

    private struct Saved: Codable {
        var bookmark: Data
        var name: String
        var index = FolderIndex()
        /// Each book's path inside the folder, and the digest of the file Gatefold took from it.
        var digests: [String: String] = [:]
        /// What this device last settled with the others, by book digest (`FolderPlaces.settle`).
        var marks: [String: FolderSyncMark] = [:]
        /// Books that didn't come aboard, by path, with the size and date they had then: tried again at
        /// every look, but said only once until the file changes.
        var failed: [String: FolderIndex.Stamp] = [:]
    }

    @ObservationIgnored private var saved: Saved? {
        didSet { persist() }
    }
    @ObservationIgnored private var pendingWrite: Task<Void, Never>?
    /// Counts each watch and stop, so a look that began before one never saves over it.
    @ObservationIgnored private var generation = 0
    /// Each other device's place for each book at the last look: by book digest, then device ID.
    @ObservationIgnored private var others: [String: [String: FolderPlace]] = [:]
    /// The generation whose places were last traded: until a look has read the other devices' files,
    /// this device doesn't write its own (it can't yet tell a stale page from a new one).
    @ObservationIgnored private var tradedGeneration: Int?
    /// Looks, and writes of the places file, each wait for the one before.
    @ObservationIgnored private var lookTail: Task<Void, Never>?
    @ObservationIgnored private var writeTail: Task<Void, Never>?
    /// What this device's places file held when last read or written, so an unchanged file isn't written again.
    @ObservationIgnored private var lastWritten: FolderPlaceFile?
    private let library: LibraryStore
    private let savedURL: URL
    /// This install's own places file in the folder; random, never tied to the person.
    let deviceID: String
    /// What the places file says read there.
    private let deviceName: String
    /// The open book, whose place the folder never moves under the reader.
    @ObservationIgnored var openBookID: () -> String? = { nil }
    /// How long the page has to rest before the folder hears of it.
    @ObservationIgnored var writeDelay: Duration = .seconds(2)

    /// Where the device ID is kept: a file left out of backups, so a backup restored to a new device
    /// doesn't make two devices write one places file.
    static let deviceIDFile = "folder-device-id"

    init(library: LibraryStore, root: URL = LibraryStore.defaultRoot,
         deviceName: String = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone") {
        self.library = library
        self.deviceName = deviceName
        savedURL = root.appending(path: "watched-folder.json")
        deviceID = Self.deviceID(in: root)
        if let data = try? Data(contentsOf: savedURL), let restored = try? JSONDecoder().decode(Saved.self, from: data) {
            saved = restored
            name = restored.name
        }
    }

    private static func deviceID(in root: URL) -> String {
        var file = root.appending(path: deviceIDFile)
        if let id = try? String(contentsOf: file, encoding: .utf8), !id.isEmpty { return id }
        let id = UUID().uuidString
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? Data(id.utf8).write(to: file, options: .atomic)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? file.setResourceValues(values)
        return id
    }

    /// The digests of the books that came from the folder, whose places it carries.
    var folderDigests: Set<String> { Set(saved?.digests.values.map { $0 } ?? []) }

    // MARK: Choosing

    /// Starts watching the folder the reader picked, and brings its books in.
    @discardableResult
    func watch(_ url: URL, telemetry: GatefoldTelemetry = .shared) async throws -> LibraryStore.ImportResult {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        generation += 1
        others = [:]
        lastWritten = nil
        let shown = Self.displayName(of: url)
        saved = Saved(bookmark: bookmark, name: shown)
        name = shown
        return await look(telemetry: telemetry)
    }

    /// The folder's name as Files shows it: "On My iPhone" for that folder itself, not its name on disk.
    static func displayName(of url: URL) -> String {
        (try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName) ?? url.lastPathComponent
    }

    /// Stops watching. The books stay on the shelf, and the folder keeps every file.
    func stopWatching() {
        generation += 1
        pendingWrite?.cancel()
        saved = nil
        name = nil
        isUnreachable = false
    }

    // MARK: Looking

    /// Brings in books new or changed since the last look, then trades places with the other devices.
    @discardableResult
    func look(telemetry: GatefoldTelemetry = .shared) async -> LibraryStore.ImportResult {
        let before = lookTail
        let task = Task { [weak self] () -> LibraryStore.ImportResult in
            await before?.value
            return await self?.lookNow(telemetry: telemetry) ?? .init()
        }
        lookTail = Task { _ = await task.value }
        return await task.value
    }

    private func lookNow(telemetry: GatefoldTelemetry) async -> LibraryStore.ImportResult {
        guard var current = saved else { return .init() }
        let started = generation
        isLooking = true
        defer { isLooking = false }
        guard let folder = resolve(&current) else {
            isUnreachable = true
            return .init()
        }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }

        // A folder that can't be listed (iCloud Drive signed out, the folder gone) is unreachable, not
        // empty: what was known about it stays, so nothing is read twice once it's back.
        guard let stamps = await Self.listBooks(in: folder) else {
            isUnreachable = true
            return .init()
        }
        isUnreachable = false
        var kept = current.index.stamps.filter { stamps[$0.key] == $0.value }
        var result = LibraryStore.ImportResult()
        var newFailures = 0
        for path in current.index.changed(in: stamps) {
            // One book at a time, so each path keeps the digest of the file it gave; one count for the look.
            let errorBefore = library.lastError
            let one = await library.importBooks(from: [folder.appending(path: path)], source: .folder, telemetry: nil)
            if let book = one.added.first ?? one.alreadyHere.first {
                if let digest = book.digest { current.digests[path] = digest }
                // A stamp with no size or date says nothing about the file: the next look reads it again.
                if let stamp = stamps[path], stamp != FolderIndex.Stamp(size: 0, modified: 0) { kept[path] = stamp }
                current.failed[path] = nil
            } else if current.failed[path] != stamps[path] {
                current.failed[path] = stamps[path]
                newFailures += 1
            } else {
                // Failed again, unchanged: already spoken of.
                library.lastError = errorBefore
            }
            result.added += one.added
            result.alreadyHere += one.alreadyHere
            result.linkedToCloud += one.linkedToCloud
            result.refused += one.refused
        }
        // Several new failures are spoken of together.
        if newFailures > 1 {
            library.lastError = "\(newFailures) books in “\(current.name)” didn't come aboard. Gatefold reads EPUB books; is each one?"
        }
        // Stopped, or another folder chosen, while this look went on: what it found is no longer wanted.
        guard generation == started else { return result }
        // A book gone from the folder stays on the shelf (it was copied in); its place just stops travelling.
        // Only what the look owns is saved: marks settled meanwhile (`writeNow` trades while books import) stay.
        guard var latest = saved else { return result }
        latest.bookmark = current.bookmark
        latest.digests = current.digests.filter { stamps[$0.key] != nil }
        latest.failed = current.failed.filter { stamps[$0.key] != nil }
        latest.index = FolderIndex(stamps: kept)
        saved = latest
        if result != LibraryStore.ImportResult() {
            telemetry.capture("gatefold_books_added", properties: GatefoldTelemetry.addedProperties(source: .folder, result: result))
        }
        await tradePlaces(in: folder)
        return result
    }

    /// The bookmark's folder, renewing a stale bookmark while it still resolves.
    private func resolve(_ current: inout Saved) -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: current.bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return nil
        }
        if stale, url.startAccessingSecurityScopedResource() {
            defer { url.stopAccessingSecurityScopedResource() }
            if let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) { current.bookmark = fresh }
        }
        return url
    }

    /// The folder's books, by path inside it, with each one's size and date; nil when the folder can't be
    /// listed. Read through a file coordinator, so iCloud Drive lists what it has, downloaded or not.
    nonisolated private static func listBooks(in folder: URL) async -> [String: FolderIndex.Stamp]? {
        await Task.detached(priority: .utility) {
            var stamps: [String: FolderIndex.Stamp]?
            var error: NSError?
            NSFileCoordinator().coordinate(readingItemAt: folder, options: .immediatelyAvailableMetadataOnly, error: &error) { readable in
                guard (try? FileManager.default.contentsOfDirectory(atPath: readable.path)) != nil else { return }
                var found: [String: FolderIndex.Stamp] = [:]
                let base = readable.standardizedFileURL.path + "/"
                for url in BookFile.books(in: readable) {
                    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .totalFileSizeKey])
                    let path = String(url.standardizedFileURL.path.dropFirst(base.count))
                    found[path] = FolderIndex.Stamp(size: Int64(values?.fileSize ?? values?.totalFileSize ?? 0),
                                                    modified: values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
                }
                stamps = found
            }
            return error == nil ? stamps : nil
        }.value
    }

    // MARK: Places

    /// A place was kept here for a book: the folder hears of it a moment later, once the turning stops.
    func placeChanged(_ bookID: String) {
        guard saved != nil, let digest = library.book(bookID)?.digest, folderDigests.contains(digest) else { return }
        pendingWrite?.cancel()
        pendingWrite = Task { [weak self] in
            try? await Task.sleep(for: self?.writeDelay ?? .seconds(2))
            guard !Task.isCancelled, let self else { return }
            await self.writeNow()
        }
    }

    /// Writes this device's places now, without waiting for the page to rest: Gatefold is leaving, and iOS
    /// may suspend it before a write still waiting would land.
    func writeNow() async {
        pendingWrite?.cancel()
        pendingWrite = nil
        guard var current = saved, let folder = resolve(&current) else { return }
        if current.bookmark != saved?.bookmark { saved?.bookmark = current.bookmark }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        // Before this launch has read the others' files, a place here may be a stale page: trade first.
        if tradedGeneration == generation {
            await writeOwnPlaces(in: folder)
        } else {
            await tradePlaces(in: folder)
        }
    }

    /// This device's place for a book, as settling sees it.
    private func local(_ book: LibraryBook) -> FolderSyncMark.Seen? {
        book.lastOpened.map { FolderSyncMark.Seen(updated: $0, progression: book.totalProgression) }
    }

    /// Settles each book's place with the places the other devices left in the folder, then writes this
    /// device's own. The open book is never moved under the reader: it settles once it's closed.
    private func tradePlaces(in folder: URL) async {
        let started = generation
        let read = await Self.readPlaceFiles(in: folder, own: deviceID)
        guard generation == started, var current = saved else { return }
        if lastWritten == nil { lastWritten = read.own }
        var byBook: [String: [String: FolderPlace]] = [:]
        for (device, file) in read.others {
            for (digest, place) in file.places { byBook[digest, default: [:]][device] = place }
        }
        others = byBook
        let digests = folderDigests
        for book in library.books where book.isOnDevice {
            guard let digest = book.digest, digests.contains(digest) else { continue }
            let remotes = byBook[digest] ?? [:]
            let mark = current.marks[digest]
            // A device whose file couldn't be read this time is still known as it was.
            let seenNow = (mark?.others ?? [:]).merging(remotes.mapValues(FolderSyncMark.Seen.init)) { $1 }
            switch FolderPlaces.settle(remotes, local: local(book), mark: mark) {
            case let .takeRemote(place):
                guard book.id != openBookID() else { continue }
                library.takeFolderPlace(bookID: book.id, locatorJSON: place.locator, totalProgression: place.progression, updated: place.updated)
                current.marks[digest] = FolderSyncMark(others: seenNow, local: FolderSyncMark.Seen(place), taken: FolderSyncMark.Seen(place))
            case .keepLocal:
                current.marks[digest] = FolderSyncMark(others: seenNow, local: local(book), taken: mark?.taken)
            }
        }
        current.marks = current.marks.filter { digests.contains($0.key) }
        saved?.marks = current.marks
        tradedGeneration = started
        await writeOwnPlaces(in: folder)
    }

    /// This device's places file: only what was read here. A place taken from another device isn't
    /// written back (the others would read it as a new move), and neither is the place of a book whose
    /// newer place elsewhere is still to be taken (it was open); each keeps what this file said before.
    private func writeOwnPlaces(in folder: URL) async {
        let before = writeTail
        let task = Task { [weak self] in
            await before?.value
            await self?.writeOwnPlacesNow(in: folder)
        }
        writeTail = task
        await task.value
    }

    private func writeOwnPlacesNow(in folder: URL) async {
        guard let current = saved, tradedGeneration == generation else { return }
        let started = generation
        let digests = folderDigests
        var file = FolderPlaceFile(device: deviceName)
        for book in library.books {
            guard let digest = book.digest, digests.contains(digest) else { continue }
            let mark = current.marks[digest]
            let pending = if case .takeRemote = FolderPlaces.settle(others[digest] ?? [:], local: local(book), mark: mark) { true } else { false }
            let onTakenPage = if let taken = mark?.taken, let here = local(book) { !here.differs(from: taken) } else { false }
            if pending || onTakenPage {
                if let earlier = lastWritten?.places[digest] { file.record(earlier, for: digest) }
                continue
            }
            guard let locator = book.locatorJSON, let updated = book.lastOpened else { continue }
            file.record(FolderPlace(locator: locator, progression: book.totalProgression, updated: updated, device: deviceName), for: digest)
        }
        guard !file.places.isEmpty, file != lastWritten, let data = try? FolderPlaces.encode(file) else { return }
        let target = folder.appending(path: FolderPlaces.directory, directoryHint: .isDirectory).appending(path: FolderPlaces.fileName(deviceID: deviceID))
        let wrote = await Task.detached(priority: .utility) {
            var error: NSError?
            var done = false
            NSFileCoordinator().coordinate(writingItemAt: target, options: .forReplacing, error: &error) { writable in
                try? FileManager.default.createDirectory(at: writable.deletingLastPathComponent(), withIntermediateDirectories: true)
                done = (try? data.write(to: writable, options: .atomic)) != nil
            }
            return done
        }.value
        if wrote, generation == started { lastWritten = file }
    }

    /// Every device's places file in the folder: this device's own, and the others' by device ID. A file
    /// iCloud Drive hasn't downloaded yet is listed as a placeholder; the coordinated read downloads it.
    nonisolated private static func readPlaceFiles(in folder: URL, own: String) async -> (own: FolderPlaceFile?, others: [String: FolderPlaceFile]) {
        await Task.detached(priority: .utility) {
            let dir = folder.appending(path: FolderPlaces.directory, directoryHint: .isDirectory)
            let listed = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            var mine: FolderPlaceFile?
            var files: [String: FolderPlaceFile] = [:]
            for name in Set(listed.compactMap(FolderPlaces.placesFile(listedAs:))).sorted() {
                guard let device = FolderPlaces.deviceID(fromFileName: name) else { continue }
                var error: NSError?
                NSFileCoordinator().coordinate(readingItemAt: dir.appending(path: name), options: [], error: &error) { readable in
                    guard let data = try? Data(contentsOf: readable), let file = try? FolderPlaces.decode(data) else { return }
                    if device == own { mine = file } else { files[device] = file }
                }
            }
            return (mine, files)
        }.value
    }

    private func persist() {
        if let saved, let data = try? JSONEncoder().encode(saved) {
            try? data.write(to: savedURL, options: .atomic)
        } else if saved == nil {
            try? FileManager.default.removeItem(at: savedURL)
        }
    }
}
