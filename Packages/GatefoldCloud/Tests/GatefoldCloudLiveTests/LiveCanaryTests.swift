#if os(macOS)
import Foundation
import Testing
@testable import GatefoldCloud

/// The cloud canary (gatefold#372): the basics Gatefold needs from PocketBook Cloud, checked against
/// test account 1 with exactly one sign-in, because the cloud rate-limits logins per account.
/// Off unless `GATEFOLD_LIVE_CANARY=1`; `.github/workflows/cloud-canary.yml` runs it every 6 hours.
/// Each step logs a `CANARY <step> ok|FAILED` line the workflow quotes in the cloud-drift issue.
@Suite("Cloud canary", .enabled(if: ProcessInfo.processInfo.environment["GATEFOLD_LIVE_CANARY"] == "1"))
struct LiveCanaryTests {
    @Test func theBasicsStillWork() async throws {
        let account = try Live.account(1)
        let cloud = Live.cloud()

        // 1. Sign-in: store lookup plus password grant, with the app's own retries.
        let store = try #require(try await step("sign-in: store lookup") {
            try await cloud.stores(forEmail: account.email).first { $0.usesPassword }
        })
        _ = try await step("sign-in: password grant") {
            try await cloud.signIn(email: account.email, password: account.password, store: store)
        }

        // 2. The library lists, and a download matches the listed size (and the MD5 when it is one).
        let books = try await step("library") { try await cloud.library() }
        let book = try #require(books.first { $0.fastHash == Live.frankenstein }, "test account 1 holds Frankenstein")
        Live.log("library: \(books.count) books; md5 field is an MD5: \(book.verifiableMD5 != nil)")
        let file = try await step("download") { try await cloud.download(book) }
        let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
        check("download: size matches the listing", size?.int64Value == book.bytes,
              "listed \(book.bytes) bytes, got \(size?.int64Value ?? -1)")
        if let md5 = book.verifiableMD5 {
            check("download: MD5 matches the listing", try PocketBookCloud.md5Base64(of: file) == md5, "listed md5 does not match the file")
        }

        // 3. The e-reader's place comes back, and resolves in the book.
        let position = try await step("position read") { try await cloud.remotePosition(for: book) }
        check("position read: a place is there", position?.cfi != nil, "no position, or one without a pointer")
        if let position {
            let location = await (try Live.mapper(forEPUB: file)).location(for: position)
            check("position read: the place resolves in the book", location != nil, "pointer \(position.pointer ?? "nil") does not resolve")
        }

        // 4. A position write. Known to fail since November 2026 (gatefold#371: 422 "position: File not
        //    found." for records from before PocketBook's change). When it starts working, this known
        //    issue goes missing and the canary says so, so we can drop the app's refused-place notice.
        let written = ReadingPosition(cfi: position?.cfi, progression: position?.progression ?? 0.05,
                                      totalProgression: position?.totalProgression ?? 0.05, updated: Date())
        await cloud.push(written, for: book)
        await cloud.flushOutbox()
        let back = try? await cloud.remotePosition(for: book)
        let landed = back.map { abs($0.updated.timeIntervalSince(written.updated)) < 5 } ?? false
        withKnownIssue("gatefold#371: the cloud refuses position writes for pre-change records") {
            check("position write: lands", landed, "the write did not land (read back \(back.map { PBDate.string($0.updated) } ?? "nothing"))")
        }
    }

    private func step<T>(_ name: String, _ body: () async throws -> T) async throws -> T {
        do {
            let value = try await body()
            Live.log("CANARY \(name) ok")
            return value
        } catch {
            Live.log("CANARY \(name) FAILED: \(error)")
            throw error
        }
    }

    private func check(_ name: String, _ ok: Bool, _ detail: String) {
        Live.log("CANARY \(name) \(ok ? "ok" : "FAILED: \(detail)")")
        #expect(ok, "\(name): \(detail)")
    }
}
#endif
