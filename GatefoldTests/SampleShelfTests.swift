import Foundation
import Testing
@testable import Gatefold

/// A reader without a PocketBook account, App Review's included, gets a real shelf in one tap: public-domain books
/// that ship in the app (Guidelines 2.1 and 4.2: the app does its job before any sign-in).
@MainActor @Suite struct SampleShelfTests {
    private func makeStore() -> LibraryStore {
        LibraryStore(sync: FakeSyncService(signedIn: false, latency: .zero),
                     root: URL.temporaryDirectory.appending(path: "sample-shelf-\(UUID().uuidString)"))
    }

    @Test func everySampleBookShipsInTheApp() {
        #expect(LibraryStore.sampleShelf.count == 7)
        for resource in LibraryStore.sampleShelf {
            #expect(Bundle.main.url(forResource: resource, withExtension: "epub") != nil, "\(resource).epub")
        }
    }

    @Test func itFillsAnEmptyShelfWithoutAnAccount() async {
        let store = makeStore()
        #expect(store.books.isEmpty)
        let added = await store.addSampleShelf(telemetry: nil).added
        #expect(added.count == LibraryStore.sampleShelf.count)
        #expect(store.books.count == LibraryStore.sampleShelf.count)
        #expect(store.lastError == nil)
        for book in store.books {
            #expect(book.origin == .imported)
            #expect(book.source == .sample)
            #expect(book.id.hasPrefix("sample-"))
            #expect(store.state(of: book) == .onDevice, "\(book.title) opens with no download")
        }
        #expect(store.books.contains { $0.title.contains("Frankenstein") })
    }

    @Test func addingItTwiceAddsNothingNew() async {
        let store = makeStore()
        await store.addSampleShelf(telemetry: nil)
        let again = await store.addSampleShelf(telemetry: nil).added
        #expect(again.isEmpty)
        #expect(store.books.count == LibraryStore.sampleShelf.count)
    }

    @Test func aSampleBookRemovedComesBackOnTheNextTap() async throws {
        let store = makeStore()
        await store.addSampleShelf(telemetry: nil)
        store.remove(try #require(store.books.first))
        let again = await store.addSampleShelf(telemetry: nil).added
        #expect(again.count == 1)
        #expect(store.books.count == LibraryStore.sampleShelf.count)
    }

    /// The shelf lists newest first, so the classics go on in reverse: Frankenstein, the one the review notes open,
    /// comes first.
    @Test func frankensteinLeadsTheShelf() async {
        let store = makeStore()
        await store.addSampleShelf(telemetry: nil)
        #expect(store.allBooks.map(\.id) == LibraryStore.sampleShelf.map { "sample-\($0)" })
    }

    /// Two windows on an iPad can tap at once: each book goes on once, and neither call deletes the other's file.
    @Test func twoTapsAtOnceAddEachBookOnce() async {
        let store = makeStore()
        async let first = store.addSampleShelf(telemetry: nil).added
        async let second = store.addSampleShelf(telemetry: nil).added
        let added = await first.count + second.count
        #expect(added == LibraryStore.sampleShelf.count)
        #expect(store.books.count == LibraryStore.sampleShelf.count)
        #expect(store.lastError == nil)
        for book in store.books {
            #expect(store.state(of: book) == .onDevice, "\(book.title) still has its file")
        }
    }

    /// A file left behind by an import that never finished (the app was killed mid-copy) doesn't block the book.
    @Test func aLeftoverFileDoesNotBlockItsBook() async throws {
        let root = URL.temporaryDirectory.appending(path: "sample-shelf-\(UUID().uuidString)")
        let books = root.appending(path: "Books", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: books, withIntermediateDirectories: true)
        try Data("half a book".utf8).write(to: books.appending(path: "sample-frankenstein.epub"))
        let store = LibraryStore(sync: FakeSyncService(signedIn: false, latency: .zero), root: root)
        let added = await store.addSampleShelf(telemetry: nil).added
        #expect(added.count == LibraryStore.sampleShelf.count)
        #expect(store.lastError == nil)
    }
}
