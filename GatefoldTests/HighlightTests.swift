import Foundation
import GatefoldCloud
import GatefoldCore
import ReadiumShared
import Testing
@testable import Gatefold

/// A Cloud that answers with whatever list the test sets, however stale, and records writes.
actor ListSync: SyncService {
    var list: [CloudAnnotation] = []
    private(set) var saved: [CloudAnnotation] = []
    private(set) var deleted: [CloudAnnotation] = []
    func setList(_ new: [CloudAnnotation]) { list = new }

    var account: CloudAccount? { CloudAccount(email: "reader@example.com", store: FakeSyncService.stores[0]) }
    func stores(forEmail email: String) async throws -> [CloudStore] { FakeSyncService.stores }
    func signIn(email: String, password: String, store: CloudStore) async throws -> CloudAccount { await account! }
    func signOut() async {}
    func cachedLibrary() async -> [CloudBook] { [] }
    func library() async throws -> [CloudBook] { [] }
    func download(_ book: CloudBook) async throws -> URL { throw CloudError.notFound }
    func upload(fileAt url: URL) async throws -> CloudBook { throw CloudError.notFound }
    func delete(_ book: CloudBook) async throws {}
    func remotePosition(for book: CloudBook) async throws -> ReadingPosition? { nil }
    func push(_ position: ReadingPosition, for book: CloudBook) async {}
    func markRead(_ book: CloudBook) async {}
    func annotations(for book: CloudBook) async throws -> [CloudAnnotation] { list }
    func save(_ annotation: CloudAnnotation, for book: CloudBook) async { saved.append(annotation) }
    func deleteAnnotation(_ annotation: CloudAnnotation, for book: CloudBook) async { deleted.append(annotation) }
    func pendingChanges() async -> Int { 0 }
    func flushOutbox() async {}
    nonisolated func changes() -> AsyncStream<CloudChange> { AsyncStream { _ in } }
}

/// Highlights and notes: the fake InkPad's seeds, drawing them, making and removing your own.
@MainActor @Suite(.serialized) struct HighlightTests {
    static let book = FakeSyncService.highlightedBook

    static func publication() async throws -> Publication {
        let url = try #require(Bundle.main.url(forResource: "pride-and-prejudice", withExtension: "epub"))
        return try await BookOpener.shared.open(url)
    }

    static func mapper(_ publication: Publication) async throws -> PositionMapper {
        nonisolated(unsafe) let p = publication
        return try #require(await BookPositions.mapper(for: p))
    }

    /// A reader on Pride and Prejudice over `sync`, its highlights loaded.
    static func reader(_ sync: any SyncService) async throws -> (ReaderModel, PositionMapper, Publication) {
        let app = AppModel(sync: sync, libraryRoot: URL.temporaryDirectory.appending(path: "highlights-\(UUID().uuidString)"))
        let cloud = CloudBook(fastHash: book, name: "pride-and-prejudice.epub", title: "Pride and Prejudice")
        await app.library.merge([cloud])
        let entry = try #require(app.library.book(book))
        let publication = try await publication()
        let mapper = try await mapper(publication)
        nonisolated(unsafe) let p = publication
        let start = try #require(await p.locate(progression: 0))
        let model = ReaderModel(book: entry, publication: publication, app: app, page: ScriptedPage(at: start))
        await model.highlights.start(model: model, mapper: mapper)
        return (model, mapper, publication)
    }

    /// What Readium reports for selecting a sentence in Chapter I.
    static func selection(_ publication: Publication, _ words: String, before: String, after: String) throws -> Locator {
        let link = publication.readingOrder[1]
        return Locator(href: link.url(), mediaType: .xhtml, locations: .init(progression: 0.9),
                       text: .init(after: after, before: before, highlight: words))
    }

    @Test func theFakeInkPadsAnchorsNameTheirWordsExactly() async throws {
        let mapper = try await Self.mapper(try await Self.publication())
        let seeds = try #require(FakeSyncService.seededAnnotations(now: Date())[Self.book])
        #expect(seeds.count == 2)
        for seed in seeds {
            let range = try #require(await mapper.range(for: seed))
            let quotation = try #require(seed.quotation?.value)
            #expect(range.displayText == quotation.text)
            // Found by its CFIs, not by searching for the words.
            #expect(range.begin.description == EPUBCFI(quotation.begin)?.description)
            #expect(range.end.description == EPUBCFI(quotation.end)?.description)
            #expect(seed.anchorStyle == .device)
        }
    }

    @Test func theInkPadsHighlightsArePlacedInReadingOrderWithTheirStory() async throws {
        let (model, _, _) = try await Self.reader(FakeSyncService(signedIn: true, latency: .zero))
        let items = model.highlights.items
        #expect(items.map(\.quote) == [
            "a truth universally acknowledged, that a single man in possession of a good fortune must be in want of a wife.",
            "Netherfield Park is let at last?",
        ])
        #expect(items.allSatisfy { $0.origin == .inkPad })
        #expect(items[0].note == nil)
        #expect(items[1].note?.hasPrefix("And so it begins.") == true)
        #expect(items[0].totalProgression > 0 && items[0].totalProgression < 0.1)
        #expect(items[0].locator.text.highlight?.contains("universally acknowledged") == true)
        let now = Date()
        #expect(items[0].provenance(now: now).hasPrefix("Highlighted on your e-reader · "))
        // Seeded 72 hours back: "3 days ago" by the calendar, or "2 days ago" late in the evening after
        // the clocks go back, when 72 hours reach only into the day before yesterday.
        #expect(["2 days ago", "3 days ago"].contains { items[0].provenance(now: now).hasSuffix($0) })
        #expect(items[1].provenance(now: now).hasPrefix("Noted on your e-reader · "))
    }

    @Test func aSelectionBecomesAHighlightTheCloudKeeps() async throws {
        let fake = FakeSyncService(signedIn: true, latency: .zero)
        let (model, _, publication) = try await Self.reader(fake)
        let cloudBook = CloudBook(fastHash: Self.book)
        let store = model.highlights
        let saved = store.savedCount
        await store.add(try Self.selection(publication, "Mr. Bennet made no answer.", before: "told me all about it.”\n\n", after: "\n\n“Do not you want"))
        #expect(store.items.count == 3)
        let mine = try #require(store.items.last)
        #expect(mine.quote == "Mr. Bennet made no answer.")
        #expect(mine.origin == .here)
        #expect(mine.provenance() == "Highlighted here · just now")
        #expect(store.savedCount == saved + 1)

        var cloud = try await fake.annotations(for: cloudBook)
        let written = try #require(cloud.first { $0.quotation?.value.text == "Mr. Bennet made no answer." })
        #expect(written.uuid != nil)
        #expect(written.quotation?.value.begin.hasPrefix("#epubcfi(/6/4[pg-header]!") == true)
        #expect(written.kind.value == .highlight)

        await store.setNote("He rarely does.", for: mine.id)
        cloud = try await fake.annotations(for: cloudBook)
        #expect(cloud.first { $0.uuid == written.uuid }?.kind.value == .note)
        #expect(cloud.first { $0.uuid == written.uuid }?.noteText == "He rarely does.")
        #expect(store.items.last?.provenance().hasPrefix("Noted here") == true)

        await store.remove(mine.id)
        #expect(store.items.count == 2)
        #expect(try await fake.annotations(for: cloudBook).count == 2)
    }

    @Test func aNoteOnAFreshSelectionIsANote() async throws {
        let fake = FakeSyncService(signedIn: true, latency: .zero)
        let (model, _, publication) = try await Self.reader(fake)
        let draft = NoteDraft(quote: "Mr. Bennet replied that he had not.", text: "Classic.",
                              target: .selection(try Self.selection(publication, "Mr. Bennet replied that he had not.", before: "let at last?", after: "")))
        await model.highlights.saveDraft(draft)
        let note = try #require(model.highlights.items.first { $0.quote == "Mr. Bennet replied that he had not." })
        #expect(note.note == "Classic.")
        #expect(try await fake.annotations(for: CloudBook(fastHash: Self.book)).contains { $0.kind.value == .note && $0.noteText == "Classic." })
    }

    /// A listing fetched before a write lands must not undo what the reader just did.
    @Test func aStaleListingNeitherDropsANewHighlightNorRevivesARemovedOne() async throws {
        let sync = ListSync()
        let seeds = try #require(FakeSyncService.seededAnnotations(now: Date())[Self.book])
        await sync.setList(seeds)
        let (model, _, publication) = try await Self.reader(sync)
        let store = model.highlights
        #expect(store.items.count == 2)

        await store.add(try Self.selection(publication, "Mr. Bennet made no answer.", before: "", after: ""))
        await store.remove(store.items[0].id)
        await store.refresh() // the Cloud hasn't caught up with either
        #expect(store.items.map(\.quote) == ["Netherfield Park is let at last?", "Mr. Bennet made no answer."])
        #expect(await sync.saved.count == 1)
        #expect(await sync.deleted.count == 1)

        // Now it has: the removed one is gone there, the new one is there.
        await sync.setList([seeds[1], await sync.saved[0]])
        await store.refresh()
        #expect(store.items.count == 2)
        // And a later removal elsewhere (the InkPad deleting the note) is honoured.
        await sync.setList([await sync.saved[0]])
        await store.refresh()
        #expect(store.items.map(\.quote) == ["Mr. Bennet made no answer."])
    }

    @Test func theTintSuitsEveryTheme() {
        for theme in ReaderTheme.allCases {
            let look = HighlightLook(color: .yellow, theme: theme, hasNote: true)
            #expect(look.blend == (theme.palette.isDark ? "screen" : "multiply"), "\(theme)")
            #expect(look.mark == ThemePalette.hexString(theme.palette.accent))
        }
        #expect(HighlightLook(color: .cyan, theme: .vellum, hasNote: false).fill != HighlightLook(color: .yellow, theme: .vellum, hasNote: false).fill)
    }

    @Test func aNoteIsAWarmWashWhateverItsColour() {
        for theme in ReaderTheme.allCases {
            let notes = Set([AnnotationColor.cyan, .blue, .yellow, .green, .red].map { HighlightLook(color: $0, theme: theme, hasNote: true).fill })
            #expect(notes.count == 1, "\(theme): a note's wash depends on its colour")
            let fill = notes.first ?? ""
            let rgb = UInt32(fill.dropFirst(), radix: 16) ?? 0
            let r = (rgb >> 16) & 0xFF, b = rgb & 0xFF
            #expect(r > b + 40, "\(theme): \(fill) is not warm")
        }
    }
}
