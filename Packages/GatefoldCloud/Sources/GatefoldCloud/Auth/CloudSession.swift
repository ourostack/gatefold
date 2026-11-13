import Foundation

/// Sign-in, token storage and authorized calls. One actor owns the token, so concurrent
/// callers share a single refresh.
public actor CloudSession {
    public static let defaultBase = URL(string: "https://cloud.pocketbook.digital")!
    /// Refresh this long before `expires_in` runs out (PocketOrbit uses the same margin).
    static let refreshMargin: TimeInterval = 120

    let transport: HTTPTransport
    let credentials: ClientCredentialsProvider
    let tokenStore: TokenStore
    let base: URL
    let now: @Sendable () -> Date
    let sleep: @Sendable (Duration) async throws -> Void
    let language: String

    private var stored: StoredSession?
    private var loaded = false
    private var refreshing: Task<CloudToken, Error>?
    /// Bumped by sign-in and sign-out so a refresh that finishes afterwards cannot restore an old session.
    private var generation = 0
    private var clockKnown = false
    /// The last Keychain write failure, if any. The session still works for this launch.
    public private(set) var persistenceError: Error?
    /// Server time minus device time, from the latest `Date` header.
    public private(set) var serverClockOffset: TimeInterval = 0

    public init(transport: HTTPTransport, credentials: ClientCredentialsProvider, tokenStore: TokenStore,
                base: URL = CloudSession.defaultBase, language: String = "en", now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.transport = transport
        self.credentials = credentials
        self.tokenStore = tokenStore
        self.base = base
        self.language = language
        self.now = now
        self.sleep = sleep
    }

    /// Sign-in calls the Cloud refuses spuriously are asked again, a second apart. Since November 2026
    /// it answers a real account's lookup with 404 "No one account has been found", and about one
    /// correct password in three with 403 error 1204, the same answer a wrong password gets (seen live
    /// 2026-11-13). The lookup is asked three times in all. The password only twice: a wrong one costs
    /// every attempt against the Cloud's per-account login limit (429 "Too many login attempts").
    static let lookupAttempts = 3
    static let passwordAttempts = 2

    private func performSignInCall(_ endpoint: Endpoint, attempts: Int, refusedWhen refused: (HTTPURLResponse) -> Bool) async throws -> (Data, HTTPURLResponse) {
        var attempt = 1
        while true {
            let (data, response) = try await perform(endpoint, bearer: nil)
            guard refused(response), attempt < attempts else { return (data, response) }
            attempt += 1
            try await sleep(.seconds(1))
        }
    }

    public var account: CloudAccount? {
        get async {
            await loadIfNeeded()
            return stored?.account
        }
    }

    /// Device time translated to the server's clock.
    public func serverNow() -> Date { now().addingTimeInterval(serverClockOffset) }

    /// A device-clock date on the server's clock.
    public func serverTime(_ deviceDate: Date) -> Date { deviceDate.addingTimeInterval(serverClockOffset) }

    public func stores(forEmail email: String) async throws -> [CloudStore] {
        let creds = try await credentials.credentials(refresh: false)
        let endpoint = Endpoint.get("/auth/login", query: [
            "username": email.trimmingCharacters(in: .whitespacesAndNewlines),
            "client_id": creds.id, "client_secret": creds.secret, "language": language,
        ])
        let (data, response) = try await performSignInCall(endpoint, attempts: Self.lookupAttempts) { $0.statusCode == 404 }
        if response.statusCode == 404 { throw CloudError.noAccount }
        try Self.check(response, data)
        return try WireDecoder.stores(data)
    }

    public func signIn(email: String, password: String, store: CloudStore) async throws -> CloudAccount {
        let creds = try await credentials.credentials(refresh: false)
        let endpoint = Endpoint(method: "POST", path: "/auth/login/\(Endpoint.pathSegment(store.alias))", body: .form([
            "shop_id": store.shopID, "username": email.trimmingCharacters(in: .whitespacesAndNewlines), "password": password,
            "client_id": creds.id, "client_secret": creds.secret, "grant_type": "password", "language": language,
        ]))
        let (data, response) = try await performSignInCall(endpoint, attempts: Self.passwordAttempts) { $0.statusCode == 403 }
        if [400, 401, 403].contains(response.statusCode) { throw CloudError.invalidCredentials }
        try Self.check(response, data)
        let token = try WireDecoder.token(data, now: now())

        let (userData, userResponse) = try await perform(.get("/user"), bearer: token.accessToken)
        try Self.check(userResponse, userData)
        var account = try WireDecoder.account(userData, store: store)
        if account.email.isEmpty { account.email = email }
        let session = StoredSession(account: account, token: token)
        generation += 1
        refreshing = nil
        stored = session
        loaded = true
        await persist(session)
        return account
    }

    public func signOut() async {
        generation += 1
        refreshing?.cancel()
        refreshing = nil
        stored = nil
        loaded = true
        await tokenStore.clear()
    }

    /// An authorized call: refreshes an expiring token first, and once more after the Cloud turns the
    /// token away (401, or a 403 about the token). Only a call that is still turned away with a freshly
    /// renewed token is a confirmed `authenticationRequired`. Throws `CloudError` for every non-2xx status.
    /// Never signs out: the saved session stays until the reader signs out or in again.
    @discardableResult
    public func send(_ endpoint: Endpoint) async throws -> (Data, HTTPURLResponse) {
        let token = try await validToken()
        var (data, response) = try await perform(endpoint, bearer: token.accessToken)
        if Self.rejectsToken(response, data) {
            let fresh = try await refresh(from: token)
            (data, response) = try await perform(endpoint, bearer: fresh.accessToken)
            if Self.rejectsToken(response, data) { throw CloudError.authenticationRequired }
        }
        try Self.check(response, data)
        return (data, response)
    }

    /// The Cloud's ways of saying "not with that token": 401, and 403 with a token error
    /// (seen live 2026-11-03: `error_code` 222, "Wrong token format" / "Invalid refresh token").
    static func rejectsToken(_ response: HTTPURLResponse, _ data: Data) -> Bool {
        if response.statusCode == 401 { return true }
        guard response.statusCode == 403, let body = try? WireDecoder.loose(data) else { return false }
        let code = body["error_code"]?.int
        let message = body["error_msg"]?.string?.lowercased() ?? ""
        return code == 222 || message == "wrong token format" || message == "invalid refresh token"
    }

    /// The current access token, refreshed if it is about to expire. For URLs that need it in a query.
    public func accessToken() async throws -> String { try await validToken().accessToken }

    // MARK: - Internals

    /// A nil load is retried on the next call: before first unlock the Keychain reads as empty,
    /// and that must not look like a sign-out for the rest of the process.
    private func loadIfNeeded() async {
        guard !loaded, stored == nil else { return }
        let generationBefore = generation
        let session = await tokenStore.load()
        guard generation == generationBefore, !loaded else { return }
        stored = session
        loaded = session != nil
    }

    private func persist(_ session: StoredSession) async {
        do {
            try await tokenStore.save(session)
            persistenceError = nil
        } catch {
            persistenceError = error
        }
    }

    /// Makes sure `serverClockOffset` reflects the server before a timestamp is sent. Costs one
    /// unauthenticated request per launch; any response carries a `Date` header.
    public func syncClock() async {
        guard !clockKnown else { return }
        _ = try? await perform(.get("/user"), bearer: nil)
    }

    private func validToken() async throws -> CloudToken {
        await loadIfNeeded()
        guard let token = stored?.token else { throw CloudError.notSignedIn }
        if token.expiresAt.timeIntervalSince(now()) > Self.refreshMargin { return token }
        return try await refresh(from: token)
    }

    private func refresh(from old: CloudToken) async throws -> CloudToken {
        if let refreshing { return try await refreshing.value }
        if let current = stored?.token, current.accessToken != old.accessToken,
           current.expiresAt.timeIntervalSince(now()) > Self.refreshMargin { return current }
        let task = Task { try await self.performRefresh(old) }
        refreshing = task
        defer { if refreshing == task { refreshing = nil } }
        return try await task.value
    }

    /// Renews the token. A renewal the Cloud turns away is asked once more before it counts: only two
    /// refusals in a row are a confirmed `authenticationRequired`. Even then the saved session (account and
    /// tokens) is kept, so the app keeps his name, his shelf and his place, and asks him to sign in again;
    /// only `signOut()` forgets it. A failure that isn't a refusal (offline, a 5xx, a cancelled call)
    /// changes nothing.
    private func performRefresh(_ old: CloudToken) async throws -> CloudToken {
        let startedIn = generation
        guard let refreshToken = old.refreshToken, var session = stored else {
            throw CloudError.authenticationRequired
        }
        let endpoint = Endpoint(method: "POST", path: "/auth/renew-token",
                                body: .form(["grant_type": "refresh_token", "refresh_token": refreshToken]))
        var (data, response) = try await perform(endpoint, bearer: old.accessToken)
        guard generation == startedIn else { throw CloudError.notSignedIn }
        if Task.isCancelled { throw CancellationError() }
        if [400, 401, 403].contains(response.statusCode) {
            // Once more before believing it: a refusal can be a hiccup (two renewals racing, a proxy).
            (data, response) = try await perform(endpoint, bearer: old.accessToken)
            guard generation == startedIn else { throw CloudError.notSignedIn }
            if Task.isCancelled { throw CancellationError() }
            if [400, 401, 403].contains(response.statusCode) { throw CloudError.authenticationRequired }
        }
        try Self.check(response, data)
        var token = try WireDecoder.token(data, now: now())
        if token.refreshToken == nil { token.refreshToken = refreshToken }
        session.token = token
        stored = session
        await persist(session)
        // The write above may have landed after a newer sign-in's: re-assert whatever is current.
        guard generation == startedIn else {
            // Signed out (or in again) while saving: undo our write unless a newer session owns the store.
            if let newer = stored { await persist(newer) } else { await tokenStore.clear() }
            throw CloudError.notSignedIn
        }
        return token
    }

    private func perform(_ endpoint: Endpoint, bearer: String?) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await transport.send(endpoint.request(base: base, bearer: bearer))
            if let header = response.value(forHTTPHeaderField: "Date"), let serverDate = Self.httpDate(header) {
                serverClockOffset = serverDate.timeIntervalSince(now()).rounded()
                clockKnown = true
            }
            return (data, response)
        } catch {
            throw Self.mapTransportError(error)
        }
    }

    /// URLSession failures as `CloudError` (cancellation passes through).
    static func mapTransportError(_ error: Error) -> Error {
        switch error {
        case let error as CloudError: return error
        case let error as URLError:
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost, .dataNotAllowed,
                 .internationalRoamingOff:
                return CloudError.offline
            case .cancelled: return CancellationError()
            default: return CloudError.network(error.localizedDescription)
            }
        default: return error
        }
    }

    static func check(_ response: HTTPURLResponse, _ data: Data) throws {
        switch response.statusCode {
        case 200..<300: return
        case 401: throw CloudError.authenticationRequired
        case 404: throw CloudError.notFound
        case 429:
            throw CloudError.rateLimited(retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
        case 500..<600: throw CloudError.server(status: response.statusCode)
        default:
            let message = (try? WireDecoder.loose(data))?["error_msg"]?.string
            throw CloudError.http(status: response.statusCode, message: message)
        }
    }

    static func httpDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: s)
    }
}
