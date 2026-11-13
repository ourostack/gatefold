import CryptoKit
import Foundation
import Testing
@testable import GatefoldCloud

private let creds = StaticCredentials(ClientCredentials(id: "test-id", secret: "test-secret"))
private let frankenstein = "56f8619536655be4a1541a40c5702d32"

private struct Harness {
    let transport: ScriptedTransport
    let clock: TestClock
    let directory: URL
    let tokens: InMemoryTokenStore
    let places: InMemoryPushedPlaces

    init(directory: URL = tempDirectory(), transport: ScriptedTransport? = nil, clock: TestClock = TestClock(),
         places: InMemoryPushedPlaces = InMemoryPushedPlaces(),
         tokens: InMemoryTokenStore = InMemoryTokenStore(StoredSession(
             account: CloudAccount(email: "reader@example.com", store: testStore()),
             token: CloudToken(accessToken: "a1", refreshToken: "r1", expiresAt: utc("2026-12-01T00:00:00Z"))))) {
        self.transport = transport ?? ScriptedTransport(clock: clock)
        self.clock = clock
        self.directory = directory
        self.tokens = tokens
        self.places = places
    }

    func cloud() -> PocketBookCloud {
        let clock = self.clock
        return PocketBookCloud(
            configuration: .init(storageDirectory: directory, autoFlush: false),
            transport: transport, credentials: creds, tokenStore: tokens, pushedPlaces: places,
            now: { clock.now }, jitter: { 1.0 }, sleep: { _ in }
        )
    }
}

private func book(_ fastHash: String = frankenstein, updated: String? = nil, pointer: String? = nil, md5: String? = nil, link: String = "https://cloud.pocketbook.digital/api/v1.0/files/x/signature-download/f1.epub?payload=p&signature=s") -> String {
    let position = updated.map { #"{"pointer":"\#(pointer ?? "")","pointer_pb":"\#(pointer ?? "")","percent":9,"updated":"\#($0)","offs":9}"# }
        ?? #"{"pointer":null,"pointer_pb":null,"percent":0,"updated":null,"offs":0}"#
    return #"{"id":"1","fast_hash":"\#(fastHash)","name":"\#(fastHash).epub","title":"T \#(fastHash.prefix(4))","format":"epub","bytes":5000,"md5_hash":\#(md5.map { "\"\($0)\"" } ?? "null"),"mtime":"2026-10-31T21:56:44Z","link":"\#(link)","position":\#(position)}"#
}

private func page(_ items: [String], total: Int? = nil) -> String {
    #"{"total":\#(total ?? items.count),"items":[\#(items.joined(separator: ","))]}"#
}

private func md5Base64(_ data: Data) -> String { Data(Insecure.MD5.hash(data: data)).base64EncodedString() }

@Suite("Library")
struct LibraryTests {
    @Test func pagesThroughTheWholeLibraryAndCachesIt() async throws {
        let h = Harness()
        let cloud = h.cloud()
        await h.transport.on("GET", "/books?limit=2&offset=0", .json(page([book("aa"), book("bb")], total: 3)))
        await h.transport.on("GET", "/books?limit=2&offset=2", .json(page([book("cc")], total: 3)))
        await cloud.setPageSize(2)
        let books = try await cloud.library()
        #expect(books.map(\.fastHash) == ["aa", "bb", "cc"])
        #expect(await h.cloud().cachedLibrary().map(\.fastHash) == ["aa", "bb", "cc"], "the cache survives a restart")
    }

    @Test func announcesAPositionAnotherClientWrote() async throws {
        let h = Harness()
        await h.transport.on("GET", "/books", .json(page([book(updated: "2026-10-31T21:00:00Z", pointer: "#epubcfi(/6/4!/4/2/1:0)")])),
                             .json(page([book(updated: "2026-10-31T21:30:00Z", pointer: "pbr:/webkit?##epubcfi(/6/16!/4/2/1:0)")])))
        let cloud = h.cloud()
        let stream = cloud.changes()
        _ = try await cloud.library()
        _ = try await cloud.library()
        var remote: ReadingPosition?
        for await change in stream {
            if case let .remotePosition(hash, p) = change { #expect(hash == frankenstein); remote = p; break }
        }
        #expect(remote?.cfi == "epubcfi(/6/16!/4/2/1:0)")
        #expect(remote?.source == .pocketBookNative)
    }

    @Test func announcesAddedAndRemovedBooks() async throws {
        let h = Harness()
        await h.transport.on("GET", "/books", .json(page([book("aa")])), .json(page([book("bb")])))
        let cloud = h.cloud()
        let stream = cloud.changes()
        _ = try await cloud.library()
        _ = try await cloud.library()
        var seen: [CloudChange] = []
        for await change in stream {
            switch change {
            case .bookAdded, .bookRemoved: seen.append(change)
            default: break
            }
            if seen.count == 3 { break }
        }
        #expect(seen.contains(.bookRemoved(fastHash: "aa")))
        #expect(seen.contains { if case let .bookAdded(b) = $0 { b.fastHash == "bb" } else { false } })
    }
}

@Suite("Download and upload")
struct FileTests {
    @Test func downloadsIntoTheContainerAndVerifiesMD5() async throws {
        let h = Harness()
        let bytes = Data(repeating: 7, count: 5000)
        await h.transport.on("GET", "signature-download", .data(bytes))
        let b = try WireDecoder.book(WireDecoder.loose(Data(book(md5: md5Base64(bytes)).utf8)))!
        let url = try await h.cloud().download(b)
        #expect(url.lastPathComponent == "\(frankenstein).epub")
        #expect(try Data(contentsOf: url) == bytes)
        _ = try await h.cloud().download(b)
        #expect(await h.transport.requests("GET", "signature-download").count == 1, "a verified local copy is reused")
    }

    @Test func rejectsACorruptDownloadAndKeepsNothing() async throws {
        let h = Harness()
        await h.transport.on("GET", "signature-download", .data(Data(repeating: 1, count: 5000)))
        let b = try WireDecoder.book(WireDecoder.loose(Data(book(md5: md5Base64(Data("other".utf8))).utf8)))!
        await #expect(throws: CloudError.checksumMismatch) { _ = try await h.cloud().download(b) }
        let left = try FileManager.default.contentsOfDirectory(atPath: h.directory.appendingPathComponent("Books").path)
        #expect(left.isEmpty)
    }

    /// Since November 2026 the Cloud's `md5_hash` is the base64 of the book's fast_hash string, not
    /// an MD5 of its bytes (seen live 2026-11-13; desk evidence/p0-basics-20261113). Every download
    /// failed its check against it, so no book could be opened.
    @Test func downloadsWhenTheCloudsHashIsNotAnMD5() async throws {
        let h = Harness()
        let bytes = Data(repeating: 7, count: 5000)
        await h.transport.on("GET", "signature-download", .data(bytes))
        let notAnMD5 = Data(frankenstein.utf8).base64EncodedString()
        let b = try WireDecoder.book(WireDecoder.loose(Data(book(md5: notAnMD5).utf8)))!
        let url = try await h.cloud().download(b)
        #expect(try Data(contentsOf: url) == bytes)
        _ = try await h.cloud().download(b)
        #expect(await h.transport.requests("GET", "signature-download").count == 1, "the local copy is reused")
    }

    /// With no MD5 to check, the size the Cloud lists still catches a download cut short.
    @Test func withoutAnMD5AShortDownloadIsStillRejected() async throws {
        let h = Harness()
        await h.transport.on("GET", "signature-download", .data(Data(repeating: 7, count: 4000)))
        let notAnMD5 = Data(frankenstein.utf8).base64EncodedString()
        let b = try WireDecoder.book(WireDecoder.loose(Data(book(md5: notAnMD5).utf8)))!
        await #expect(throws: CloudError.checksumMismatch) { _ = try await h.cloud().download(b) }
        let left = try FileManager.default.contentsOfDirectory(atPath: h.directory.appendingPathComponent("Books").path)
        #expect(left.isEmpty)
    }

    @Test func refetchesAnExpiredSignedLink() async throws {
        let h = Harness()
        let bytes = Data(repeating: 3, count: 5000)
        await h.transport.on("GET", "f1.epub", .json("{}", status: 403))
        await h.transport.on("GET", "/fileops/info", .json(#"{"fast_hash":"\#(frankenstein)","name":"x.epub","download_link":"https://cloud.pocketbook.digital/api/v1.0/files/x/signature-download/fresh.epub?payload=p2&signature=s2"}"#))
        await h.transport.on("GET", "fresh.epub", .data(bytes))
        let b = try WireDecoder.book(WireDecoder.loose(Data(book(md5: md5Base64(bytes)).utf8)))!
        let url = try await h.cloud().download(b)
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func refusesTinyEPUBs() async throws {
        let h = Harness()
        let file = h.directory.appendingPathComponent("tiny.epub")
        try Data(repeating: 0, count: 100).write(to: file)
        await #expect(throws: CloudError.fileTooSmall(bytes: 100)) { _ = try await h.cloud().upload(fileAt: file) }
        #expect(await h.transport.requests("PUT", "/files/").isEmpty)
    }

    @Test func uploadsWithAnEncodedNameAndReturnsTheBook() async throws {
        let h = Harness()
        let bytes = Data(repeating: 9, count: 8000)
        let file = h.directory.appendingPathComponent("Alice's Adventures.epub")
        try bytes.write(to: file)
        await h.transport.on("GET", "/books", .json(page([])), .json(page([book("ab12", md5: md5Base64(bytes))])))
        await h.transport.on("GET", "/fileops/info", .json(#"{"error_code":311}"#, status: 404), .json(#"{"fast_hash":"ab12","name":"x"}"#))
        await h.transport.on("PUT", "/api/v1.1/files/", .json(#"{"id":7,"name":"Alice's Adventures.epub","bytes":"8000","fast_hash":"ab12","md5_hash":"\#(md5Base64(bytes))","mtime":"2026-10-31 21:56:29"}"#))
        let uploaded = try await h.cloud().upload(fileAt: file)
        #expect(uploaded.fastHash == "ab12")
        let put = try #require(await h.transport.requests("PUT", "/files/").first)
        #expect(put.url.absoluteString.hasSuffix("/api/v1.1/files/Alice%27s%20Adventures.epub"))
        #expect(put.headers["Content-Type"] == "application/epub+zip")
        #expect(put.body == bytes)
        #expect(await h.transport.requests("GET", "/fileops/info").count == 2, "waited until the Cloud could serve the new book")
        #expect(uploaded.title == "T ab12", "returns the indexed library entry")
    }

    @Test func doesNotUploadABookTheCloudAlreadyHas() async throws {
        let h = Harness()
        let bytes = Data(repeating: 4, count: 8000)
        let file = h.directory.appendingPathComponent("again.epub")
        try bytes.write(to: file)
        await h.transport.on("GET", "/books", .json(page([book("ee", md5: md5Base64(bytes))])))
        let existing = try await h.cloud().upload(fileAt: file)
        #expect(existing.fastHash == "ee")
        #expect(await h.transport.requests("PUT", "/files/").isEmpty)
    }

    @Test func deletesAndConfirmsTheBookIsGone() async throws {
        let h = Harness()
        await h.transport.on("POST", "/fileops/delete/", .ok)
        await h.transport.on("GET", "/fileops/info", .json(#"{"error_code":311,"error_msg":"File not found"}"#, status: 404))
        try await h.cloud().delete(CloudBook(fastHash: frankenstein))
        let del = try #require(await h.transport.requests("POST", "/fileops/delete/").first)
        #expect(del.url.absoluteString.contains("/api/v1.1/fileops/delete/?fast_hash=\(frankenstein)"))
        #expect(del.headers["Content-Type"] == "application/x-www-form-urlencoded")
    }

    @Test func reportsADeleteTheCloudIgnored() async throws {
        let h = Harness()
        await h.transport.on("POST", "/fileops/delete/", .ok)
        await h.transport.on("GET", "/fileops/info", .json(#"{"fast_hash":"\#(frankenstein)","name":"x"}"#))
        await #expect(throws: CloudError.deleteNotApplied) { try await h.cloud().delete(CloudBook(fastHash: frankenstein)) }
        #expect(await h.transport.requests("POST", "/fileops/delete/").count == 2, "retried once before giving up")
    }
}

@Suite("Position sync and the outbox")
struct PositionSyncTests {
    let position = ReadingPosition(cfi: "epubcfi(/6/16[item9]!/4/2[pgepubid00007]/2/1:0)", progression: 0.0, totalProgression: 0.086, updated: utc("2026-10-31T21:59:30Z"))

    func remote(_ updated: String, cfi: String = "epubcfi(/6/8!/4/2/1:0)", headers: [String: String] = [:]) -> ScriptedTransport.Response {
        .json(###"{"fast_hash":"\###(frankenstein)","name":"x","position":{"pointer":"#\###(cfi)","pointer_pb":"#\###(cfi)","percent":3,"updated":"\###(updated)"}}"###, headers: headers)
    }

    @Test func writesExactCFIAndProgressBothWays() async throws {
        let h = Harness()
        await h.transport.on("GET", "/fileops/info", remote("2026-10-31T21:00:00Z"))
        await h.transport.on("POST", "/books/read-position", .ok)
        let cloud = h.cloud()
        await cloud.push(position, for: CloudBook(fastHash: frankenstein))
        await cloud.flushOutbox()
        let post = try #require(await h.transport.requests("POST", "/books/read-position").first)
        #expect(post.query["fast_hash"] == frankenstein)
        #expect(post.json["pointer"] as? String == "#epubcfi(/6/16[item9]!/4/2[pgepubid00007]/2/1:0)")
        #expect(post.json["pointer_pb"] as? String == "pbr:/external##epubcfi(/6/16[item9]!/4/2[pgepubid00007]/2/1:0)")
        #expect(post.json["offs"] as? Int == 9)
        #expect(await cloud.pendingChanges() == 0)
    }

    @Test func marksABookReadByItsFileName() async throws {
        let h = Harness()
        await h.transport.on("POST", "/books/status/", .ok)
        let cloud = h.cloud()
        var book = CloudBook(fastHash: frankenstein)
        book.name = "Frankenstein's Monster.epub"
        await cloud.markRead(book)
        await cloud.markRead(book)
        await cloud.flushOutbox()
        let posts = await h.transport.requests("POST", "/books/status/")
        #expect(posts.count == 1, "two marks coalesce")
        #expect(posts.first?.url.absoluteString.hasSuffix("/api/v1.0/books/status/Frankenstein%27s%20Monster.epub/read") == true)
        #expect(await cloud.pendingChanges() == 0)
    }

    @Test func aBookAlreadyReadIsNotRetried() async throws {
        let h = Harness()
        await h.transport.on("POST", "/books/status/", .json("{}", status: 500))
        let cloud = h.cloud()
        await cloud.markRead(CloudBook(fastHash: frankenstein))
        await cloud.flushOutbox()
        #expect(await h.transport.requests("POST", "/books/status/").count == 1)
        #expect(await cloud.pendingChanges() == 0)
    }

    @Test func coalescesRapidPageTurnsIntoOneWrite() async throws {
        let h = Harness()
        await h.transport.on("GET", "/fileops/info", remote("2026-10-31T21:00:00Z"))
        await h.transport.on("POST", "/books/read-position", .ok)
        let cloud = h.cloud()
        for i in 0..<5 {
            var p = position
            p.cfi = "epubcfi(/6/16!/4/2/4/1:\(i))"
            await cloud.push(p, for: CloudBook(fastHash: frankenstein))
        }
        #expect(await cloud.pendingChanges() == 1)
        await cloud.flushOutbox()
        let posts = await h.transport.requests("POST", "/books/read-position")
        #expect(posts.count == 1)
        #expect(posts.first?.json["pointer"] as? String == "#epubcfi(/6/16!/4/2/4/1:4)")
    }

    @Test func survivesARestartWhileOffline() async throws {
        let h = Harness()
        await h.transport.setOffline(true)
        await h.cloud().push(position, for: CloudBook(fastHash: frankenstein))
        let first = h.cloud()
        await first.flushOutbox()
        #expect(await first.pendingChanges() == 1)

        await h.transport.setOffline(false)
        await h.transport.on("GET", "/fileops/info", remote("2026-10-31T21:00:00Z"))
        await h.transport.on("POST", "/books/read-position", .ok)
        h.clock.advance(3600)
        let second = h.cloud()
        await second.flushOutbox()
        #expect(await h.transport.requests("POST", "/books/read-position").count == 1)
        #expect(await second.pendingChanges() == 0)
    }

    @Test func aNewerPositionFromAnotherClientWins() async throws {
        let h = Harness()
        await h.transport.on("GET", "/fileops/info", remote("2026-10-31T21:59:50Z", cfi: "epubcfi(/6/30!/4/2/1:0)"))
        let cloud = h.cloud()
        let stream = cloud.changes()
        await cloud.push(position, for: CloudBook(fastHash: frankenstein))
        await cloud.flushOutbox()
        #expect(await h.transport.requests("POST", "/books/read-position").isEmpty)
        #expect(await cloud.pendingChanges() == 0)
        for await change in stream {
            if case let .positionSuperseded(hash, remote) = change {
                #expect(hash == frankenstein)
                #expect(remote.cfi == "epubcfi(/6/30!/4/2/1:0)")
                break
            }
        }
    }

    /// Since November 2026 PocketBook answers position writes for records from before its change with 422 "position: File not found."
    /// (seen live 2026-11-13). The app must hear that the place didn't reach the e-reader: never a
    /// silent drop under an "In step with your e-reader" line.
    @Test func aPlaceTheCloudRefusesIsAnnouncedNotLostInSilence() async throws {
        let h = Harness()
        await h.transport.on("GET", "/fileops/info", remote("2026-10-31T21:00:00Z"))
        await h.transport.on("POST", "/books/read-position", .json(#"{"error_code":0,"error_msg":"position: File not found."}"#, status: 422))
        let cloud = h.cloud()
        let stream = cloud.changes()
        await cloud.push(position, for: CloudBook(fastHash: frankenstein))
        await cloud.flushOutbox()
        var refused: String?
        for await change in stream {
            if case let .positionRefused(hash) = change { refused = hash; break }
        }
        #expect(refused == frankenstein)
    }

    @Test func aPlaceThatLandsIsAnnouncedSent() async throws {
        let h = Harness()
        await h.transport.on("GET", "/fileops/info", remote("2026-10-31T21:00:00Z"))
        await h.transport.on("POST", "/books/read-position", .ok)
        let cloud = h.cloud()
        let stream = cloud.changes()
        await cloud.push(position, for: CloudBook(fastHash: frankenstein))
        await cloud.flushOutbox()
        var sent: String?
        for await change in stream {
            if case let .positionSent(hash) = change { sent = hash; break }
        }
        #expect(sent == frankenstein)
    }

    /// The Cloud's shape since November 2026: `/fileops/info/` carries the position only when asked
    /// with `include_metadata=true` (seen live 2026-11-13). Without it Gatefold never saw the InkPad's place.
    func eReaderPlaceOnlyWithMetadata(_ transport: ScriptedTransport, _ updated: String, cfi: String) async {
        await transport.on("GET", "/fileops/info", .json(#"{"fast_hash":"\#(frankenstein)","name":"x","md5_hash":"x"}"#))
        await transport.on("GET", "include_metadata=true", remote(updated, cfi: cfi))
    }

    @Test func readsTheEReadersPlaceThatComesOnlyWithMetadata() async throws {
        let h = Harness()
        await eReaderPlaceOnlyWithMetadata(h.transport, "2026-11-12T23:40:00Z", cfi: "epubcfi(/6/30!/4/2/1:0)")
        let remote = try #require(try await h.cloud().remotePosition(for: CloudBook(fastHash: frankenstein)))
        #expect(remote.cfi == "epubcfi(/6/30!/4/2/1:0)")
        #expect(remote.source != .gatefold)
    }

    @Test func aNewerEReaderPlaceThatComesOnlyWithMetadataIsNotOverwritten() async throws {
        let h = Harness()
        await eReaderPlaceOnlyWithMetadata(h.transport, "2026-10-31T21:59:50Z", cfi: "epubcfi(/6/30!/4/2/1:0)")
        let cloud = h.cloud()
        await cloud.push(position, for: CloudBook(fastHash: frankenstein))
        await cloud.flushOutbox()
        #expect(await h.transport.requests("POST", "/books/read-position").isEmpty, "the InkPad's newer place stands")
    }

    @Test func comparesTimesOnTheServersClock() async throws {
        // Device clock runs 60 s fast: our 21:59:30 is really 21:58:30, older than the remote 21:59:00.
        let h = Harness(clock: TestClock(utc("2026-10-31T22:01:00Z")))
        await h.transport.on("GET", "/fileops/info", remote("2026-10-31T21:59:00Z", cfi: "epubcfi(/6/30!/4/2/1:0)", headers: ["Date": "Sat, 31 Oct 2026 22:00:00 GMT"]))
        await h.transport.on("POST", "/books/read-position", .ok)
        let cloud = h.cloud()
        await cloud.push(position, for: CloudBook(fastHash: frankenstein))
        await cloud.flushOutbox()
        #expect(await h.transport.requests("POST", "/books/read-position").isEmpty)
    }

    @Test func backsOffOnServerErrorsThenRetries() async throws {
        let h = Harness()
        await h.transport.on("GET", "/fileops/info", .json("{}", status: 503), remote("2026-10-31T21:00:00Z"))
        await h.transport.on("POST", "/books/read-position", .ok)
        let cloud = h.cloud()
        await cloud.push(position, for: CloudBook(fastHash: frankenstein))
        await cloud.flushOutbox()
        #expect(await cloud.pendingChanges() == 1)
        await cloud.flushOutbox()
        #expect(await h.transport.requests("GET", "/fileops/info").count == 1, "not retried before the backoff elapses")
        h.clock.advance(5)
        await cloud.flushOutbox()
        #expect(await h.transport.requests("POST", "/books/read-position").count == 1)
    }

    @Test func dropsAWriteForABookThatNoLongerExists() async throws {
        let h = Harness()
        await h.transport.on("GET", "/fileops/info", .json(#"{"error_code":311}"#, status: 404))
        let cloud = h.cloud()
        await cloud.push(position, for: CloudBook(fastHash: frankenstein))
        await cloud.flushOutbox()
        #expect(await cloud.pendingChanges() == 0)
    }

    @Test func aListingCutShortIsAnErrorAndLeavesTheShelfAlone() async throws {
        let h = Harness()
        let cloud = h.cloud()
        await cloud.setPageSize(2)
        await h.transport.on("GET", "/books?limit=2&offset=0", .json(page([book("aa"), book("bb")], total: 3)))
        await h.transport.on("GET", "/books?limit=2&offset=2", .json(page([book("cc")], total: 3)))
        _ = try await cloud.library()
        // The Cloud has a bad moment: the second page comes back empty though it still counts three.
        await h.transport.on("GET", "/books?limit=2&offset=2", .json(page([], total: 3)))
        await #expect(throws: CloudError.self) { _ = try await cloud.library() }
        #expect(await cloud.cachedLibrary().map(\.fastHash) == ["aa", "bb", "cc"])
    }

    @Test func aBookTheCloudListsButWeCantReadDoesNotCutTheListingShort() async throws {
        let h = Harness()
        let cloud = h.cloud()
        await cloud.setPageSize(2)
        await h.transport.on("GET", "/books?limit=2&offset=0", .json(page([book("aa"), #"{"id":"2"}"#], total: 3)))
        await h.transport.on("GET", "/books?limit=2&offset=2", .json(page([book("cc")], total: 3)))
        #expect(try await cloud.library().map(\.fastHash) == ["aa", "cc"])
    }

    @Test func anEmptyListingIsAskedAgainBeforeEveryBookIsAnnouncedGone() async throws {
        let h = Harness()
        let cloud = h.cloud()
        await h.transport.on("GET", "/books", .json(page([book("aa"), book("bb")])))
        _ = try await cloud.library()
        // One empty answer, then the real shelf again.
        await h.transport.on("GET", "/books", .json(page([])), .json(page([book("aa"), book("bb")])))
        #expect(try await cloud.library().map(\.fastHash) == ["aa", "bb"])
        #expect(await h.transport.requests("GET", "/books").count == 3)
        // Empty twice in a row: he really did clear his Cloud.
        await h.transport.on("GET", "/books", .json(page([])))
        #expect(try await cloud.library().isEmpty)
    }

    @Test func aCancelledFetchChangesNothing() async throws {
        let h = Harness()
        let cloud = h.cloud()
        await h.transport.on("GET", "/books", .json(page([book("aa"), book("bb")])))
        _ = try await cloud.library()
        await h.transport.on("GET", "/books", .json(page([book("aa")])))
        await h.transport.setDelay(.milliseconds(300))
        let fetch = Task { try await cloud.library() }
        try await Task.sleep(for: .milliseconds(50))
        fetch.cancel()
        await #expect(throws: (any Error).self) { _ = try await fetch.value }
        #expect(await cloud.cachedLibrary().map(\.fastHash) == ["aa", "bb"])
        #expect(await h.tokens.load() != nil)
    }

    @Test func aServerErrorOrAConfirmedRefusalNeverSignsOut() async throws {
        let h = Harness()
        let cloud = h.cloud()
        await h.transport.on("GET", "/books", .json(page([book("aa")])))
        _ = try await cloud.library()
        await h.transport.on("GET", "/books", .json("{}", status: 503))
        await #expect(throws: CloudError.server(status: 503)) { _ = try await cloud.library() }
        await h.transport.on("GET", "/books", .json("{}", status: 401))
        await h.transport.on("POST", "/auth/renew-token", .json("{}", status: 401))
        await #expect(throws: CloudError.authenticationRequired) { _ = try await cloud.library() }
        #expect(await cloud.account?.email == "reader@example.com")
        #expect(await h.tokens.load() != nil)
        #expect(await cloud.cachedLibrary().map(\.fastHash) == ["aa"])
    }

    @Test func keepsWorkQueuedWhenSignInExpires() async throws {
        let h = Harness()
        await h.transport.on("GET", "/fileops/info", .json("{}", status: 401))
        await h.transport.on("POST", "/auth/renew-token", .json("{}", status: 401))
        let cloud = h.cloud()
        let stream = cloud.changes()
        await cloud.push(position, for: CloudBook(fastHash: frankenstein))
        await cloud.flushOutbox()
        #expect(await cloud.pendingChanges() == 1)
        for await change in stream where change == .authenticationRequired { break }
    }

    @Test func recognisesItsOwnPositionWhenReadingBack() async throws {
        let h = Harness()
        await h.transport.on("POST", "/books/read-position", .ok)
        await h.transport.on("GET", "/fileops/info", remote("2026-10-31T21:00:00Z"),
                             .json(###"{"fast_hash":"\###(frankenstein)","name":"x","position":{"pointer":"#epubcfi(/6/16[item9]!/4/2[pgepubid00007]/2/1:0)","pointer_pb":"pbr:/external##epubcfi(/6/16[item9]!/4/2[pgepubid00007]/2/1:0)","percent":9,"updated":"2026-10-31T22:00:01Z"}}"###))
        let cloud = h.cloud()
        await cloud.push(position, for: CloudBook(fastHash: frankenstein))
        await cloud.flushOutbox()
        let back = try #require(try await cloud.remotePosition(for: CloudBook(fastHash: frankenstein)))
        #expect(back.source == .gatefold)
        #expect(back.cfi == position.cfi)
    }

    // A reinstall wipes the app's files but not the Keychain: our own place must not come back as
    // "From your InkPad" (the Cloud record carries no device or client id to tell by).
    @Test func recognisesItsOwnPositionAfterAReinstall() async throws {
        let places = InMemoryPushedPlaces()
        let first = Harness(places: places)
        await first.transport.on("POST", "/books/read-position", .ok)
        await first.transport.on("GET", "/fileops/info", remote("2026-10-31T21:00:00Z"))
        let firstCloud = first.cloud()
        await firstCloud.push(position, for: CloudBook(fastHash: frankenstein))
        await firstCloud.flushOutbox()

        let reinstalled = Harness(places: places)
        await reinstalled.transport.on("GET", "/fileops/info",
            .json(###"{"fast_hash":"\###(frankenstein)","name":"x","position":{"pointer":"#epubcfi(/6/16[item9]!/4/2[pgepubid00007]/2/1:0)","pointer_pb":"pbr:/external##epubcfi(/6/16[item9]!/4/2[pgepubid00007]/2/1:0)","percent":9,"updated":"2026-10-31T22:00:01Z"}}"###))
        let back = try #require(try await reinstalled.cloud().remotePosition(for: CloudBook(fastHash: frankenstein)))
        #expect(back.source == .gatefold)
    }

    @Test func anotherAccountsPlaceIsNotOurs() async throws {
        let places = InMemoryPushedPlaces()
        let first = Harness(places: places)
        await first.transport.on("POST", "/books/read-position", .ok)
        await first.transport.on("GET", "/fileops/info", remote("2026-10-31T21:00:00Z"))
        let firstCloud = first.cloud()
        await firstCloud.push(position, for: CloudBook(fastHash: frankenstein))
        await firstCloud.flushOutbox()

        let other = Harness(places: places, tokens: InMemoryTokenStore(StoredSession(
            account: CloudAccount(email: "someone-else@example.com", store: testStore()),
            token: CloudToken(accessToken: "a2", refreshToken: "r2", expiresAt: utc("2026-12-01T00:00:00Z")))))
        await other.transport.on("GET", "/fileops/info",
            .json(###"{"fast_hash":"\###(frankenstein)","name":"x","position":{"pointer":"#epubcfi(/6/16[item9]!/4/2[pgepubid00007]/2/1:0)","pointer_pb":"pbr:/external##epubcfi(/6/16[item9]!/4/2[pgepubid00007]/2/1:0)","percent":9,"updated":"2026-10-31T22:00:01Z"}}"###))
        let back = try #require(try await other.cloud().remotePosition(for: CloudBook(fastHash: frankenstein)))
        #expect(back.source == .pocketBookNative)
    }
}

@Suite("Annotations")
struct AnnotationSyncTests {
    let note = try! WireDecoder.annotation(Fixture.data("note.json"))

    @Test func readsEveryAnnotationOfABook() async throws {
        let h = Harness()
        await h.transport.on("GET", "/notes?fast_hash=", .data(try Fixture.data("notes-list.json")))
        await h.transport.on("GET", "/notes/d1c0a338", .data(try Fixture.data("note.json")))
        let list = try await h.cloud().annotations(for: CloudBook(fastHash: frankenstein))
        #expect(list.map(\.uuid) == ["d1c0a338-a35f-4e57-8104-3f8bd5a09820"])
        #expect(list.first?.note?.value == "partial update")
        let detail = try #require(await h.transport.requests("GET", "/notes/d1c0a338").first)
        #expect(detail.query["fast_hash"] == frankenstein, "the Cloud answers 404 for a note without its book")
    }

    @Test func createsANewHighlightThroughTheOutbox() async throws {
        let h = Harness()
        await h.transport.on("POST", "/notes?fast_hash=", .json(#"{"uuid":"new-1","updated":"2026-10-31T22:00:00Z"}"#))
        let cloud = h.cloud()
        let highlight = CloudAnnotation.highlight(begin: "#epubcfi(/6/8!/4/2/4/1:0)", end: "#epubcfi(/6/8!/4/2/4/1:20)", text: "quoted", at: utc("2026-10-31T21:59:00Z"))
        await cloud.save(highlight, for: CloudBook(fastHash: frankenstein))
        await cloud.flushOutbox()
        let post = try #require(await h.transport.requests("POST", "/notes?fast_hash=").first)
        #expect((post.json["quotation"] as? [String: Any])?["text"] as? String == "quoted")
        #expect(await cloud.pendingChanges() == 0)
    }

    @Test func aRetriedCreateDoesNotDuplicate() async throws {
        let h = Harness()
        // First attempt: the request may have landed but the response was lost.
        await h.transport.on("POST", "/notes?fast_hash=", .json("{}", status: 502))
        let cloud = h.cloud()
        let highlight = CloudAnnotation.highlight(begin: "#epubcfi(/6/8!/4/2/4/1:0)", end: "#epubcfi(/6/8!/4/2/4/1:20)", text: "probe text", at: utc("2026-10-31T21:59:00Z"))
        await cloud.save(highlight, for: CloudBook(fastHash: frankenstein))
        await cloud.flushOutbox()
        // On replay the server already holds it.
        await h.transport.on("GET", "/notes?fast_hash=", .data(try Fixture.data("notes-list.json")))
        await h.transport.on("GET", "/notes/d1c0a338", .data(try Fixture.data("note.json")))
        await h.transport.on("POST", "/notes/d1c0a338", .json(#"{"uuid":"d1c0a338-a35f-4e57-8104-3f8bd5a09820"}"#))
        h.clock.advance(10)
        await cloud.flushOutbox()
        #expect(await h.transport.requests("POST", "/notes?fast_hash=").count == 1, "no second create")
        #expect(await cloud.pendingChanges() == 0)
    }

    @Test func updatesAndDeletesByUUID() async throws {
        let h = Harness()
        await h.transport.on("POST", "/notes/d1c0a338", .json(#"{"uuid":"d1c0a338-a35f-4e57-8104-3f8bd5a09820"}"#))
        await h.transport.on("DELETE", "/notes/d1c0a338", .ok)
        let cloud = h.cloud()
        var edited = note
        edited.note = .init("edited", updated: utc("2026-10-31T21:59:59Z"))
        await cloud.save(edited, for: CloudBook(fastHash: frankenstein))
        await cloud.flushOutbox()
        let update = try #require(await h.transport.requests("POST", "/notes/d1c0a338").first)
        #expect((update.json["note"] as? [String: Any])?["text"] as? String == "edited")
        #expect(update.query["fast_hash"] == frankenstein)
        await cloud.deleteAnnotation(edited, for: CloudBook(fastHash: frankenstein))
        await cloud.flushOutbox()
        let deletion = try #require(await h.transport.requests("DELETE", "/notes/d1c0a338").first)
        #expect(deletion.query["fast_hash"] == frankenstein)
    }

    @Test func neverSendsATimestampFromTheFuture() async throws {
        // A future `updated` would block every later edit of that field on the server.
        let h = Harness()
        await h.transport.on("POST", "/notes/d1c0a338", .json("{}"))
        let cloud = h.cloud()
        var edited = note
        edited.color = .init(.green, updated: utc("2026-11-02T00:00:00Z"))
        await cloud.save(edited, for: CloudBook(fastHash: frankenstein))
        await cloud.flushOutbox()
        let update = try #require(await h.transport.requests("POST", "/notes/d1c0a338").first)
        #expect((update.json["color"] as? [String: Any])?["updated"] as? String == "2026-10-31T22:00:00Z")
    }

    @Test func showsPendingEditsOnTopOfTheServerCopy() async throws {
        // The server copy's note is from 22:00:59; the offline edit is newer, so it shows (and will win on the server).
        let h = Harness(clock: TestClock(utc("2026-10-31T22:01:30Z")))
        await h.transport.setOffline(true)
        let cloud = h.cloud()
        var edited = note
        edited.note = .init("offline edit", updated: utc("2026-10-31T22:01:10Z"))
        await cloud.save(edited, for: CloudBook(fastHash: frankenstein))
        await h.transport.setOffline(false)
        await h.transport.on("GET", "/notes?fast_hash=", .data(try Fixture.data("notes-list.json")))
        await h.transport.on("GET", "/notes/d1c0a338", .data(try Fixture.data("note.json")))
        let list = try await cloud.annotations(for: CloudBook(fastHash: frankenstein))
        #expect(list.first?.note?.value == "offline edit")
    }
}

@Suite("Change stream")
struct ChangeStreamTests {
    @Test func everySubscriberSeesEveryChange() async throws {
        let h = Harness()
        let cloud = h.cloud()
        let a = cloud.changes()
        let b = cloud.changes()
        await cloud.signOut()
        var ia = a.makeAsyncIterator()
        var ib = b.makeAsyncIterator()
        #expect(await ia.next() == .signedOut)
        #expect(await ib.next() == .signedOut)
    }
}

@Suite("Outbox races and identity")
struct OutboxRaceTests {
    let highlight = CloudAnnotation.highlight(begin: "#epubcfi(/6/8!/4/2/4/1:0)", end: "#epubcfi(/6/8!/4/2/4/1:20)", text: "quoted", at: utc("2026-10-31T21:59:00Z"))
    let position = ReadingPosition(cfi: "epubcfi(/6/16!/4/2/1:0)", totalProgression: 0.1, updated: utc("2026-10-31T21:59:30Z"))

    @Test func anEditAfterTheCreateLandedUpdatesInsteadOfDuplicating() async throws {
        let h = Harness()
        await h.transport.on("POST", "/notes?fast_hash=", .json(#"{"uuid":"new-1","updated":"2026-10-31T22:00:00Z"}"#))
        await h.transport.on("POST", "/notes/new-1", .json("{}"))
        let cloud = h.cloud()
        let stream = cloud.changes()
        await cloud.save(highlight, for: CloudBook(fastHash: frankenstein))
        await cloud.flushOutbox()
        var recoloured = highlight // the app's copy still has no uuid
        recoloured.color = .init(.green, updated: utc("2026-10-31T21:59:50Z"))
        await cloud.save(recoloured, for: CloudBook(fastHash: frankenstein))
        await cloud.flushOutbox()
        #expect(await h.transport.requests("POST", "/notes?fast_hash=").count == 1)
        #expect(await h.transport.requests("POST", "/notes/new-1").count == 1)
        for await change in stream {
            if case let .annotationSaved(hash, saved) = change { #expect(hash == frankenstein); #expect(saved.uuid == "new-1"); break }
        }
    }

    @Test func aDeleteAfterTheCreateLandedDeletesOnTheServer() async throws {
        let h = Harness()
        await h.transport.on("POST", "/notes?fast_hash=", .json(#"{"uuid":"new-1"}"#))
        await h.transport.on("DELETE", "/notes/new-1", .ok)
        let cloud = h.cloud()
        await cloud.save(highlight, for: CloudBook(fastHash: frankenstein))
        await cloud.flushOutbox()
        await cloud.deleteAnnotation(highlight, for: CloudBook(fastHash: frankenstein))
        await cloud.flushOutbox()
        #expect(await h.transport.requests("DELETE", "/notes/new-1").count == 1)
    }

    @Test func aDeleteDuringTheCreateDeletesItOnceItLands() async throws {
        let h = Harness()
        await h.transport.on("POST", "/notes?fast_hash=", .json(#"{"uuid":"new-1"}"#))
        await h.transport.on("DELETE", "/notes/new-1", .ok)
        await h.transport.setDelay(.milliseconds(800))
        let cloud = h.cloud()
        await cloud.save(highlight, for: CloudBook(fastHash: frankenstein))
        let flush = Task { await cloud.flushOutbox() }
        try await waitForRequest(h.transport, "POST", "/notes?fast_hash=")
        await cloud.deleteAnnotation(highlight, for: CloudBook(fastHash: frankenstein))
        await flush.value
        await cloud.flushOutbox()
        #expect(await h.transport.requests("DELETE", "/notes/new-1").count == 1)
        #expect(await cloud.pendingChanges() == 0)
    }

    @Test func aPositionPushedMidSendGoesOutInTheSameFlush() async throws {
        let h = Harness()
        await h.transport.on("GET", "/fileops/info", .json(#"{"fast_hash":"\#(frankenstein)","name":"x"}"#))
        await h.transport.on("POST", "/books/read-position", .ok)
        await h.transport.setDelay(.milliseconds(800))
        let cloud = h.cloud()
        await cloud.push(position, for: CloudBook(fastHash: frankenstein))
        let flush = Task { await cloud.flushOutbox() }
        try await waitForRequest(h.transport, "POST", "/books/read-position")
        var later = position
        later.cfi = "epubcfi(/6/16!/4/2/1:9)"
        await cloud.push(later, for: CloudBook(fastHash: frankenstein))
        await flush.value
        let posts = await h.transport.requests("POST", "/books/read-position")
        #expect(posts.count == 2)
        #expect(posts.last?.json["pointer"] as? String == "#epubcfi(/6/16!/4/2/1:9)")
        #expect(await cloud.pendingChanges() == 0)
    }

    @Test func aRejectedSendDoesNotDropANewerPayload() async throws {
        let h = Harness()
        await h.transport.on("GET", "/fileops/info", .json(#"{"fast_hash":"\#(frankenstein)","name":"x"}"#))
        await h.transport.on("POST", "/books/read-position", .json("{}", status: 400), .ok)
        await h.transport.setDelay(.milliseconds(800))
        let cloud = h.cloud()
        await cloud.push(position, for: CloudBook(fastHash: frankenstein))
        let flush = Task { await cloud.flushOutbox() }
        try await waitForRequest(h.transport, "POST", "/books/read-position")
        var later = position
        later.cfi = "epubcfi(/6/16!/4/2/1:9)"
        await cloud.push(later, for: CloudBook(fastHash: frankenstein))
        await flush.value
        await cloud.flushOutbox()
        #expect(await h.transport.requests("POST", "/books/read-position").last?.json["pointer"] as? String == "#epubcfi(/6/16!/4/2/1:9)")
        #expect(await cloud.pendingChanges() == 0)
    }

    @Test func noteTimesAreOnTheServersClockEvenOnTheFirstSend() async throws {
        // Fresh launch, device clock an hour fast, nothing has been fetched yet.
        let clock = TestClock(utc("2026-10-31T23:00:00Z"))
        let h = Harness(transport: ScriptedTransport(), clock: clock) // server says 22:00:00
        await h.transport.on("POST", "/notes?fast_hash=", .json(#"{"uuid":"new-1"}"#))
        let cloud = h.cloud()
        await cloud.save(CloudAnnotation.highlight(begin: "#epubcfi(/6/8!/4/2/4/1:0)", end: "#epubcfi(/6/8!/4/2/4/1:20)", text: "q", at: clock.now),
                         for: CloudBook(fastHash: frankenstein))
        await cloud.flushOutbox()
        let post = try #require(await h.transport.requests("POST", "/notes?fast_hash=").first)
        #expect((post.json["color"] as? [String: Any])?["updated"] as? String == "2026-10-31T22:00:00Z")
    }

    @Test func concurrentDownloadsOfOneBookBothSucceed() async throws {
        let h = Harness()
        let bytes = Data(repeating: 5, count: 5000)
        await h.transport.on("GET", "signature-download", .data(bytes))
        await h.transport.setDelay(.milliseconds(30))
        let b = try WireDecoder.book(WireDecoder.loose(Data(book(md5: md5Base64(bytes)).utf8)))!
        let cloud = h.cloud()
        async let first = cloud.download(b)
        async let second = cloud.download(b)
        let (u1, u2) = try await (first, second)
        #expect(u1 == u2)
    }

    @Test func highlightingAPassageAgainAfterDeletingItCreatesANewNote() async throws {
        let h = Harness()
        await h.transport.on("POST", "/notes?fast_hash=", .json(#"{"uuid":"new-1"}"#), .json(#"{"uuid":"new-2"}"#))
        await h.transport.on("DELETE", "/notes/new-1", .ok)
        let cloud = h.cloud()
        let book = CloudBook(fastHash: frankenstein)
        await cloud.save(highlight, for: book)
        await cloud.flushOutbox()
        await cloud.deleteAnnotation(highlight, for: book)
        await cloud.flushOutbox()
        await cloud.save(highlight, for: book)
        await cloud.flushOutbox()
        #expect(await h.transport.requests("POST", "/notes?fast_hash=").count == 2)
        #expect(await h.transport.requests("POST", "/notes/new-1").isEmpty)
    }

    @Test func anUpdateToANoteThatIsGoneOnTheServerBecomesACreate() async throws {
        let h = Harness()
        await h.transport.on("POST", "/notes?fast_hash=", .json(#"{"uuid":"new-1"}"#), .json(#"{"uuid":"new-2"}"#))
        await h.transport.on("POST", "/notes/new-1", .json(#"{"error":"File not found"}"#, status: 404))
        let cloud = h.cloud()
        let book = CloudBook(fastHash: frankenstein)
        await cloud.save(highlight, for: book)
        await cloud.flushOutbox()
        // Deleted elsewhere (the web reader); we still remember new-1.
        var recoloured = highlight
        recoloured.color = .init(.green, updated: utc("2026-10-31T21:59:50Z"))
        await cloud.save(recoloured, for: book)
        await cloud.flushOutbox()
        #expect(await h.transport.requests("POST", "/notes?fast_hash=").count == 2)
        #expect(await cloud.pendingChanges() == 0)
    }

    @Test func savingAgainAfterDeletingAnInFlightCreateKeepsIt() async throws {
        let h = Harness()
        await h.transport.on("POST", "/notes?fast_hash=", .json(#"{"uuid":"new-1"}"#))
        await h.transport.on("DELETE", "/notes/new-1", .ok)
        await h.transport.setDelay(.milliseconds(800))
        let cloud = h.cloud()
        let book = CloudBook(fastHash: frankenstein)
        await cloud.save(highlight, for: book)
        let flush = Task { await cloud.flushOutbox() }
        try await waitForRequest(h.transport, "POST", "/notes?fast_hash=")
        await cloud.deleteAnnotation(highlight, for: book) // and then undo
        await cloud.save(highlight, for: book)
        await flush.value
        await cloud.flushOutbox()
        #expect(await h.transport.requests("DELETE", "/notes/new-1").isEmpty)
    }

    @Test func aCreateInterruptedByARestartLooksBeforePostingAgain() async throws {
        let h = Harness()
        await h.transport.on("POST", "/notes?fast_hash=", .json(#"{"uuid":"new-1"}"#))
        await h.transport.on("GET", "/notes?fast_hash=", .data(try Fixture.data("notes-list.json")))
        await h.transport.setDelay(.milliseconds(800))
        let first = h.cloud()
        await first.save(highlight, for: CloudBook(fastHash: frankenstein))
        let flush = Task { await first.flushOutbox() }
        // Wait until the POST is on the wire, then "kill" the app by starting a second instance.
        try await waitForRequest(h.transport, "POST", "/notes?fast_hash=")
        await h.transport.setDelay(.zero)
        let relaunched = h.cloud()
        await relaunched.flushOutbox()
        _ = await flush.value
        #expect(await !h.transport.requests("GET", "/notes?fast_hash=").isEmpty)
    }

    @Test func anUnreadableOutboxIsKeptAside() async throws {
        let h = Harness()
        try Data("{not json".utf8).write(to: h.directory.appendingPathComponent("outbox.json"))
        _ = h.cloud()
        let names = try FileManager.default.contentsOfDirectory(atPath: h.directory.path)
        #expect(names.contains { $0.hasPrefix("outbox.unreadable-") })
    }
}

/// Waits until the fake has received a matching request, which it records before its delay, so the
/// request is known to be in flight. Avoids fixed sleeps that flake on slow CI runners.
func waitForRequest(_ transport: ScriptedTransport, _ method: String, _ path: String) async throws {
    // Generous: on the CI simulator every test can sit ~22 s before its first request goes out.
    let deadline = ContinuousClock.now + .seconds(90)
    while await transport.requests(method, path).isEmpty, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(await !transport.requests(method, path).isEmpty)
}
