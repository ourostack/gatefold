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
    }

    @ObservationIgnored private var saved: Saved? {
        didSet { persist() }
    }
    @ObservationIgnored private var pendingWrite: Task<Void, Never>?
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

    static let deviceIDKey = "GatefoldFolderDeviceID"

    init(library: LibraryStore, root: URL = LibraryStore.defaultRoot, defaults: UserDefaults = .standard,
         deviceName: String = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone") {
        self.library = library
        self.deviceName = deviceName
        savedURL = root.appending(path: "watched-folder.json")
        if let id = defaults.string(forKey: Self.deviceIDKey) {
            deviceID = id
        } else {
            deviceID = UUID().uuidString
            defaults.set(deviceID, forKey: Self.deviceIDKey)
        }
        if let data = try? Data(contentsOf: savedURL), let restored = try? JSONDecoder().decode(Saved.self, from: data) {
            saved = restored
            name = restored.name
        }
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
        saved = Saved(bookmark: bookmark, name: url.lastPathComponent)
        name = url.lastPathComponent
        return await look(telemetry: telemetry)
    }

    /// Stops watching. The books stay on the shelf, and the folder keeps every file.
    func stopWatching() {
        saved = nil
        name = nil
        isUnreachable = false
    }

    // MARK: Looking

    /// Brings in books new or changed since the last look, then trades places with the other devices.
    @discardableResult
    func look(telemetry: GatefoldTelemetry = .shared) async -> LibraryStore.ImportResult {
        guard var current = saved, !isLooking else { return .init() }
        isLooking = true
        defer { isLooking = false }
        guard let folder = resolve(&current) else {
            isUnreachable = true
            return .init()
        }
        isUnreachable = false
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }

        let books = await Self.listBooks(in: folder)
        let changed = current.index.changed(in: books.stamps)
        var result = LibraryStore.ImportResult()
        for path in changed {
            // One book at a time, so each path keeps the digest of the file it gave; one count for the look.
            let one = await library.importBooks(from: [folder.appending(path: path)], source: .folder, telemetry: nil)
            if let book = one.added.first ?? one.alreadyHere.first, let digest = book.digest {
                current.digests[path] = digest
            }
            result.added += one.added
            result.alreadyHere += one.alreadyHere
            result.linkedToCloud += one.linkedToCloud
            result.refused += one.refused
        }
        // A book gone from the folder stays on the shelf (it was copied in); its place just stops travelling.
        current.digests = current.digests.filter { books.stamps[$0.key] != nil }
        current.index = FolderIndex(stamps: books.stamps)
        saved = current
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

    /// The folder's books, by path inside it, with each one's size and date. Read through a file
    /// coordinator, so iCloud Drive lists what it has, downloaded or not.
    nonisolated private static func listBooks(in folder: URL) async -> (stamps: [String: FolderIndex.Stamp], urls: [URL]) {
        await Task.detached(priority: .utility) {
            var stamps: [String: FolderIndex.Stamp] = [:]
            var urls: [URL] = []
            var error: NSError?
            NSFileCoordinator().coordinate(readingItemAt: folder, options: .immediatelyAvailableMetadataOnly, error: &error) { readable in
                let base = readable.standardizedFileURL.path + "/"
                for url in BookFile.books(in: readable) {
                    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .totalFileSizeKey])
                    let path = String(url.standardizedFileURL.path.dropFirst(base.count))
                    stamps[path] = FolderIndex.Stamp(size: Int64(values?.fileSize ?? values?.totalFileSize ?? 0),
                                                     modified: values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
                    urls.append(url)
                }
            }
            return (stamps, urls)
        }.value
    }

    // MARK: Places

    /// A place was kept here for a book: the folder hears of it a moment later, once the turning stops.
    func placeChanged(_ bookID: String) {
        guard saved != nil, let digest = library.book(bookID)?.digest, folderDigests.contains(digest) else { return }
        pendingWrite?.cancel()
        pendingWrite = Task { [weak self] in
            try? await Task.sleep(for: self?.writeDelay ?? .seconds(2))
            guard !Task.isCancelled, let self, var current = self.saved, let folder = self.resolve(&current) else { return }
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            await self.writeOwnPlaces(in: folder)
        }
    }

    /// Takes every newer place another device left in the folder, then writes this device's own.
    private func tradePlaces(in folder: URL) async {
        let others = await Self.readPlaceFiles(in: folder, except: FolderPlaces.fileName(deviceID: deviceID))
        let newest = FolderPlaces.newest(in: others)
        let digests = folderDigests
        for book in library.books where book.isOnDevice && book.id != openBookID() {
            guard let digest = book.digest, digests.contains(digest),
                  let place = FolderPlaces.take(newest[digest], overLocalUpdated: book.lastOpened, localProgression: book.totalProgression)
            else { continue }
            library.takeFolderPlace(bookID: book.id, locatorJSON: place.locator, totalProgression: place.progression, updated: place.updated)
        }
        await writeOwnPlaces(in: folder)
    }

    private func writeOwnPlaces(in folder: URL) async {
        let digests = folderDigests
        var file = FolderPlaceFile(device: deviceName)
        for book in library.books {
            guard let digest = book.digest, digests.contains(digest), let locator = book.locatorJSON, let updated = book.lastOpened else { continue }
            file.record(FolderPlace(locator: locator, progression: book.totalProgression, updated: updated, device: deviceName), for: digest)
        }
        guard !file.places.isEmpty, let data = try? FolderPlaces.encode(file) else { return }
        let target = folder.appending(path: FolderPlaces.directory, directoryHint: .isDirectory).appending(path: FolderPlaces.fileName(deviceID: deviceID))
        await Task.detached(priority: .utility) {
            var error: NSError?
            NSFileCoordinator().coordinate(writingItemAt: target, options: .forReplacing, error: &error) { writable in
                try? FileManager.default.createDirectory(at: writable.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: writable, options: .atomic)
            }
        }.value
    }

    nonisolated private static func readPlaceFiles(in folder: URL, except own: String) async -> [FolderPlaceFile] {
        await Task.detached(priority: .utility) {
            let dir = folder.appending(path: FolderPlaces.directory, directoryHint: .isDirectory)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            var files: [Data] = []
            for name in names where name != own && FolderPlaces.deviceID(fromFileName: name) != nil {
                var error: NSError?
                NSFileCoordinator().coordinate(readingItemAt: dir.appending(path: name), options: [], error: &error) { readable in
                    if let data = try? Data(contentsOf: readable) { files.append(data) }
                }
            }
            return FolderPlaces.decodeAll(files)
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
