import Foundation
import GatefoldCore
import ReadiumShared
import Testing
@testable import Gatefold

/// gatefold#201 (runs 42946596192, 42981905510): Readium's first report, of the book's start, arrived
/// before a test's launch jump and read the words on screen, which waits for the web view to load. The
/// jump went out meanwhile and landed; the start's report then resumed and was written as the jump's
/// move, and the jump's own report found that move kept. The only place written was the book's start,
/// so every reopen opened on the cover. Judged by page identity: file and progression in it.
@MainActor @Suite(.serialized) struct LaunchJumpStaleReportTests {
    @Test func aReportFromBeforeTheLaunchJumpNeverTakesItsPlace() async throws {
        let publication = try await ReaderSyncTests.publication()
        // A launch place well inside its file, so its file's first page is a different page.
        var goTo = 0.0
        var target: Locator?
        for candidate in [0.31, 0.33, 0.47, 0.6, 0.72] {
            if let found = await ReaderSyncTests.locate(publication, candidate), (found.locations.progression ?? 0) > 0.2 {
                goTo = candidate
                target = found
                break
            }
        }
        let place = try #require(target, "no launch place well inside its file")

        let sync = StubSync()
        await sync.setLibrary(.success([ReaderSyncTests.frankenstein]))
        await sync.setRemote(nil)
        let app = AppModel(sync: sync, libraryRoot: URL.temporaryDirectory.appending(path: "launch-jump-stale-\(UUID().uuidString)"))
        await app.library.refresh()
        let book = try #require(app.library.book(ReaderSyncTests.frankenstein.fastHash))
        let opening = Locator(href: try #require(AnyURL(string: publication.readingOrder[0].url().string)), mediaType: .xhtml,
                              locations: .init(progression: 0, totalProgression: 0))
        // A page is a twentieth of the file; reading words waits until the web view has loaded.
        let page = ColdLaunchPage(at: opening, span: 0.05, loadsAtRead: 4)
        let model = ReaderModel(book: book, publication: publication, app: app, page: page, goTo: goTo)
        page.model = model

        // Readium's first report, of the book's start, reaches the model while the book is still opening.
        let early = Task { await model.locationDidChange(opening) }
        await model.load()
        await early.value
        for _ in 0..<400 where page.reportsDone < page.reportsSent { try await Task.sleep(for: .milliseconds(10)) }
        #expect(page.reportsDone == page.reportsSent, "Readium's reports never finished")
        try await Task.sleep(for: .milliseconds(300))
        let landed = try #require(page.landedPage, "the launch jump never loaded its page")
        #expect(landed.href.string == place.href.string)
        #expect((landed.locations.progression ?? 0) > 0, "the landed page is its file's first page; the test proves nothing")

        let saved = try #require(app.library.book(ReaderSyncTests.frankenstein.fastHash)?.locatorJSON.flatMap { try? Locator(jsonString: $0) },
                                 "the launch jump kept no place")
        #expect(saved.href.string == landed.href.string && saved.locations.progression == landed.locations.progression,
                "kept \(saved.href.string == opening.href.string ? "the book's start" : saved.href.string) @\(saved.locations.progression ?? -1), not the landed page @\(landed.locations.progression ?? -1)")
        model.close()
    }
}
