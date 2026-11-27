#if os(macOS)
import Foundation
import Testing
@testable import GatefoldCloud

/// App Review's demo account: test account 2 (the App Store listing's review details name it, from the
/// `GATEFOLD_REVIEW_DEMO_EMAIL` and `GATEFOLD_REVIEW_DEMO_PASSWORD` secrets). This fills its shelf with the
/// public-domain books that ship in the app and leaves Pride and Prejudice about a fifth read, so a reviewer who signs in
/// sees covers, downloads a book and lands on a saved place. It adds only what is missing, and deletes nothing
/// but the five probe copies named in `probes`. Alice is left out, because `uploadsAndDeletesAPublicDomainEPUB` adds and deletes
/// its own copy on this account.
///
/// Run by hand before a submission, never in CI:
///     GATEFOLD_LIVE=1 GATEFOLD_LIVE_REVIEW_SHELF=1 swift test --package-path Packages/GatefoldCloud \
///         --filter LiveReviewShelf
@Suite(.enabled(if: Live.enabled && ProcessInfo.processInfo.environment["GATEFOLD_LIVE_REVIEW_SHELF"] == "1"))
struct LiveReviewShelf {
    /// The app's own sample shelf (LibraryStore.sampleShelf) less Alice, so a reviewer sees the same classics with or
    /// without the account. The Great Gatsby ships too, but only for the fake Cloud's screenshot shelf.
    static let books = ["frankenstein", "pride-and-prejudice", "moby-dick", "dracula", "sherlock-holmes", "emma"]
    static let partRead = (book: "pride-and-prejudice", at: 0.22)

    static var sampleBooks: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Gatefold/Resources/SampleBooks")
    }

    /// Dracula under five odd file names, left on this account by the file-name download probe of 2026-11-13. A
    /// reviewer would see six Draculas.
    static let probes = ["Plain-Name---Probe.epub", "Café-Ñoño-–-en-dash.epub", "Hash.epub",
                         "Colon:-subtitle;-semi---amps-(paren).epub", "Questions.epub"]

    @Test func fillsTheReviewShelf() async throws {
        let cloud = try await Live.signedIn(2)
        var shelf = try await cloud.library()
        Live.log("review shelf before: \(shelf.count) books")
        for probe in shelf where Self.probes.contains(probe.name) {
            try await cloud.delete(probe)
            Live.log("deleted a probe copy: fast_hash=\(probe.fastHash)")
        }
        // The Cloud names a book by its fast hash and refuses a second copy (409, the hash in its message): either
        // way, the hash finds the book. The library doesn't report MD5s, so a rerun goes through the 409.
        var onShelf: [String: String] = [:]
        for name in Self.books {
            do {
                let uploaded = try await cloud.upload(fileAt: Self.sampleBooks.appending(path: "\(name).epub"))
                onShelf[name] = uploaded.fastHash
                Live.log("uploaded \(name): fast_hash=\(uploaded.fastHash)")
            } catch CloudError.http(status: 409, let message) {
                let hash = try #require(message?.firstMatch(of: /[0-9a-f]{32}/).map { String($0.output) },
                                        "a 409 names the fast hash it already has")
                onShelf[name] = hash
            }
        }
        shelf = try await cloud.library()
        for name in Self.books {
            let hash = try #require(onShelf[name])
            #expect(shelf.contains { $0.fastHash == hash }, "\(name) is on the review shelf")
        }
        #expect(!shelf.contains { Self.probes.contains($0.name) })

        let hash = try #require(onShelf[Self.partRead.book])
        let book = try #require(shelf.first { $0.fastHash == hash })
        // The Cloud refuses a percent with no CFI on a book nobody has read yet (422, "no reading position"), so the
        // place is a real CFI: the start of the spine item nearest the part-read share of the book.
        let mapper = try Live.mapper(forEPUB: Self.sampleBooks.appending(path: "\(Self.partRead.book).epub"))
        let items = mapper.spine.items
        let index = min(items.count - 1, Int((Double(items.count) * Self.partRead.at).rounded()))
        let at = Double(index) / Double(items.count)
        let location = BookLocation(href: items[index].href, progression: 0, totalProgression: at)
        let position = try #require(await mapper.position(for: location, at: Date()))
        await cloud.push(position, for: book)
        await cloud.flushOutbox()
        #expect(await cloud.pendingChanges() == 0)
        // The outbox drops a write the Cloud refuses, so an empty outbox proves nothing: read the place back.
        let back = try #require(try await cloud.remotePosition(for: book), "the Cloud holds the part-read place")
        #expect(back.cfi == position.cfi)
        Live.log("review shelf after: \(shelf.count) books; \(Self.partRead.book) at \(Int((back.totalProgression * 100).rounded()))%")
    }
}
#endif
