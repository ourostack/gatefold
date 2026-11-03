#if os(macOS)
import Foundation
import Testing
@testable import GatefoldCloud

/// How the Cloud answers a renewal whose access token is no longer good, as on a phone left overnight.
/// Logs only status codes and the Cloud's error text, never a token.
@Suite("Live renew probe", .serialized, .enabled(if: Live.enabled))
struct LiveRenewProbe {
    static let slow = ProcessInfo.processInfo.environment["GATEFOLD_LIVE_SLOW"] == "1"

    @Test func renewalWithAnUnusableAccessToken() async throws {
        let (refresh, access) = try await Self.signIn()
        try await Self.books("fresh bearer", bearer: access)
        for (label, bearer) in [("garbage bearer", "not-a-token-\(UUID().uuidString)"), ("no bearer", nil) as (String, String?)] {
            try await Self.renew(label, refresh: refresh, bearer: bearer)
        }
        try await Self.books("garbage bearer", bearer: "not-a-token")
    }

    /// Does signing in again (another device, the web reader) retire the first sign-in's tokens?
    @Test func anOlderSignInAfterANewerOne() async throws {
        let first = try await Self.signIn()
        let second = try await Self.signIn()
        try await Self.books("the older sign-in's bearer", bearer: first.access)
        try await Self.books("the newer sign-in's bearer", bearer: second.access)
        try await Self.renew("the older sign-in's tokens", refresh: first.refresh, bearer: first.access)
    }

    /// Off unless GATEFOLD_LIVE_SLOW=1: waits past the access token's own lifetime (expires_in, 2 h) and renews
    /// with the genuinely expired token, which is what the app does the first time it is opened in the morning.
    @Test(.enabled(if: LiveRenewProbe.slow)) func renewalAfterTheAccessTokenHasReallyExpired() async throws {
        let (refresh, access) = try await Self.signIn()
        Live.log("signed in; waiting 2 h 5 min for the access token to expire")
        try await Task.sleep(for: .seconds(2 * 3600 + 300))
        try await Self.books("expired bearer", bearer: access)
        try await Self.renew("expired bearer", refresh: refresh, bearer: access)
    }

    static func signIn() async throws -> (refresh: String, access: String) {
        let account = try Live.account(Int(ProcessInfo.processInfo.environment["GATEFOLD_LIVE_ACCOUNT"] ?? "2") ?? 2)
        let tokens = InMemoryTokenStore()
        let cloud = PocketBookCloud(configuration: .init(storageDirectory: tempDirectory(), autoFlush: false), tokenStore: tokens)
        let store = try #require(try await cloud.stores(forEmail: account.email).first { $0.usesPassword })
        _ = try await cloud.signIn(email: account.email, password: account.password, store: store)
        let saved = try #require(await tokens.load())
        return (try #require(saved.token.refreshToken), saved.token.accessToken)
    }

    static func renew(_ label: String, refresh: String, bearer: String?) async throws {
        let endpoint = Endpoint(method: "POST", path: "/auth/renew-token", body: .form(["grant_type": "refresh_token", "refresh_token": refresh]))
        let (data, response) = try await URLSessionTransport().send(endpoint.request(base: CloudSession.defaultBase, bearer: bearer))
        Live.log("renew with \(label): HTTP \(response.statusCode) \(describe(data))")
    }

    static func books(_ label: String, bearer: String) async throws {
        let (data, response) = try await URLSessionTransport().send(Endpoint.get("/books", query: ["limit": "1", "offset": "0"]).request(base: CloudSession.defaultBase, bearer: bearer))
        Live.log("GET /books with \(label): HTTP \(response.statusCode) \((200..<300).contains(response.statusCode) ? listing(data) : describe(data))")
    }

    static func listing(_ data: Data) -> String {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return "(no JSON)" }
        return "total=\(json["total"].map { "\($0)" } ?? "-") items=\((json["items"] as? [Any])?.count ?? -1)"
    }

    /// The error fields only: a success body holds tokens and is never logged.
    static func describe(_ data: Data) -> String {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return "(no JSON)" }
        if json["access_token"] != nil { return "(new tokens)" }
        return "error_code=\(json["error_code"].map { "\($0)" } ?? "-") error_msg=\(json["error_msg"].map { "\($0)" } ?? "-")"
    }
}
#endif
