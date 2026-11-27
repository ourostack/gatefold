import Foundation
import Testing
@testable import Gatefold

/// One action finishes what it was for (Ari, 2026-11-27): one book chosen in Files, opened in Gatefold from another
/// app or dropped on the shelf opens, through the same open a Cloud book takes as it lands (`openRequest`). Several
/// land on the shelf with a note that offers Read, and so does a folder, even one holding a single book.
@MainActor @Suite(.serialized) struct OneBookOpensTests {
    /// Receiving a book marks the welcome done and an open book is remembered for the next launch: both are put back.
    private let remembered = ["onboarded", "reopenBook"].map { ($0, UserDefaults.standard.object(forKey: $0)) }

    private func app() throws -> AppModel {
        let app = AppModel(sync: StubSync(), libraryRoot: URL.temporaryDirectory.appending(path: "one-opens-\(UUID().uuidString)"))
        try #require(app.openBookID == nil, "a book was left open by another test")
        return app
    }

    private func restoreDefaults() {
        for (key, value) in remembered { UserDefaults.standard.set(value, forKey: key) }
    }

    private func copy(_ resources: [String]) throws -> [URL] {
        let dir = URL.temporaryDirectory.appending(path: "one-opens-src-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try resources.map { resource in
            let source = try #require(Bundle.main.url(forResource: resource, withExtension: "epub"))
            let target = dir.appending(path: "\(resource).epub")
            try FileManager.default.copyItem(at: source, to: target)
            return target
        }
    }

    @Test(arguments: [LibraryBook.Source.files, .shared, .dropped])
    func oneBookOpens(from source: LibraryBook.Source) async throws {
        defer { restoreDefaults() }
        let app = try app()
        await app.receive(try copy(["emma"]), source: source)
        let book = try #require(app.library.books.first)
        #expect(app.library.openRequest == book.id, "one book came in and wasn't opened")
        #expect(app.handedOver?.bookID == book.id, "the shelf can't tell a book handed over from a Cloud book landing")
        #expect(app.lastArrival == nil, "a note offering Read was left under the open book")
    }

    @Test func aHandedOverBookThatCantOpenGetsItsNote() async throws {
        defer { restoreDefaults() }
        let app = try app()
        await app.receive(try copy(["emma"]), source: .shared)
        app.handOffDone(opened: false)
        #expect(app.handedOver == nil)
        #expect(app.lastArrival?.result.single?.title.contains("Emma") == true, "the book came in with nothing said")
    }

    @Test func aHandedOverBookThatOpensNeedsNoNote() async throws {
        defer { restoreDefaults() }
        let app = try app()
        await app.receive(try copy(["emma"]), source: .shared)
        app.handOffDone(opened: true)
        #expect(app.handedOver == nil)
        #expect(app.lastArrival == nil)
    }

    @Test func oneBookAlreadyOnTheShelfOpensToo() async throws {
        defer { restoreDefaults() }
        let app = try app()
        await app.receive(try copy(["emma"]), source: .files)
        app.library.openRequest = nil
        app.handOffDone(opened: true)
        await app.receive(try copy(["emma"]), source: .shared)
        #expect(app.library.books.count == 1)
        #expect(app.library.openRequest == app.library.books.first?.id)
    }

    @Test func severalBooksLandOnTheShelf() async throws {
        defer { restoreDefaults() }
        let app = try app()
        await app.receive(try copy(["emma", "frankenstein"]), source: .files)
        #expect(app.library.books.count == 2)
        #expect(app.library.openRequest == nil)
        #expect(app.lastArrival?.result.added.count == 2)
    }

    @Test func aFolderOfBooksLandsOnTheShelf() async throws {
        defer { restoreDefaults() }
        let app = try app()
        let folder = try #require(try copy(["emma", "frankenstein"]).first?.deletingLastPathComponent())
        await app.receive([folder], source: .files)
        #expect(app.library.books.count == 2)
        #expect(app.library.openRequest == nil)
    }

    /// A catalog's Get offers Read on the catalog's own page, over which the reader can't come up: the book stays on the shelf.
    @Test func aBookFromACatalogStaysOnTheShelf() async throws {
        defer { restoreDefaults() }
        let app = try app()
        let result = await app.receive(try copy(["emma"]), source: .catalog)
        #expect(result.single != nil)
        #expect(app.library.openRequest == nil, "a catalog's Get opened the book under the catalog")
        #expect(app.handedOver == nil)
    }

    /// A folder is several books asked for, even when it holds only one: it lands on the shelf with its note.
    @Test func aFolderHoldingOneBookLandsOnTheShelf() async throws {
        defer { restoreDefaults() }
        let app = try app()
        let folder = try #require(try copy(["emma"]).first?.deletingLastPathComponent())
        await app.receive([folder], source: .files)
        #expect(app.library.books.count == 1)
        #expect(app.library.openRequest == nil, "a folder chosen to fill the shelf opened its one book")
        #expect(app.lastArrival?.result.added.count == 1)
    }

    /// A book handed over while another is open opens in its place: the shelf is told it's a hand-off and replaces the reader.
    @Test func oneBookThatArrivesWhileAnotherIsOpenStillOpens() async throws {
        defer { restoreDefaults() }
        let app = try app()
        app.openBookID = "gutenberg-dracula"
        restoreDefaults()
        defer { app.openBookID = nil; restoreDefaults() }
        await app.receive(try copy(["emma"]), source: .shared)
        let book = try #require(app.library.books.first)
        #expect(app.library.openRequest == book.id, "Open in did nothing because a book was open")
        #expect(app.handedOver?.bookID == book.id)
    }

    /// Another app sharing several files hands them over one by one: a second before the shelf took the first makes
    /// them several, and they land together with one note.
    @Test func twoBooksHandedOverTogetherLandWithANote() async throws {
        defer { restoreDefaults() }
        let app = try app()
        let files = try copy(["emma", "frankenstein"])
        await app.receive([files[0]], source: .shared)
        await app.receive([files[1]], source: .shared)
        #expect(app.handedOver == nil, "the second book was opened over the first")
        #expect(app.library.openRequest == nil)
        #expect(app.lastArrival?.result.added.count == 2, "a book handed over went onto the shelf with nothing said")
    }

    /// The same book handed over twice before the shelf took it up (Open in tapped twice) is still one book: it opens.
    @Test func theSameBookHandedOverTwiceStillOpens() async throws {
        defer { restoreDefaults() }
        let app = try app()
        await app.receive(try copy(["emma"]), source: .shared)
        let emma = try #require(app.handedOver?.bookID)
        await app.receive(try copy(["emma"]), source: .shared)
        #expect(app.handedOver?.bookID == emma, "a second Open in of the same book turned it into a note")
        #expect(app.library.openRequest == emma)
        #expect(app.lastArrival == nil)
    }

    /// Several files shared from another app at once come as several `onOpenURL` calls in one turn: one arrival.
    @Test func severalFilesSharedAtOnceLandOnTheShelf() async throws {
        defer { restoreDefaults() }
        let app = try app()
        let files = try copy(["emma", "frankenstein"])
        for file in files { app.handOver(file) }
        var opened = 0
        for _ in 0..<400 where app.lastArrival == nil {
            // The shelf takes up a hand-off as soon as it sees one.
            if app.handedOver != nil { opened += 1; app.handOffDone(opened: true) }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(opened == 0, "one of several shared files was opened")
        #expect(app.lastArrival?.result.added.count == 2)
    }

    @Test func oneFileSharedOpens() async throws {
        defer { restoreDefaults() }
        let app = try app()
        app.handOver(try copy(["emma"])[0])
        for _ in 0..<200 where app.handedOver == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(app.handedOver != nil)
        #expect(app.library.openRequest == app.handedOver?.bookID)
    }

    /// A Cloud book landing in the same moment doesn't swallow the hand-off: the book handed over is the one asked for.
    @Test func aHandOffWinsOverACloudBookLandingAtOnce() async throws {
        defer { restoreDefaults() }
        let app = try app()
        await app.receive(try copy(["emma"]), source: .shared)
        let emma = try #require(app.handedOver?.bookID)
        #expect(app.asked("cloud-book") == AppModel.Asked(id: emma, handOff: true))
        app.handOffDone(opened: true)
        #expect(app.asked("cloud-book") == AppModel.Asked(id: "cloud-book", handOff: false))
    }

    // What the shelf does when asked to open a book: a Cloud book landing keeps #639's rule (only onto a bare shelf),
    // a book handed over always ends open or with its note.

    @Test func aHandOffOntoTheShelfOpens() {
        #expect(AppModel.openStep(id: "a", handOff: true, known: true, opening: false, reading: nil, sheetUp: false) == .open)
    }

    @Test func aHandOffWhileReadingReplacesTheBook() {
        #expect(AppModel.openStep(id: "a", handOff: true, known: true, opening: false, reading: "b", sheetUp: true) == .replace)
    }

    @Test func aHandOffOfTheBookBeingReadKeepsIt() {
        #expect(AppModel.openStep(id: "a", handOff: true, known: true, opening: false, reading: "a", sheetUp: true) == .keep)
    }

    @Test func aHandOffWhileABookOpensWaitsForIt() {
        #expect(AppModel.openStep(id: "a", handOff: true, known: true, opening: true, reading: nil, sheetUp: false) == .wait)
    }

    @Test func aHandOffUnderASheetGetsItsNote() {
        #expect(AppModel.openStep(id: "a", handOff: true, known: true, opening: false, reading: nil, sheetUp: true) == .note)
        #expect(AppModel.openStep(id: "a", handOff: true, known: false, opening: false, reading: nil, sheetUp: false) == .note)
    }

    @Test func aCloudBookLandingOpensOnlyOntoAQuietShelf() {
        #expect(AppModel.openStep(id: "a", handOff: false, known: true, opening: false, reading: nil, sheetUp: false) == .open)
        #expect(AppModel.openStep(id: "a", handOff: false, known: true, opening: false, reading: "b", sheetUp: false) == .skip)
        #expect(AppModel.openStep(id: "a", handOff: false, known: true, opening: true, reading: nil, sheetUp: false) == .skip)
        #expect(AppModel.openStep(id: "a", handOff: false, known: false, opening: false, reading: nil, sheetUp: false) == .skip)
    }
}
