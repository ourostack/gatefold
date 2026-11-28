import Foundation

/// How far a download has got: the fraction of the body received, from 0 to 1. Called from any thread, and only
/// while the server has said how long the body is.
public typealias DownloadProgress = @Sendable (Double) -> Void

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// Streams the body to `destination`, which must not exist yet.
    func download(_ request: URLRequest, to destination: URL) async throws -> HTTPURLResponse
    /// As `download(_:to:)`, telling `progress` how far it has got.
    func download(_ request: URLRequest, to destination: URL, progress: DownloadProgress?) async throws -> HTTPURLResponse
}

extension HTTPTransport {
    /// A transport that can't tell how far it has got says nothing until the download is done.
    public func download(_ request: URLRequest, to destination: URL, progress: DownloadProgress?) async throws -> HTTPURLResponse {
        try await download(request, to: destination)
    }
}

public struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    public init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    public func download(_ request: URLRequest, to destination: URL) async throws -> HTTPURLResponse {
        try await download(request, to: destination, progress: nil)
    }

    public func download(_ request: URLRequest, to destination: URL, progress: DownloadProgress?) async throws -> HTTPURLResponse {
        let watcher = progress.map(ProgressWatcher.init)
        let (temp, response) = try await session.download(for: request, delegate: watcher)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if (200..<300).contains(http.statusCode) {
            try FileManager.default.moveItem(at: temp, to: destination)
            watcher?.finished()
        } else {
            try? FileManager.default.removeItem(at: temp)
        }
        return http
    }
}

/// Watches one download task's progress and passes on its fraction while its length is known: forward only, and in
/// steps of a hundredth, so a fast transfer doesn't flood the shelf with redraws.
private final class ProgressWatcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: DownloadProgress
    private let lock = NSLock()
    private var observation: NSKeyValueObservation?
    private var last = 0.0

    init(_ report: @escaping DownloadProgress) { self.report = report }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        let observation = task.progress.observe(\.fractionCompleted) { [weak self, weak task] progress, _ in
            // Only the book's own body counts: a refusal's page (a stale link's 403) is no progress.
            guard !progress.isIndeterminate, let status = (task?.response as? HTTPURLResponse)?.statusCode,
                  (200..<300).contains(status) else { return }
            self?.pass(progress.fractionCompleted)
        }
        lock.withLock { self.observation = observation }
    }

    /// The body is in place: whole, whatever the last count said.
    func finished() {
        lock.withLock { observation?.invalidate(); observation = nil }
        pass(1)
    }

    private func pass(_ fraction: Double) {
        let f = min(max(fraction, 0), 1)
        let forward: Bool = lock.withLock {
            guard f > last, f == 1 || f - last >= 0.01 else { return false }
            last = f
            return true
        }
        if forward { report(f) }
    }
}

public enum CloudError: Error, Sendable, Equatable {
    case notSignedIn
    /// No PocketBook Cloud account exists for that email.
    case noAccount
    case invalidCredentials
    /// The refresh token stopped working. Sign in again.
    case authenticationRequired
    case notFound
    case rateLimited(retryAfter: TimeInterval?)
    case server(status: Int)
    case http(status: Int, message: String?)
    case offline
    case network(String)
    /// PocketBook's web bundle no longer exposes the OAuth client pair where we look.
    case clientCredentialsUnavailable
    /// The official iOS reader crashes on EPUBs under 4 KiB, so we refuse to upload them.
    case fileTooSmall(bytes: Int64)
    case checksumMismatch
    /// The Cloud accepted a delete but still lists the book.
    case deleteNotApplied
    case unexpectedResponse(String)

    /// Worth retrying later without user action.
    public var isTransient: Bool {
        switch self {
        case .offline, .network, .rateLimited, .server: true
        case let .http(status, _): status == 408
        default: false
        }
    }
}

/// One Cloud call, relative to the API base.
public struct Endpoint: Sendable {
    public enum Version: String, Sendable { case v1_0 = "v1.0", v1_1 = "v1.1" }
    public enum Body: Sendable {
        case none
        case json(Data)
        case form([String: String])
        case raw(Data, contentType: String)
        /// An empty body that still declares a form content type. `fileops/delete` silently
        /// ignores the request without it.
        case emptyForm
    }

    public var method: String
    public var path: String
    public var query: [String: String]
    public var body: Body
    public var version: Version

    public init(method: String, path: String, query: [String: String] = [:], body: Body = .none, version: Version = .v1_0) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
        self.version = version
    }

    public static func get(_ path: String, query: [String: String] = [:]) -> Endpoint {
        Endpoint(method: "GET", path: path, query: query)
    }

    func request(base: URL, bearer: String?) -> URLRequest {
        var components = URLComponents(url: base.appendingPathComponent("api/\(version.rawValue)"), resolvingAgainstBaseURL: false)!
        components.percentEncodedPath += path.hasPrefix("/") ? path : "/" + path
        if !query.isEmpty {
            components.percentEncodedQuery = query.sorted { $0.key < $1.key }
                .map { "\(Self.formEncode($0.key))=\(Self.formEncode($0.value))" }.joined(separator: "&")
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        switch body {
        case .none: break
        case let .json(data):
            request.httpBody = data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        case let .form(fields):
            request.httpBody = Data(Self.form(fields).utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        case let .raw(data, contentType):
            request.httpBody = data
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        case .emptyForm:
            request.httpBody = Data()
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    static func form(_ fields: [String: String]) -> String {
        fields.sorted { $0.key < $1.key }.map { "\(formEncode($0.key))=\(formEncode($0.value))" }.joined(separator: "&")
    }

    static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// Percent-encodes one path segment (book file names contain spaces, apostrophes, slashes).
    static func pathSegment(_ s: String) -> String { formEncode(s) }
}
