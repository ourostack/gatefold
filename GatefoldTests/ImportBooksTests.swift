import Foundation
import GatefoldCore
import Testing
@testable import Gatefold

/// Books from outside the Cloud: Files, Open in and the share sheet, a drop on the shelf. One shelf, no duplicates.
@MainActor @Suite struct ImportBooksTests {
    private func makeStore(signedIn: Bool = false) -> LibraryStore {
        LibraryStore(sync: FakeSyncService(signedIn: signedIn, latency: .zero),
                     root: URL.temporaryDirectory.appending(path: "import-tests-\(UUID().uuidString)"))
    }

    private func scratch() throws -> URL {
        let dir = URL.temporaryDirectory.appending(path: "import-src-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A bundled public-domain book, copied where an import can take it from.
    private func copy(_ resource: String, into dir: URL, as name: String? = nil) throws -> URL {
        let source = try #require(Bundle.main.url(forResource: resource, withExtension: "epub"))
        let target = dir.appending(path: name ?? "\(resource).epub")
        try FileManager.default.copyItem(at: source, to: target)
        return target
    }

    /// The same book unzipped, the way Apple Books keeps it on a Mac (an EPUB folder).
    private func unzipped(_ resource: String, into dir: URL) throws -> URL {
        let zipped = try copy(resource, into: dir, as: "\(resource)-zipped.epub")
        let folder = dir.appending(path: "\(resource).epub", directoryHint: .isDirectory)
        try ZipTestReader.unzip(zipped, to: folder)
        return folder
    }

    @Test func aFileFromFilesComesAboardWithWhereItCameFrom() async throws {
        let store = makeStore()
        let result = await store.importBooks(from: [try copy("frankenstein", into: scratch())], source: .files)
        let book = try #require(result.added.first)
        #expect(result.added.count == 1)
        #expect(book.title.contains("Frankenstein"))
        #expect(book.origin == .imported)
        #expect(book.source == .files)
        #expect(book.digest?.count == 64)
        #expect(book.arrivalLabel == "From Files")
        #expect(store.fileURL(of: book).map { FileManager.default.fileExists(atPath: $0.path) } == true)
    }

    @Test func theSameBookTwiceIsOneBook() async throws {
        let store = makeStore()
        let dir = try scratch()
        _ = await store.importBooks(from: [try copy("emma", into: dir)], source: .files)
        let again = await store.importBooks(from: [try copy("emma", into: dir, as: "Emma (1).epub")], source: .shared)
        #expect(again.added.isEmpty)
        #expect(again.alreadyHere.count == 1)
        #expect(again.single?.title.contains("Emma") == true)
        #expect(store.books.count == 1)
        // The second copy's file didn't stay behind.
        let kept = try FileManager.default.contentsOfDirectory(atPath: store.root.appending(path: "Books").path)
        #expect(kept.count == 1)
    }

    @Test func anEPUBFolderIsZippedAndOpens() async throws {
        let store = makeStore()
        let result = await store.importBooks(from: [try unzipped("alice-in-wonderland", into: scratch())], source: .dropped)
        let book = try #require(result.added.first)
        #expect(book.title.contains("Alice"))
        let url = try #require(store.fileURL(of: book))
        #expect(BookFile.kind(at: url) == .epub)
        let publication = try await BookOpener.shared.open(url)
        #expect(!publication.readingOrder.isEmpty)
        publication.close()
    }

    /// EPUB 2, EPUB 3 and a Kobo `.kepub.epub` (an EPUB with Kobo's spans) all open in the reader as they come in.
    @Test(arguments: [("pride-and-prejudice", "Pride and Prejudice.epub"), ("frankenstein", "Frankenstein.epub"), ("emma", "Emma.kepub.epub")])
    func eachKindOfEPUBOpens(resource: String, name: String) async throws {
        let store = makeStore()
        let result = await store.importBooks(from: [try copy(resource, into: scratch(), as: name)], source: .files)
        let book = try #require(result.added.first)
        let url = try #require(store.fileURL(of: book))
        let publication = try await BookOpener.shared.open(url)
        #expect(!publication.readingOrder.isEmpty)
        publication.close()
    }

    @Test func aFolderOfBooksBringsEachBookInIt() async throws {
        let store = makeStore()
        let dir = try scratch()
        _ = try copy("dracula", into: dir)
        let shelf = dir.appending(path: "More", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: shelf, withIntermediateDirectories: true)
        _ = try copy("emma", into: shelf)
        try Data("%PDF-1.7".utf8).write(to: dir.appending(path: "scan.pdf"))
        let result = await store.importBooks(from: [dir], source: .files)
        #expect(result.added.count == 2)
        #expect(result.refused == 0) // a PDF inside a folder is passed over, not refused
    }

    @Test func aPocketBookBookInTheCloudTakesTheSameFileInsteadOfASecondCopy() async throws {
        let store = makeStore(signedIn: true)
        await store.refresh()
        let cloudCount = store.books.count
        let moby = try #require(store.books.first { $0.title == "Moby-Dick" })
        #expect(!moby.isOnDevice)
        let result = await store.importBooks(from: [try copy("moby-dick", into: scratch())], source: .shared)
        #expect(result.added.isEmpty)
        #expect(result.linkedToCloud == 1)
        #expect(store.books.count == cloudCount)
        let linked = try #require(store.book(moby.id))
        #expect(linked.isOnDevice)
        #expect(linked.cloud != nil) // its place still goes to the e-reader
        #expect(linked.origin == .cloud)
    }

    /// The other way round (the coordinator's App Review path): a book on the shelf from before he signed in, the
    /// Cloud listing the same file once he does. One shelf entry: the Cloud's, so its place goes to and from the
    /// e-reader, with the file and his reading carried over, never the same book twice.
    @Test func aBookFromBeforeSignInIsOneBookWithItsCloudCopy() async throws {
        let sync = FakeSyncService(signedIn: false, latency: .zero)
        let store = LibraryStore(sync: sync, root: URL.temporaryDirectory.appending(path: "import-tests-\(UUID().uuidString)"))
        let local = try #require(await store.importBooks(from: [try copy("frankenstein", into: scratch())], source: .files).added.first)
        let read = Date(timeIntervalSinceNow: -60)
        store.update(local.id) {
            $0.totalProgression = 0.03
            $0.lastOpened = read
            $0.started = read
            $0.sessions = 1
        }
        _ = try await sync.signIn(email: "a@b.c", password: "hunter2", store: FakeSyncService.stores[0])
        await store.refresh()
        let copies = store.books.filter { $0.title.contains("Frankenstein") }
        #expect(copies.count == 1)
        let book = try #require(copies.first)
        #expect(book.cloud != nil) // its place still goes to the e-reader
        #expect(book.origin == .cloud)
        #expect(book.id != local.id)
        #expect(book.isOnDevice)
        #expect(store.fileURL(of: book).map { FileManager.default.fileExists(atPath: $0.path) } == true)
        #expect(book.digest == local.digest)
        #expect(book.totalProgression == 0.03)
        #expect(book.lastOpened == read)
        #expect(book.sessions == 1)
        #expect(book.remote != nil)
        #expect(store.book(local.id) == nil)
        // Its old file didn't stay behind under the old name.
        let kept = try FileManager.default.contentsOfDirectory(atPath: store.root.appending(path: "Books").path)
        #expect(kept == ["\(book.id).epub"])
        // A second refresh changes nothing.
        await store.refresh()
        #expect(store.books.filter { $0.title.contains("Frankenstein") }.count == 1)
    }

    /// The real Cloud's `md5_hash` is often the fast_hash, which no file matches. Then the same size to the byte
    /// and the same title are the same book; a different size is a different edition and stays its own entry.
    @Test func aBookFromBeforeSignInMeetsItsCloudCopyWithoutAChecksum() async throws {
        let store = makeStore()
        let local = try #require(await store.importBooks(from: [try copy("dracula", into: scratch())], source: .files).added.first)
        let url = try #require(store.fileURL(of: local))
        let bytes = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64)
        let fastHashShaped = Data(repeating: 7, count: 32).base64EncodedString()
        let other = CloudBook(fastHash: "other-edition", title: local.title, authors: local.author, bytes: bytes + 1, md5Base64: fastHashShaped)
        await store.merge([other])
        #expect(store.book(local.id) != nil)
        let same = CloudBook(fastHash: "same-file", title: " \(local.title.uppercased()) ", authors: local.author, bytes: bytes, md5Base64: fastHashShaped)
        await store.merge([same])
        #expect(store.book(local.id) == nil)
        let book = try #require(store.book("same-file"))
        #expect(book.isOnDevice && book.cloud != nil && book.origin == .cloud)
        #expect(book.digest == local.digest)
        #expect(store.books.count == 2) // the other edition, and this one
    }

    @Test func aDownloadedPocketBookBookIsSpottedToo() async throws {
        let store = makeStore(signedIn: true)
        await store.refresh()
        let emma = try #require(store.books.first { $0.title == "Emma" })
        await store.download(emma)
        #expect(store.book(emma.id)?.isOnDevice == true)
        let result = await store.importBooks(from: [try copy("emma", into: scratch())], source: .files)
        #expect(result.added.isEmpty)
        #expect(result.alreadyHere.first?.id == emma.id)
    }

    @Test func aPDFIsTurnedAwayKindly() async throws {
        let store = makeStore()
        let pdf = try scratch().appending(path: "Scan.pdf")
        try Data("%PDF-1.7\n".utf8).write(to: pdf)
        let result = await store.importBooks(from: [pdf], source: .shared)
        #expect(result.refused == 1)
        #expect(store.books.isEmpty)
        #expect(store.lastError == "“Scan” didn't come aboard. Gatefold reads EPUB books, and doesn't open PDFs yet.")
    }

    @Test func theTelemetrySaysOnlyCountsAndTheSource() async throws {
        var result = LibraryStore.ImportResult()
        result.added = [LibraryBook(id: "local-1", title: "Frankenstein", author: "Mary Shelley", origin: .imported, added: Date())]
        result.refused = 2
        let p = GatefoldTelemetry.addedProperties(source: .shared, result: result)
        #expect(Set(p.keys) == ["source", "added", "already_here", "linked_to_cloud", "refused"])
        #expect(p["source"] == .string("shared"))
        #expect(p["added"] == .int(1))
        #expect(p["refused"] == .int(2))
        #expect(!p.values.contains { if case let .string(s) = $0 { s.contains("Frankenstein") || s.contains("Shelley") } else { false } })
    }

    @Test func onlyTheCopiesMadeForGatefoldAreDeleted() {
        let inbox = URL.documentsDirectory.appending(path: "Inbox")
        let incoming = URL.temporaryDirectory.appending(path: "Incoming")
        #expect(AppModel.isHandOffCopy(inbox.appending(path: "Emma.epub")))
        #expect(AppModel.isHandOffCopy(incoming.appending(path: "\(UUID().uuidString)/Emma.epub")))
        // The person's own files, and the folders themselves, are never touched.
        #expect(!AppModel.isHandOffCopy(URL.documentsDirectory.appending(path: "InboxOther/Emma.epub")))
        #expect(!AppModel.isHandOffCopy(incoming))
        #expect(!AppModel.isHandOffCopy(URL(filePath: "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Emma.epub")))
    }

    @Test func aBookFromBeforeDigestsIsStillSpotted() async throws {
        let root = URL.temporaryDirectory.appending(path: "import-tests-\(UUID().uuidString)")
        let dir = try scratch()
        let first = LibraryStore(sync: FakeSyncService(signedIn: false, latency: .zero), root: root)
        let book = try #require(await first.importBooks(from: [try copy("emma", into: dir)]).added.first)
        first.update(book.id) { $0.digest = nil } // as a shelf from before Gatefold kept digests
        let relaunched = LibraryStore(sync: FakeSyncService(signedIn: false, latency: .zero), root: root)
        let again = await relaunched.importBooks(from: [try copy("emma", into: dir, as: "Emma again.epub")])
        #expect(again.added.isEmpty)
        #expect(again.alreadyHere.map(\.id) == [book.id])
    }

    @Test func twoImportsAtOnceStillMakeOneBook() async throws {
        let store = makeStore()
        let dir = try scratch()
        let a = try copy("dracula", into: dir), b = try copy("dracula", into: dir, as: "Dracula (1).epub")
        async let first = store.importBooks(from: [a], source: .shared)
        async let second = store.importBooks(from: [b], source: .shared)
        let results = await [first, second]
        #expect(store.books.count == 1)
        #expect(results.map(\.added.count).sorted() == [0, 1])
    }

    @Test func whatTheToastSays() {
        func book(_ id: String, _ title: String) -> LibraryBook {
            LibraryBook(id: id, title: title, author: "Jane Austen", origin: .imported, source: .files, digest: nil, fileName: "\(id).epub", added: Date())
        }
        let one = ArrivalWords(.init(added: [book("e", "Emma")]))
        #expect(one?.message == "“Emma” is on your shelf")
        #expect(one?.bookID == "e")
        let twice = ArrivalWords(.init(alreadyHere: [book("e", "Emma")]))
        #expect(twice?.message == "“Emma” was already on your shelf")
        let several = ArrivalWords(.init(added: [book("a", "A"), book("b", "B")], alreadyHere: [book("c", "C")]))
        #expect(several?.message == "2 books added")
        #expect(several?.description == "1 was already here.")
        #expect(several?.bookID == nil)
        #expect(ArrivalWords(.init()) == nil)
    }

}

/// Unzips a stored-or-deflated EPUB with the system's own archive support, for making EPUB folders in tests.
enum ZipTestReader {
    static func unzip(_ zip: URL, to folder: URL) throws {
        let archive = try Data(contentsOf: zip)
        let bytes = [UInt8](archive)
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        var eocd = bytes.count - 22
        while eocd > 0, u32(eocd) != 0x0605_4B50 { eocd -= 1 }
        var cd = u32(eocd + 16)
        for _ in 0 ..< u16(eocd + 10) {
            let method = u16(cd + 10), packed = u32(cd + 20), size = u32(cd + 24)
            let nameLength = u16(cd + 28), extra = u16(cd + 30), comment = u16(cd + 32), local = u32(cd + 42)
            let name = String(decoding: bytes[(cd + 46) ..< (cd + 46 + nameLength)], as: UTF8.self)
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            let raw = Data(bytes[start ..< (start + packed)])
            let data = method == 0 ? raw : try inflate(raw, size: size)
            let target = folder.appending(path: name)
            if name.hasSuffix("/") {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target)
            }
            cd += 46 + nameLength + extra + comment
        }
    }

    private static func inflate(_ data: Data, size: Int) throws -> Data {
        // ZIP's deflate is raw deflate, which is what Apple's `.zlib` algorithm reads.
        let out = try (data as NSData).decompressed(using: .zlib) as Data
        guard out.count == size else { throw CocoaError(.fileReadCorruptFile) }
        return out
    }
}
