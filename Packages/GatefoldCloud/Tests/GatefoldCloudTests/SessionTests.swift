import Foundation
import Testing
@testable import GatefoldCloud

private let fakeCredentials = StaticCredentials(ClientCredentials(id: "test-id", secret: "test-secret"))

private func makeSession(_ transport: ScriptedTransport, store: any TokenStore = InMemoryTokenStore(), clock: TestClock = TestClock()) -> CloudSession {
    CloudSession(transport: transport, credentials: fakeCredentials, tokenStore: store, now: { clock.now }, sleep: { _ in })
}

private func signedIn(_ transport: ScriptedTransport, clock: TestClock = TestClock(), store: any TokenStore = InMemoryTokenStore()) async throws -> CloudSession {
    await transport.on("POST", "/auth/login/pocketbook_de", .json(tokenJSON("a1")))
    await transport.on("GET", "/api/v1.0/user", .data(try Fixture.data("user.json")))
    let session = makeSession(transport, store: store, clock: clock)
    _ = try await session.signIn(email: "reader@example.com", password: "pw", store: testStore())
    return session
}

@Suite("Client credentials discovery")
struct CredentialsTests {
    @Test func readsThePairFromTheWebAppBundle() async throws {
        let t = ScriptedTransport()
        await t.on("GET", "/browser/", .data(Data(#"<script src="/browser/static/js/4.abc.chunk.js"></script><script src="/browser/static/js/main.1234abcd.chunk.js"></script>"#.utf8)))
        await t.on("GET", "main.1234abcd.chunk.js", .data(Data(#"x,u="".concat(r,"/api/v1.0/"),d="".concat(r,"/api/v1.1/"),l="FAKEID12",h="FakeSecretValueThatIsLongEnough0123456789",p="info@example.com""#.utf8)))
        let provider = WebBundleCredentials(transport: t)
        let creds = try await provider.credentials(refresh: false)
        #expect(creds == ClientCredentials(id: "FAKEID12", secret: "FakeSecretValueThatIsLongEnough0123456789"))
        _ = try await provider.credentials(refresh: false)
        #expect(await t.requests("GET", "main.1234abcd").count == 1, "cached after the first fetch")
    }

    /// The welcome screen warms the pair while the reader types; the store lookup that follows
    /// must join that fetch, not start a second one.
    @Test func concurrentCallersShareOneFetch() async throws {
        let t = ScriptedTransport()
        await t.setDelay(.milliseconds(80))
        await t.on("GET", "/browser/", .data(Data(#"<script src="/browser/static/js/main.1234abcd.chunk.js"></script>"#.utf8)))
        await t.on("GET", "main.1234abcd.chunk.js", .data(Data(#"d="".concat(r,"/api/v1.1/"),l="FAKEID12",h="FakeSecretValueThatIsLongEnough0123456789""#.utf8)))
        let provider = WebBundleCredentials(transport: t)
        async let warm = provider.credentials(refresh: false)
        async let lookup = provider.credentials(refresh: false)
        let (a, b) = try await (warm, lookup)
        #expect(a == b)
        #expect(await t.requests("GET", "main.1234abcd").count == 1, "one bundle fetch for both callers")
    }

    @Test func prepareSignInWarmsTheClientPair() async throws {
        let t = ScriptedTransport()
        await t.on("GET", "/browser/", .data(Data(#"<script src="/browser/static/js/main.1234abcd.chunk.js"></script>"#.utf8)))
        await t.on("GET", "main.1234abcd.chunk.js", .data(Data(#"d="".concat(r,"/api/v1.1/"),l="FAKEID12",h="FakeSecretValueThatIsLongEnough0123456789""#.utf8)))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cloud = PocketBookCloud(configuration: .init(storageDirectory: dir), transport: t, tokenStore: InMemoryTokenStore())
        await cloud.prepareSignIn()
        #expect(await t.requests("GET", "main.1234abcd").count == 1)
    }

    @Test func failsClearlyWhenTheBundleChangesShape() async throws {
        let t = ScriptedTransport()
        await t.on("GET", "/browser/", .data(Data("<html></html>".utf8)))
        await #expect(throws: CloudError.clientCredentialsUnavailable) {
            _ = try await WebBundleCredentials(transport: t, fallback: nil).credentials(refresh: false)
        }
    }

    /// PocketBook's new web app (November 2026) serves no `/browser/` bundle and keeps its secret on
    /// its server, so discovery finds nothing. Sign-in falls back to the pair we know works.
    @Test func fallsBackToTheKnownPairWhenTheWebAppNoLongerShipsIt() async throws {
        let t = ScriptedTransport() // every path answers 404, as /browser/ does now
        let fallback = ClientCredentials(id: "FALLBACK1", secret: "FallbackSecretLongEnough0123456789")
        #expect(try await WebBundleCredentials(transport: t, fallback: fallback).credentials(refresh: false) == fallback)
    }

    @Test func signInHasAPairByDefault() async throws {
        let t = ScriptedTransport()
        let creds = try await WebBundleCredentials(transport: t).credentials(refresh: false)
        #expect(creds == ClientCredentials.pocketBookWeb)
        #expect(creds.id.count >= 4 && creds.secret.count >= 16)
    }

    @Test func offlineIsStillOffline() async throws {
        let t = ScriptedTransport()
        await t.setOffline(true)
        await #expect(throws: CloudError.offline) { _ = try await WebBundleCredentials(transport: t).credentials(refresh: false) }
    }
}

@Suite("Sign-in, tokens and refresh")
struct SessionTests {
    @Test func looksUpStoresByEmail() async throws {
        let t = ScriptedTransport()
        await t.on("GET", "/auth/login", .data(try Fixture.data("auth-providers.json")))
        let stores = try await makeSession(t).stores(forEmail: "  reader@example.com ")
        #expect(stores.map(\.alias) == ["pocketbook_de"])
        let q = try #require(await t.sent.first).query
        #expect(q["username"] == "reader@example.com")
        #expect(q["client_id"] == "test-id")
        #expect(q["client_secret"] == "test-secret")
    }

    @Test func reportsAnUnknownEmailAsNoAccount() async throws {
        let t = ScriptedTransport()
        await t.on("GET", "/auth/login", .json(#"{"error_code":0,"error_msg":"Not found"}"#, status: 404))
        await #expect(throws: CloudError.noAccount) { _ = try await makeSession(t).stores(forEmail: "nobody@example.com") }
    }

    /// Since November 2026 the Cloud sometimes answers a real account's lookup with 404 "No one account
    /// has been found", then finds it a second later (seen live 2026-11-13). Asked again before it counts.
    @Test func aLookupTheCloudFumblesIsAskedAgain() async throws {
        let t = ScriptedTransport()
        await t.on("GET", "/auth/login", .json(#"{"error_code":111,"error_msg":"No one account has been found"}"#, status: 404),
                   .data(try Fixture.data("auth-providers.json")))
        let stores = try await makeSession(t).stores(forEmail: "reader@example.com")
        #expect(stores.map(\.alias) == ["pocketbook_de"])
    }

    @Test func anUnknownEmailIsAskedThreeTimesInAll() async throws {
        let t = ScriptedTransport()
        await t.on("GET", "/auth/login", .json(#"{"error_code":111,"error_msg":"No one account has been found"}"#, status: 404))
        await #expect(throws: CloudError.noAccount) { _ = try await makeSession(t).stores(forEmail: "nobody@example.com") }
        #expect(await t.requests("GET", "/auth/login").count == 3)
    }

    /// The Cloud refuses about one correct password in three with 403 error 1204 "Authorization partner
    /// user failed", the same answer a wrong password gets (seen live 2026-11-13). Tried again before
    /// we tell the reader the password is wrong.
    @Test func aCorrectPasswordThePartnerStoreRefusesOnceSignsIn() async throws {
        let t = ScriptedTransport()
        await t.on("POST", "/auth/login/pocketbook_de", .json(#"{"error_code":1204,"error_msg":"Authorization partner user failed"}"#, status: 403),
                   .json(tokenJSON("a1")))
        await t.on("GET", "/api/v1.0/user", .data(try Fixture.data("user.json")))
        _ = try await makeSession(t).signIn(email: "reader@example.com", password: "pw", store: testStore())
        #expect(await t.requests("POST", "/auth/login/pocketbook_de").count == 2)
    }

    /// Only twice: each try counts against the Cloud's per-account login limit.
    @Test func aPasswordRefusedTwiceIsWrong() async throws {
        let t = ScriptedTransport()
        await t.on("POST", "/auth/login/pocketbook_de", .json(#"{"error_code":1204,"error_msg":"Authorization partner user failed"}"#, status: 403))
        await #expect(throws: CloudError.invalidCredentials) {
            _ = try await makeSession(t).signIn(email: "reader@example.com", password: "bad", store: testStore())
        }
        #expect(await t.requests("POST", "/auth/login/pocketbook_de").count == 2)
    }

    @Test func theLoginLimitStopsTheRetryAndSaysSo() async throws {
        let t = ScriptedTransport()
        await t.on("POST", "/auth/login/pocketbook_de", .json(#"{"error_code":1204,"error_msg":"Authorization partner user failed"}"#, status: 403),
                   .json(#"{"error_code":0,"error_msg":"Too many login attempts. Please try again later."}"#, status: 429))
        await #expect(throws: CloudError.rateLimited(retryAfter: nil)) {
            _ = try await makeSession(t).signIn(email: "reader@example.com", password: "pw", store: testStore())
        }
        #expect(await t.requests("POST", "/auth/login/pocketbook_de").count == 2)
    }

    @Test func signsInWithThePasswordGrantAndKeepsOnlyTokens() async throws {
        let t = ScriptedTransport()
        let store = InMemoryTokenStore()
        let session = try await signedIn(t, store: store)
        let login = try #require(await t.requests("POST", "/auth/login/pocketbook_de").first)
        #expect(login.form["grant_type"] == "password")
        #expect(login.form["shop_id"] == "1")
        #expect(login.form["username"] == "reader@example.com")
        #expect(login.form["password"] == "pw")
        #expect(login.headers["Content-Type"] == "application/x-www-form-urlencoded")
        #expect(await session.account?.displayName == "Gatefold Test One")
        let saved = try #require(await store.load())
        #expect(saved.token.accessToken == "a1")
        #expect(String(decoding: try JSONEncoder().encode(saved), as: UTF8.self).contains("\"pw\"") == false, "the password is never stored")
    }

    @Test func mapsABadPasswordToInvalidCredentials() async throws {
        let t = ScriptedTransport()
        await t.on("POST", "/auth/login/pocketbook_de", .json(#"{"error_code":2,"error_msg":"Invalid credentials"}"#, status: 401))
        await #expect(throws: CloudError.invalidCredentials) {
            _ = try await makeSession(t).signIn(email: "reader@example.com", password: "bad", store: testStore())
        }
    }

    @Test func sendsTheBearerTokenOnAuthorizedCalls() async throws {
        let t = ScriptedTransport()
        let session = try await signedIn(t)
        await t.on("GET", "/books", .json(#"{"total":0,"items":[]}"#))
        _ = try await session.send(.get("/books", query: ["limit": "1"]))
        let call = try #require(await t.requests("GET", "/books").first)
        #expect(call.headers["Authorization"] == "Bearer a1")
    }

    @Test func refreshesAnExpiringTokenBeforeUsingIt() async throws {
        let t = ScriptedTransport()
        let clock = TestClock()
        let session = try await signedIn(t, clock: clock)
        clock.advance(7200 - 60) // inside the 120 s early-refresh window
        await t.on("POST", "/auth/renew-token", .json(tokenJSON("a2", refresh: "r2")))
        await t.on("GET", "/books", .json(#"{"total":0,"items":[]}"#))
        _ = try await session.send(.get("/books"))
        let renew = try #require(await t.requests("POST", "/auth/renew-token").first)
        #expect(renew.form["grant_type"] == "refresh_token")
        #expect(renew.form["refresh_token"] == "r1")
        #expect(renew.headers["Authorization"] == "Bearer a1")
        #expect(await t.requests("GET", "/books").first?.headers["Authorization"] == "Bearer a2")
    }

    @Test func retriesOnceAfterA401() async throws {
        let t = ScriptedTransport()
        let session = try await signedIn(t)
        await t.on("GET", "/books", .json("{}", status: 401), .json(#"{"total":0,"items":[]}"#))
        await t.on("POST", "/auth/renew-token", .json(tokenJSON("a2")))
        _ = try await session.send(.get("/books"))
        #expect(await t.requests("GET", "/books").map { $0.headers["Authorization"] } == ["Bearer a1", "Bearer a2"])
    }

    @Test func concurrentCallsShareOneRefresh() async throws {
        let t = ScriptedTransport()
        let clock = TestClock()
        let session = try await signedIn(t, clock: clock)
        clock.advance(8000)
        await t.on("POST", "/auth/renew-token", .json(tokenJSON("a2")))
        await t.on("GET", "/books", .json(#"{"total":0,"items":[]}"#))
        await t.setDelay(.milliseconds(20))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<5 { group.addTask { _ = try await session.send(.get("/books")) } }
            try await group.waitForAll()
        }
        #expect(await t.requests("POST", "/auth/renew-token").count == 1)
    }

    @Test func keepsTheOldRefreshTokenWhenNoneComesBack() async throws {
        let t = ScriptedTransport()
        let store = InMemoryTokenStore()
        let clock = TestClock()
        let session = try await signedIn(t, clock: clock, store: store)
        clock.advance(8000)
        await t.on("POST", "/auth/renew-token", .json(tokenJSON("a2", refresh: nil)))
        await t.on("GET", "/books", .json(#"{"total":0,"items":[]}"#))
        _ = try await session.send(.get("/books"))
        #expect(await store.load()?.token.refreshToken == "r1")
        #expect(await store.load()?.token.accessToken == "a2")
    }

    /// Build 13 signed out here, wiping the Keychain on one refused renewal. Now a refusal is asked
    /// twice before it counts, and even a confirmed one keeps the session: the app asks him to sign in again.
    @Test func aConfirmedDeadRefreshTokenAsksForSignInButKeepsTheSession() async throws {
        let t = ScriptedTransport()
        let store = InMemoryTokenStore()
        let clock = TestClock()
        let session = try await signedIn(t, clock: clock, store: store)
        clock.advance(8000)
        await t.on("POST", "/auth/renew-token", .json(#"{"error_code":3}"#, status: 401))
        await #expect(throws: CloudError.authenticationRequired) { _ = try await session.send(.get("/books")) }
        #expect(await t.requests("POST", "/auth/renew-token").count == 2, "asked twice before believing it")
        #expect(await store.load()?.account.email == "reader@example.com")
        #expect(await session.account?.email == "reader@example.com")
    }

    @Test func aSingleRefusedRenewalThatThenWorksKeepsGoing() async throws {
        let t = ScriptedTransport()
        let store = InMemoryTokenStore()
        let clock = TestClock()
        let session = try await signedIn(t, clock: clock, store: store)
        clock.advance(8000)
        await t.on("POST", "/auth/renew-token", .json(#"{"error_code":222,"error_msg":"Invalid refresh token"}"#, status: 403), .json(tokenJSON("a2", refresh: "r2")))
        await t.on("GET", "/books", .json(#"{"total":0,"items":[]}"#))
        _ = try await session.send(.get("/books"))
        #expect(await store.load()?.token.accessToken == "a2")
    }

    @Test func aSingle401IsRetriedWithARenewedTokenAndIsNotAnError() async throws {
        let t = ScriptedTransport()
        let store = InMemoryTokenStore()
        let session = try await signedIn(t, store: store)
        await t.on("GET", "/books", .json("{}", status: 401), .json(#"{"total":0,"items":[]}"#))
        await t.on("POST", "/auth/renew-token", .json(tokenJSON("a2", refresh: "r2")))
        _ = try await session.send(.get("/books"))
        #expect(await t.requests("GET", "/books").last?.headers["Authorization"] == "Bearer a2")
        #expect(await session.account != nil)
    }

    @Test func aConfirmed401AfterARenewedTokenAsksForSignInButKeepsTheSession() async throws {
        let t = ScriptedTransport()
        let store = InMemoryTokenStore()
        let session = try await signedIn(t, store: store)
        await t.on("GET", "/books", .json("{}", status: 401))
        await t.on("POST", "/auth/renew-token", .json(tokenJSON("a2", refresh: "r2")))
        await #expect(throws: CloudError.authenticationRequired) { _ = try await session.send(.get("/books")) }
        #expect(await store.load()?.account.email == "reader@example.com")
        #expect(await session.account != nil)
    }

    /// The live Cloud answers a bad token with 403 "Wrong token format" (error_code 222), not 401.
    @Test func a403AboutTheTokenIsTreatedLikeA401() async throws {
        let t = ScriptedTransport()
        let session = try await signedIn(t)
        await t.on("GET", "/books", .json(#"{"error_code":222,"error_msg":"Wrong token format"}"#, status: 403), .json(#"{"total":0,"items":[]}"#))
        await t.on("POST", "/auth/renew-token", .json(tokenJSON("a2", refresh: "r2")))
        _ = try await session.send(.get("/books"))
        #expect(await t.requests("POST", "/auth/renew-token").count == 1)
    }

    @Test func a403ThatIsNotAboutTheTokenIsNotASignInProblem() async throws {
        let t = ScriptedTransport()
        let session = try await signedIn(t)
        await t.on("GET", "/books", .json(#"{"error_code":403,"error_msg":"Access to this token's shop is forbidden"}"#, status: 403))
        do {
            _ = try await session.send(.get("/books"))
            Issue.record("expected an error")
        } catch let error as CloudError {
            #expect(error != .authenticationRequired)
        }
        #expect(await t.requests("POST", "/auth/renew-token").isEmpty)
    }

    @Test func aRenewalThatFailsOnTheNetworkKeepsTheSession() async throws {
        let t = ScriptedTransport()
        let store = InMemoryTokenStore()
        let clock = TestClock()
        let session = try await signedIn(t, clock: clock, store: store)
        clock.advance(8000)
        await t.setOffline(true)
        await #expect(throws: CloudError.offline) { _ = try await session.send(.get("/books")) }
        await t.on("POST", "/auth/renew-token", .json("{}", status: 503))
        await t.setOffline(false)
        await #expect(throws: CloudError.server(status: 503)) { _ = try await session.send(.get("/books")) }
        #expect(await store.load()?.token.accessToken == "a1")
        #expect(await session.account != nil)
    }

    /// Pull-to-refresh lets go while the token is being renewed: the renewal finishes and is kept.
    @Test func cancellingACallMidRenewalKeepsTheSessionAndTheNewToken() async throws {
        let t = ScriptedTransport()
        let store = InMemoryTokenStore()
        let clock = TestClock()
        let session = try await signedIn(t, clock: clock, store: store)
        clock.advance(8000)
        await t.on("POST", "/auth/renew-token", .json(tokenJSON("a2", refresh: "r2")))
        await t.on("GET", "/books", .json(#"{"total":0,"items":[]}"#))
        await t.setDelay(.milliseconds(300))
        let call = Task { try await session.send(.get("/books")) }
        try await waitForRequest(t, "POST", "/auth/renew-token")
        call.cancel()
        _ = try? await call.value
        let deadline = ContinuousClock.now + .seconds(10)
        while await store.load()?.token.accessToken != "a2", ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await store.load()?.token.accessToken == "a2")
        #expect(await session.account?.email == "reader@example.com")
    }

    @Test func aRateLimitedRefreshKeepsTheSession() async throws {
        let t = ScriptedTransport()
        let store = InMemoryTokenStore()
        let clock = TestClock()
        let session = try await signedIn(t, clock: clock, store: store)
        clock.advance(8000)
        await t.on("POST", "/auth/renew-token", .json("{}", status: 429))
        await #expect(throws: CloudError.rateLimited(retryAfter: nil)) { _ = try await session.send(.get("/books")) }
        #expect(await store.load() != nil)
    }

    @Test func signingOutDuringARefreshStaysSignedOut() async throws {
        let t = ScriptedTransport()
        let store = InMemoryTokenStore()
        let clock = TestClock()
        let session = try await signedIn(t, clock: clock, store: store)
        clock.advance(8000)
        await t.on("POST", "/auth/renew-token", .json(tokenJSON("a2")))
        await t.on("GET", "/books", .json(#"{"total":0,"items":[]}"#))
        await t.setDelay(.milliseconds(300))
        let call = Task { try await session.send(.get("/books")) }
        try await waitForRequest(t, "POST", "/auth/renew-token")
        await session.signOut()
        _ = try? await call.value
        #expect(await store.load() == nil)
        #expect(await session.account == nil)
    }

    @Test func aKeychainThatReadsEmptyAtLaunchIsReadAgainLater() async throws {
        let store = InMemoryTokenStore() // empty, as before first unlock
        let session = makeSession(ScriptedTransport(), store: store)
        #expect(await session.account == nil)
        try await store.save(StoredSession(account: CloudAccount(email: "reader@example.com", store: testStore()),
                                           token: CloudToken(accessToken: "a", refreshToken: "r", expiresAt: utc("2026-12-01T00:00:00Z"))))
        #expect(await session.account?.email == "reader@example.com")
    }

    @Test func aLateRefreshDoesNotOverwriteANewerSignIn() async throws {
        let t = ScriptedTransport()
        let store = SlowSaveStore(delay: .milliseconds(800))
        let clock = TestClock()
        let session = try await signedIn(t, clock: clock, store: store)
        clock.advance(8000)
        await t.on("POST", "/auth/renew-token", .json(tokenJSON("a2")))
        let call = Task { try await session.send(.get("/books")) }
        let deadline = ContinuousClock.now + .seconds(20)
        while await store.savesStarted < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) } // refresh is saving
        await store.setDelay(.zero)
        await t.on("POST", "/auth/login/pocketbook_de", .json(tokenJSON("b1")))
        _ = try await session.signIn(email: "reader@example.com", password: "pw", store: testStore())
        _ = try? await call.value
        #expect(await store.load()?.token.accessToken == "b1")
    }

    @Test func restoresASavedSessionWithoutSigningIn() async throws {
        let t = ScriptedTransport()
        let store = InMemoryTokenStore()
        _ = try await signedIn(t, store: store)
        let restored = makeSession(t, store: store)
        #expect(await restored.account?.email == "reader@example.com")
    }

    @Test func signOutForgetsTokens() async throws {
        let t = ScriptedTransport()
        let store = InMemoryTokenStore()
        let session = try await signedIn(t, store: store)
        await session.signOut()
        #expect(await store.load() == nil)
        await #expect(throws: CloudError.notSignedIn) { _ = try await session.send(.get("/books")) }
    }

    @Test func mapsHTTPFailures() async throws {
        let t = ScriptedTransport()
        let session = try await signedIn(t)
        await t.on("GET", "/limited", .json("{}", status: 429, headers: ["Retry-After": "30"]))
        await t.on("GET", "/broken", .json("{}", status: 503))
        await t.on("GET", "/missing", .json(#"{"error_code":311,"error_msg":"File not found"}"#, status: 404))
        await #expect(throws: CloudError.rateLimited(retryAfter: 30)) { _ = try await session.send(.get("/limited")) }
        await #expect(throws: CloudError.server(status: 503)) { _ = try await session.send(.get("/broken")) }
        await #expect(throws: CloudError.notFound) { _ = try await session.send(.get("/missing")) }
        await t.setOffline(true)
        await #expect(throws: CloudError.offline) { _ = try await session.send(.get("/limited")) }
    }

    @Test func learnsTheServerClockFromResponses() async throws {
        let t = ScriptedTransport()
        let clock = TestClock(utc("2026-10-31T21:59:00Z")) // device runs 60 s slow
        let session = try await signedIn(t, clock: clock)
        #expect(await session.serverClockOffset == 60)
    }
}

@Suite("Keychain token store")
struct KeychainTokenStoreTests {
    @Test func savesLoadsAndClears() async throws {
        let store = KeychainTokenStore(service: "bot.ouro.gatefold.tests.\(UUID().uuidString)")
        let session = StoredSession(account: CloudAccount(email: "reader@example.com", store: testStore()),
                                    token: CloudToken(accessToken: "a", refreshToken: "r", expiresAt: utc("2026-11-01T00:00:00Z")))
        do {
            try await store.save(session)
        } catch KeychainError.unavailable {
            return // headless CI without a login keychain
        }
        #expect(await store.load() == session)
        await store.clear()
        #expect(await store.load() == nil)
    }
}

/// A token store whose saves take a while, to hold a refresh in the middle of persisting.
actor SlowSaveStore: TokenStore {
    private var session: StoredSession?
    private var delay: Duration
    init(delay: Duration) { self.delay = delay }
    func setDelay(_ d: Duration) { delay = d }
    func load() async -> StoredSession? { session }
    private(set) var savesStarted = 0
    func save(_ s: StoredSession) async throws {
        savesStarted += 1
        let d = delay
        if d > .zero { try? await Task.sleep(for: d) }
        session = s
    }
    func clear() async { session = nil }
}
