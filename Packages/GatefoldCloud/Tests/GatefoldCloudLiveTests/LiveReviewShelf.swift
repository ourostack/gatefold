#if os(macOS)
import Foundation
import Testing
@testable import GatefoldCloud

/// App Review's demo account: test account 2 (the App Store listing's review details name it, from the
/// `GATEFOLD_REVIEW_DEMO_EMAIL` and `GATEFOLD_REVIEW_DEMO_PASSWORD` secrets). This fills its shelf with the
/// public-domain books that ship in the app and leaves Pride and Prejudice part-read, so a reviewer who signs in
/// sees covers, downloads a book and lands on a saved place. It only adds: a book already there (by MD5) is left
/// alone, and nothing is deleted. Alice is left out, because `uploadsAndDeletesAPublicDomainEPUB` adds and deletes
/// its own copy on this account.
///
/// Run by hand before a submission, never in CI:
///     GATEFOLD_LIVE=1 GATEFOLD_LIVE_REVIEW_SHELF=1 swift test --package-path Packages/GatefoldCloud \
///         --filter LiveReviewShelf
@Suite(.enabled(if: Live.enabled && ProcessInfo.processInfo.environment["GATEFOLD_LIVE_REVIEW_SHELF"] == "1"))
struct LiveReviewShelf {
    static let books = ["frankenstein", "pride-and-prejudice", "moby-dick", "dracula", "sherlock-holmes", "emma"]
    static let partRead = (book: "pride-and-prejudice", at: 0.22)

    static var sampleBooks: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Gatefold/Resources/SampleBooks")
    }

    @Test func fillsTheReviewShelf() async throws {
        let cloud = try await Live.signedIn(2)
        var shelf = try await cloud.library()
        Live.log("review shelf before: \(shelf.count) books")
        for name in Self.books {
            let file = Self.sampleBooks.appending(path: "\(name).epub")
            let md5 = try PocketBookCloud.md5Base64(of: file)
            if shelf.contains(where: { $0.md5Base64 == md5 }) { continue }
            let uploaded = try await cloud.upload(fileAt: file)
            Live.log("uploaded \(name): fast_hash=\(uploaded.fastHash)")
        }
        shelf = try await cloud.library()
        for name in Self.books {
            let md5 = try PocketBookCloud.md5Base64(of: Self.sampleBooks.appending(path: "\(name).epub"))
            #expect(shelf.contains { $0.md5Base64 == md5 }, "\(name) is on the review shelf")
        }

        let md5 = try PocketBookCloud.md5Base64(of: Self.sampleBooks.appending(path: "\(Self.partRead.book).epub"))
        let book = try #require(shelf.first { $0.md5Base64 == md5 })
        let at = Self.partRead.at
        await cloud.push(ReadingPosition(cfi: nil, progression: at, totalProgression: at, updated: Date()), for: book)
        await cloud.flushOutbox()
        #expect(await cloud.pendingChanges() == 0)
        Live.log("review shelf after: \(shelf.count) books; \(Self.partRead.book) at \(Int(at * 100))%")
    }
}
#endif
