#if os(macOS)
import Foundation
@testable import GatefoldCloud

/// Records every exchange with the live cloud, redacted, so a red canary run shows what the cloud
/// actually said (gatefold#372). `scripts/cloud-canary.py` diffs the shapes against the unit-test
/// fixtures. One JSON file per exchange: method, path, the query's keys, status and the response body
/// with secrets, emails and signed-URL parameters removed. Downloaded files are not kept.
struct RecordingTransport: HTTPTransport {
    let inner: HTTPTransport
    let directory: URL
    private let counter = Counter()

    /// Query values worth keeping; every other value is redacted.
    static let plainQuery: Set<String> = ["include_metadata", "limit", "offset", "fast_hash", "client_id_type"]
    /// JSON keys whose values are secret or personal.
    static let secretKeys: Set<String> = ["access_token", "refresh_token", "client_secret", "client_id", "password",
                                          "email", "login", "vendor_login", "username", "first_name", "last_name",
                                          "full_name", "user_id", "provider_user_id", "mail_in", "send_to_email"]

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await inner.send(request)
            record(request, status: response.statusCode, body: data)
            return (data, response)
        } catch {
            record(request, status: nil, body: Data("\(error)".utf8))
            throw error
        }
    }

    func download(_ request: URLRequest, to destination: URL) async throws -> HTTPURLResponse {
        let response = try await inner.download(request, to: destination)
        record(request, status: response.statusCode, body: nil)
        return response
    }

    private func record(_ request: URLRequest, status: Int?, body: Data?) {
        guard let url = request.url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        var query: [String: String] = [:]
        for item in parts.queryItems ?? [] {
            query[item.name] = Self.plainQuery.contains(item.name) ? (item.value ?? "") : "<redacted>"
        }
        var entry: [String: Any] = ["method": request.httpMethod ?? "GET", "host": parts.host ?? "", "path": parts.path, "query": query]
        if let status { entry["status"] = status }
        if let body {
            if !parts.path.hasPrefix("/api/") {
                // The web app's pages and bundles (where the client pair once lived): only their size.
                entry["bytes"] = body.count
            } else if let json = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) {
                entry["body"] = Self.redact(json)
            } else {
                entry["text"] = Self.redact(String(decoding: body.prefix(2000), as: UTF8.self))
            }
        }
        let n = counter.next()
        let name = String(format: "%03d-%@-%@.json", n, entry["method"] as! String,
                          parts.path.replacingOccurrences(of: "/", with: "_").trimmingCharacters(in: CharacterSet(charactersIn: "_")))
        if let data = try? JSONSerialization.data(withJSONObject: entry, options: [.prettyPrinted, .sortedKeys]) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: directory.appendingPathComponent(String(name.prefix(120))))
        }
    }

    static func redact(_ value: Any, key: String? = nil) -> Any {
        if let key, secretKeys.contains(key), !(value is NSNull) { return "<redacted>" }
        switch value {
        case let dict as [String: Any]: return dict.reduce(into: [String: Any]()) { $0[$1.key] = redact($1.value, key: $1.key) }
        case let array as [Any]: return array.prefix(5).map { redact($0) }
        case let string as String: return redact(string)
        default: return value
        }
    }

    /// Emails go; a URL keeps its query's keys and loses their values.
    static func redact(_ string: String) -> String {
        var s = string.replacingOccurrences(of: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]+"#, with: "<email>", options: .regularExpression)
        s = s.replacingOccurrences(of: #"([?&][A-Za-z_]+)=[^&"\s]+"#, with: "$1=<redacted>", options: .regularExpression)
        s = s.replacingOccurrences(of: #"Bearer [A-Za-z0-9._-]+"#, with: "Bearer <redacted>", options: .regularExpression)
        return s
    }

    final class Counter: @unchecked Sendable {
        private var n = 0
        private let lock = NSLock()
        func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    }
}
#endif
