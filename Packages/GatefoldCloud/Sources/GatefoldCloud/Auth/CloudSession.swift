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
    /// After a re-sign-in the Cloud couldn't answer (429, 5xx, offline), no other is tried before
    /// `until`: a shelf downloading book after book must not send his password on every request
    /// while the Cloud is rate-limiting it. Calls in the meantime get the same error back.
    private var reSignInPause: (until: Date, wait: TimeInterval, error: Error)?
    static let reSignInFirstPause: TimeInterval = 60
    static let reSignInLongestPause: TimeInterval = 30 * 60
    /// The last Keychain write failure, if any. The session still works for this launch.
    public private(set) var persistenceError: Error?
    /// Server time minus device time, from the latest `Date` header.
    public private(set) var serverClockOffset: TimeInterval = 0
    /// Tokens renewed so far (by refresh token, or by signing in again), for telemetry.
    public private(set) var renewals = 0
    /// Of those, the ones that needed the kept password because the renewal was refused.
    public private(set) var reSignIns = 0
    /// How the latest try to sign in again with the kept password went, for telemetry.
    public private(set) var lastReSignIn: ReSignInNote?

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
    /// 2026-11-13). The password only twice: a wrong one costs every attempt against the Cloud's
    /// per-account login limit (429 "Too many login attempts"). The lookup flaps longer (seen live
    /// 2026-11-15: eight 404s in a row for a real account), so it is asked six times, waiting a little
    /// longer each time (1, 2, 3, 4, 5 seconds).
    static let lookupAttempts = 6
    static let passwordAttempts = 2

    private func performSignInCall(_ endpoint: Endpoint, attempts: Int, backoff: Bool = false,
                                   refusedWhen refused: (HTTPURLResponse) -> Bool) async throws -> (Data, HTTPURLResponse) {
        var attempt = 1
        while true {
            let (data, response) = try await perform(endpoint, bearer: nil)
            guard refused(response), attempt < attempts else { return (data, response) }
            try await sleep(.seconds(backoff ? attempt : 1))
            attempt += 1
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
        let (data, response) = try await performSignInCall(endpoint, attempts: Self.lookupAttempts, backoff: true) { $0.statusCode == 404 }
        if response.statusCode == 404 { throw CloudError.noAccount }
        try Self.check(response, data)
        return try WireDecoder.stores(data)
    }

    /// The password grant: a fresh token for this email and password, or `invalidCredentials`.
    private func passwordGrant(email: String, password: String, store: CloudStore) async throws -> CloudToken {
        let creds = try await credentials.credentials(refresh: false)
        let endpoint = Endpoint(method: "POST", path: "/auth/login/\(Endpoint.pathSegment(store.alias))", body: .form([
            "shop_id": store.shopID, "username": email.trimmingCharacters(in: .whitespacesAndNewlines), "password": password,
            "client_id": creds.id, "client_secret": creds.secret, "grant_type": "password", "language": language,
        ]))
        let (data, response) = try await performSignInCall(endpoint, attempts: Self.passwordAttempts) { $0.statusCode == 403 }
        if [400, 401, 403].contains(response.statusCode) { throw CloudError.invalidCredentials }
        try Self.check(response, data)
        return try WireDecoder.token(data, now: now())
    }

    public func signIn(email: String, password: String, store: CloudStore) async throws -> CloudAccount {
        let token = try await passwordGrant(email: email, password: password, store: store)

        // The token is what signs him in; `/user` only fills in details. If it stops answering in a
        // shape we know, he is still signed in, under the address he typed.
        let typed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let (userData, userResponse) = try await perform(.get("/user"), bearer: token.accessToken)
        var account: CloudAccount
        do {
            try Self.check(userResponse, userData)
            account = try WireDecoder.account(userData, store: store, email: typed)
        } catch CloudError.notFound {
            CloudDrift.shared.note("/user: 404; signed in without the account's details")
            account = CloudAccount(email: typed, store: store)
        } catch is WireError {
            CloudDrift.shared.note("/user: an answer we can't read; signed in without the account's details")
            account = CloudAccount(email: typed, store: store)
        } catch is DecodingError {
            CloudDrift.shared.note("/user: not JSON; signed in without the account's details")
            account = CloudAccount(email: typed, store: store)
        }
        if account.email.isEmpty { account.email = email }
        let session = StoredSession(account: account, token: token, password: password, login: typed)
        generation += 1
        reSignInPause = nil
        refreshing = nil
        stored = session
        loaded = true
        await persist(session)
        return account
    }

    public func signOut() async {
        generation += 1
        reSignInPause = nil
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

    /// Renews the token. A renewal the Cloud turns away is asked once more before it counts: two
    /// refusals in a row mean the refresh token is dead (the Cloud rotates it on every renewal and
    /// revokes the whole family when an old one is reused; seen live 2026-11-15). Then the app signs
    /// him in again on its own with the password kept in the Keychain. Only when there is no kept
    /// password, or the Cloud refuses it, is that a confirmed `authenticationRequired`. Even then the
    /// saved session (account and tokens) is kept, so the app keeps his name, his shelf and his place,
    /// and asks him to sign in again; only `signOut()` forgets it. A failure that isn't a refusal
    /// (offline, a 5xx, a cancelled call) changes nothing.
    private func performRefresh(_ old: CloudToken) async throws -> CloudToken {
        let startedIn = generation
        guard var session = stored else { throw CloudError.authenticationRequired }
        guard let refreshToken = old.refreshToken else { return try await signInAgain(session, startedIn: startedIn) }
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
            if [400, 401, 403].contains(response.statusCode) { return try await signInAgain(session, startedIn: startedIn) }
        }
        try Self.check(response, data)
        var token = try WireDecoder.token(data, now: now())
        if token.refreshToken == nil { token.refreshToken = refreshToken }
        session.token = token
        let kept = try await keep(session, startedIn: startedIn)
        renewals += 1
        return kept
    }

    /// The Cloud answers about one correct password in three with 403 error 1204, the same answer a wrong
    /// one gets (seen live 2026-11-13, gatefold#457), so one refused re-sign-in proves nothing. Two in a
    /// row, at least a minute apart, are taken as a changed password: four tries against the Cloud's
    /// per-account login limit at most.
    static let reSignInRefusalsBeforeForgetting = 2

    /// Signs in again with the kept password, once, after the Cloud refused to renew the token.
    /// A refusal keeps the password and pauses (the call gets `rateLimited`, so it is tried again later).
    /// After `reSignInRefusalsBeforeForgetting` refusals in a row the password is forgotten, so a changed
    /// password never runs into the Cloud's login limit on every launch; he signs in by hand and the new
    /// one is kept.
    private func signInAgain(_ session: StoredSession, startedIn: Int) async throws -> CloudToken {
        do {
            let token = try await trySigningInAgain(session, startedIn: startedIn)
            noteReSignIn(hadKeptPassword: true, "ok")
            return token
        } catch let failure as ReSignInFailure {
            noteReSignIn(hadKeptPassword: session.password != nil, failure.kind)
            throw failure.error
        } catch {
            noteReSignIn(hadKeptPassword: session.password != nil, (error as? CloudError)?.kind ?? String(describing: type(of: error)))
            throw error
        }
    }

    private func noteReSignIn(hadKeptPassword: Bool, _ kind: String) {
        lastReSignIn = ReSignInNote(tries: (lastReSignIn?.tries ?? 0) + 1, hadKeptPassword: hadKeptPassword, errorKind: kind)
    }

    /// A re-sign-in that ended for a reason worth its own name in telemetry.
    private struct ReSignInFailure: Error {
        let kind: String
        let error: Error
    }

    private func trySigningInAgain(_ session: StoredSession, startedIn: Int) async throws -> CloudToken {
        guard let password = session.password else {
            throw ReSignInFailure(kind: "no_kept_password", error: CloudError.authenticationRequired)
        }
        if let pause = reSignInPause, now() < pause.until { throw ReSignInFailure(kind: "paused", error: pause.error) }
        var session = session
        do {
            session.token = try await passwordGrant(email: session.login ?? session.account.email, password: password, store: session.account.store)
        } catch CloudError.invalidCredentials {
            guard generation == startedIn else { throw CloudError.notSignedIn }
            let refusals = (session.refusedReSignIns ?? 0) + 1
            guard refusals >= Self.reSignInRefusalsBeforeForgetting else {
                session.refusedReSignIns = refusals
                _ = try? await keep(session, startedIn: startedIn)
                let wait = Self.reSignInFirstPause
                let error = CloudError.rateLimited(retryAfter: wait)
                reSignInPause = (now().addingTimeInterval(wait), wait, error)
                throw ReSignInFailure(kind: "refused_kept", error: error)
            }
            session.password = nil
            session.refusedReSignIns = nil
            _ = try? await keep(session, startedIn: startedIn)
            throw ReSignInFailure(kind: "refused_forgotten", error: CloudError.authenticationRequired)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard generation == startedIn else { throw CloudError.notSignedIn }
            var wait = reSignInPause.map { min($0.wait * 2, Self.reSignInLongestPause) } ?? Self.reSignInFirstPause
            if case CloudError.rateLimited(let retryAfter?) = error { wait = max(wait, retryAfter) }
            reSignInPause = (now().addingTimeInterval(wait), wait, error)
            throw error
        }
        reSignInPause = nil
        guard generation == startedIn else { throw CloudError.notSignedIn }
        if Task.isCancelled { throw CancellationError() }
        session.refusedReSignIns = nil
        let kept = try await keep(session, startedIn: startedIn)
        renewals += 1
        reSignIns += 1
        return kept
    }

    /// Makes `session` current and saves it, unless he signed out or in again meanwhile.
    private func keep(_ session: StoredSession, startedIn: Int) async throws -> CloudToken {
        guard generation == startedIn else { throw CloudError.notSignedIn }
        stored = session
        await persist(session)
        // The write above may have landed after a newer sign-in's: re-assert whatever is current.
        guard generation == startedIn else {
            // Signed out (or in again) while saving: undo our write unless a newer session owns the store.
            if let newer = stored { await persist(newer) } else { await tokenStore.clear() }
            throw CloudError.notSignedIn
        }
        return session.token
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

/// How one try to sign in again with the kept password went: counts and fixed names only, never the password.
public struct ReSignInNote: Sendable, Equatable {
    /// Tries so far this launch, this one included.
    public var tries: Int
    /// A password was kept to sign in again with (false: a session saved before gatefold#412 kept none).
    public var hadKeptPassword: Bool
    /// `ok`, `no_kept_password`, `paused`, `refused_kept` (refused once, kept), `refused_forgotten`
    /// (refused again, forgotten), or the error's short name.
    public var errorKind: String

    public init(tries: Int, hadKeptPassword: Bool, errorKind: String) {
        self.tries = tries
        self.hadKeptPassword = hadKeptPassword
        self.errorKind = errorKind
    }
}
