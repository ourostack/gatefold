import Foundation
import Testing
@testable import GatefoldCloud

/// The cloud is unofficial and changes without notice (gatefold#372). When an answer loses something
/// Gatefold can do without, the app carries on and notes the change in CloudDrift for the canary.
@Suite("Tolerating cloud drift")
struct ToleranceTests {
    func noted(_ fragment: String) -> Bool { CloudDrift.shared.notes.contains { $0.contains(fragment) } }

    @Test func signsInWhenTheUserAnswerStopsNamingTheAccount() async throws {
        let t = ScriptedTransport()
        await t.on("POST", "/auth/login/pocketbook_de", .json(#"{"access_token":"a1","refresh_token":"r1","expires_in":3600}"#))
        await t.on("GET", "/api/v1.0/user", .json(#"{"profile":{"name":"x"}}"#))
        let session = CloudSession(transport: t, credentials: StaticCredentials(ClientCredentials(id: "i", secret: "s")),
                                   tokenStore: InMemoryTokenStore(), sleep: { _ in })
        let account = try await session.signIn(email: " reader@example.com ", password: "pw", store: testStore())
        #expect(account.email == "reader@example.com")
        #expect(noted("/user: no email or login"))
    }

    @Test func signsInWhenTheUserCallIsGone() async throws {
        let t = ScriptedTransport()
        await t.on("POST", "/auth/login/pocketbook_de", .json(#"{"access_token":"a1","refresh_token":"r1","expires_in":3600}"#))
        await t.on("GET", "/api/v1.0/user", .json(#"{"error_code":0,"error_msg":"Not found"}"#, status: 404))
        let session = CloudSession(transport: t, credentials: StaticCredentials(ClientCredentials(id: "i", secret: "s")),
                                   tokenStore: InMemoryTokenStore(), sleep: { _ in })
        let account = try await session.signIn(email: "reader@example.com", password: "pw", store: testStore())
        #expect(account.email == "reader@example.com")
        #expect(await session.account != nil, "signed in")
        #expect(noted("/user: 404"))
    }

    @Test func aRefusedTokenOnTheUserCallStillFails() async throws {
        let t = ScriptedTransport()
        await t.on("POST", "/auth/login/pocketbook_de", .json(#"{"access_token":"a1","refresh_token":"r1","expires_in":3600}"#))
        await t.on("GET", "/api/v1.0/user", .json(#"{"error_code":0,"error_msg":"Unauthorized"}"#, status: 401))
        let session = CloudSession(transport: t, credentials: StaticCredentials(ClientCredentials(id: "i", secret: "s")),
                                   tokenStore: InMemoryTokenStore(), sleep: { _ in })
        await #expect(throws: CloudError.authenticationRequired) {
            _ = try await session.signIn(email: "reader@example.com", password: "pw", store: testStore())
        }
    }

    @Test func readsTheLibraryUnderAnotherKey() throws {
        let page = try WireDecoder.booksPage(Data(#"{"total":1,"data":[{"fast_hash":"abc","name":"a.epub","bytes":10}]}"#.utf8))
        #expect(page.items.map(\.fastHash) == ["abc"])
        #expect(noted("/books: the list is no longer under items"))
    }

    @Test func notesBooksItCannotKeep() throws {
        let page = try WireDecoder.booksPage(Data(#"{"total":2,"items":[{"fast_hash":"abc"},{"name":"no-hash.epub"}]}"#.utf8))
        #expect(page.items.count == 1 && page.listed == 2)
        #expect(noted("1 of 2 entries have no fast_hash"))
    }

    @Test func aPlaceWithoutItsTimeStillOpensTheBook() throws {
        let info = try WireDecoder.fileInfo(Data(##"{"fast_hash":"abc","position":{"pointer":"#epubcfi(/6/10!/4/2/1:0)","percent":10}}"##.utf8))
        let place = try #require(info.position)
        #expect(place.cfi != nil)
        #expect(place.updated == .distantPast, "older than any place made here")
        #expect(noted("position: no updated time"))
    }

    @Test func thePlaceComesThroughWhenTheBookLosesItsHash() throws {
        let info = try WireDecoder.fileInfo(Data(##"{"position":{"pointer":"#epubcfi(/6/10!/4/2/1:0)","updated":"2026-11-13T17:06:31Z"},"download_link":"https://x/y"}"##.utf8))
        #expect(info.position?.cfi != nil)
        #expect(info.book?.downloadURL == URL(string: "https://x/y"))
        #expect(noted("/fileops/info: no fast_hash"))
    }

    @Test func anAnswerWithNothingWeNeedStillFails() {
        #expect(throws: WireError.unexpectedShape("fileops.info")) { _ = try WireDecoder.fileInfo(Data(#"{"hello":1}"#.utf8)) }
        #expect(throws: WireError.unexpectedShape("books.items")) { _ = try WireDecoder.booksPage(Data(#"{"total":1}"#.utf8)) }
    }
}
