import Foundation

/// The OAuth client pair PocketBook's web app ships in its public JavaScript.
public struct ClientCredentials: Sendable, Hashable, Codable {
    public var id: String
    public var secret: String
    public init(id: String, secret: String) {
        self.id = id
        self.secret = secret
    }

    /// The pair PocketBook's web app shipped in its public JavaScript until November 2026, also
    /// published in open-source clients (PaddeK/pocketorbit src/pocketbook.ts). The Cloud still
    /// accepts it (live check 2026-11-13). The new web app keeps its secret on its server, so when
    /// discovery finds nothing, sign-in uses this.
    public static let pocketBookWeb = ClientCredentials(id: "qNAx1RDb", secret: "K3YYSjCgDJNoWKdGVOyO1mrROp3MMZqqRNXNXTmh")
}

public protocol ClientCredentialsProvider: Sendable {
    /// `refresh: true` drops any cached pair (after the Cloud rejects it).
    func credentials(refresh: Bool) async throws -> ClientCredentials
}

public struct StaticCredentials: ClientCredentialsProvider {
    let value: ClientCredentials
    public init(_ value: ClientCredentials) { self.value = value }
    public func credentials(refresh: Bool) async throws -> ClientCredentials { value }
}

/// Reads the client pair from the web app's bundle at runtime, so the app follows PocketBook if
/// they rotate it. The pair is the two string constants that follow the `/api/v1.1/` base URL in
/// the bundle's config module. When the bundle is gone or changes shape (PocketBook's new web app,
/// November 2026, has none), it falls back to `fallback`.
public actor WebBundleCredentials: ClientCredentialsProvider {
    let transport: HTTPTransport
    let site: URL
    let fallback: ClientCredentials?
    private var cached: ClientCredentials?

    public init(transport: HTTPTransport, site: URL = URL(string: "https://cloud.pocketbook.digital")!, cached: ClientCredentials? = nil,
                fallback: ClientCredentials? = .pocketBookWeb) {
        self.transport = transport
        self.site = site
        self.cached = cached
        self.fallback = fallback
    }

    /// Fetching the bundle is slow (it's megabytes of JavaScript), so callers who arrive while a
    /// fetch is running share it instead of starting another.
    private var fetching: Task<ClientCredentials, Error>?

    public func credentials(refresh: Bool) async throws -> ClientCredentials {
        if !refresh, let cached { return cached }
        if !refresh, let fetching { return try await fetching.value }
        let task = Task { try await fetch() }
        fetching = task
        defer { if fetching == task { fetching = nil } }
        let pair = try await task.value
        cached = pair
        return pair
    }

    private func fetch() async throws -> ClientCredentials {
        do {
            let (html, _) = try await transport.send(URLRequest(url: site.appendingPathComponent("browser/")))
            let page = String(decoding: html, as: UTF8.self)
            guard let script = Self.firstMatch(#"/browser/static/js/main\.[0-9a-f]+\.chunk\.js"#, in: page) else {
                throw CloudError.clientCredentialsUnavailable
            }
            let (js, _) = try await transport.send(URLRequest(url: site.appendingPathComponent(String(script.dropFirst()))))
            guard let pair = Self.extract(from: String(decoding: js, as: UTF8.self)) else { throw CloudError.clientCredentialsUnavailable }
            return pair
        } catch CloudError.clientCredentialsUnavailable {
            guard let fallback else { throw CloudError.clientCredentialsUnavailable }
            return fallback
        } catch let error as CloudError {
            throw error
        } catch {
            throw CloudError.offline
        }
    }

    static func extract(from bundle: String) -> ClientCredentials? {
        let pattern = #"/api/v1\.1/"\),[A-Za-z_$][\w$]*="([A-Za-z0-9]{4,64})",[A-Za-z_$][\w$]*="([A-Za-z0-9]{16,256})""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: bundle, range: NSRange(bundle.startIndex..., in: bundle)),
              let id = Range(m.range(at: 1), in: bundle), let secret = Range(m.range(at: 2), in: bundle) else { return nil }
        return ClientCredentials(id: String(bundle[id]), secret: String(bundle[secret]))
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let r = text.range(of: pattern, options: .regularExpression) else { return nil }
        return String(text[r])
    }
}
