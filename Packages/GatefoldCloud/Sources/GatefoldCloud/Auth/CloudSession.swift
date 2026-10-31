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
    let language: String

    private var stored: StoredSession?
    private var loaded = false
    private var refreshing: Task<CloudToken, Error>?
    /// Server time minus device time, from the latest `Date` header.
    public private(set) var serverClockOffset: TimeInterval = 0

    public init(transport: HTTPTransport, credentials: ClientCredentialsProvider, tokenStore: TokenStore,
                base: URL = CloudSession.defaultBase, language: String = "en", now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.credentials = credentials
        self.tokenStore = tokenStore
        self.base = base
        self.language = language
        self.now = now
    }

    public var account: CloudAccount? {
        get async {
            await loadIfNeeded()
            return stored?.account
        }
    }

    /// Device time translated to the server's clock.
    public func serverNow() -> Date { now().addingTimeInterval(serverClockOffset) }

    public func stores(forEmail email: String) async throws -> [CloudStore] {
        let creds = try await credentials.credentials(refresh: false)
        let endpoint = Endpoint.get("/auth/login", query: [
            "username": email.trimmingCharacters(in: .whitespacesAndNewlines),
            "client_id": creds.id, "client_secret": creds.secret, "language": language,
        ])
        let (data, response) = try await perform(endpoint, bearer: nil)
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
        let (data, response) = try await perform(endpoint, bearer: nil)
        if [400, 401, 403].contains(response.statusCode) { throw CloudError.invalidCredentials }
        try Self.check(response, data)
        let token = try WireDecoder.token(data, now: now())

        let (userData, userResponse) = try await perform(.get("/user"), bearer: token.accessToken)
        try Self.check(userResponse, userData)
        var account = try WireDecoder.account(userData, store: store)
        if account.email.isEmpty { account.email = email }
        let session = StoredSession(account: account, token: token)
        stored = session
        loaded = true
        try? await tokenStore.save(session)
        return account
    }

    public func signOut() async {
        refreshing?.cancel()
        refreshing = nil
        stored = nil
        loaded = true
        await tokenStore.clear()
    }

    /// An authorized call: refreshes an expiring token first, and once more after a 401.
    /// Throws `CloudError` for every non-2xx status.
    @discardableResult
    public func send(_ endpoint: Endpoint) async throws -> (Data, HTTPURLResponse) {
        let token = try await validToken()
        var (data, response) = try await perform(endpoint, bearer: token.accessToken)
        if response.statusCode == 401 {
            let fresh = try await refresh(from: token)
            (data, response) = try await perform(endpoint, bearer: fresh.accessToken)
            if response.statusCode == 401 { throw CloudError.authenticationRequired }
        }
        try Self.check(response, data)
        return (data, response)
    }

    /// The current access token, refreshed if it is about to expire. For URLs that need it in a query.
    public func accessToken() async throws -> String { try await validToken().accessToken }

    // MARK: - Internals

    private func loadIfNeeded() async {
        guard !loaded else { return }
        loaded = true
        if stored == nil { stored = await tokenStore.load() }
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
        defer { refreshing = nil }
        return try await task.value
    }

    private func performRefresh(_ old: CloudToken) async throws -> CloudToken {
        guard let refreshToken = old.refreshToken, var session = stored else {
            await signOut()
            throw CloudError.authenticationRequired
        }
        let endpoint = Endpoint(method: "POST", path: "/auth/renew-token",
                                body: .form(["grant_type": "refresh_token", "refresh_token": refreshToken]))
        let (data, response) = try await perform(endpoint, bearer: old.accessToken)
        if (400..<500).contains(response.statusCode) {
            await signOut()
            throw CloudError.authenticationRequired
        }
        try Self.check(response, data)
        var token = try WireDecoder.token(data, now: now())
        if token.refreshToken == nil { token.refreshToken = refreshToken }
        session.token = token
        stored = session
        try? await tokenStore.save(session)
        return token
    }

    private func perform(_ endpoint: Endpoint, bearer: String?) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await transport.send(endpoint.request(base: base, bearer: bearer))
            if let header = response.value(forHTTPHeaderField: "Date"), let serverDate = Self.httpDate(header) {
                serverClockOffset = serverDate.timeIntervalSince(now()).rounded()
            }
            return (data, response)
        } catch let error as CloudError {
            throw error
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost, .dataNotAllowed:
                throw CloudError.offline
            case .cancelled:
                throw CancellationError()
            default:
                throw CloudError.network(error.localizedDescription)
            }
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
