import Foundation
@testable import GatefoldCloud

/// A fake Cloud: answers each request from a list of routes and records what was sent.
actor ScriptedTransport: HTTPTransport {
    struct Response: Sendable {
        var status: Int
        var body: Data
        var headers: [String: String]
        static func json(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> Response {
            Response(status: status, body: Data(text.utf8), headers: headers.merging(["Content-Type": "application/json"]) { a, _ in a })
        }
        static func data(_ data: Data, status: Int = 200) -> Response { Response(status: status, body: data, headers: [:]) }
        static let ok = Response(status: 200, body: Data("OK".utf8), headers: ["Content-Type": "text/html"])
    }

    struct Route: Sendable {
        var method: String
        var pathContains: String
        var responses: [Response] // consumed in order; the last one repeats
    }

    struct Sent: Sendable {
        var method: String
        var url: URL
        var headers: [String: String]
        var body: Data?
        var path: String { url.path }
        var query: [String: String] {
            Dictionary(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map { ($0.name, $0.value ?? "") } ?? [], uniquingKeysWith: { a, _ in a })
        }
        var form: [String: String] {
            var c = URLComponents()
            c.percentEncodedQuery = String(decoding: body ?? Data(), as: UTF8.self)
            return Dictionary(c.queryItems?.map { ($0.name, $0.value ?? "") } ?? [], uniquingKeysWith: { a, _ in a })
        }
        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body ?? Data())) as? [String: Any] ?? [:] }
    }

    private var routes: [Route] = []
    private(set) var sent: [Sent] = []
    var offline = false
    var delay: Duration = .zero

    init(_ routes: [Route] = []) { self.routes = routes }

    func on(_ method: String, _ pathContains: String, _ responses: Response...) {
        routes.insert(Route(method: method, pathContains: pathContains, responses: responses), at: 0)
    }

    func setOffline(_ value: Bool) { offline = value }
    func setDelay(_ value: Duration) { delay = value }

    func requests(_ method: String, _ pathContains: String) -> [Sent] {
        sent.filter { $0.method == method && ($0.url.absoluteString.contains(pathContains)) }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let record = Sent(method: request.httpMethod ?? "GET", url: request.url!, headers: request.allHTTPHeaderFields ?? [:], body: request.httpBody)
        sent.append(record)
        if delay != .zero { try await Task.sleep(for: delay) }
        if offline { throw URLError(.notConnectedToInternet) }
        guard let i = routes.firstIndex(where: { $0.method == record.method && record.url.absoluteString.contains($0.pathContains) }) else {
            let r = HTTPURLResponse(url: record.url, statusCode: 404, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (Data(#"{"error_code":0,"error_msg":"Page not found."}"#.utf8), r)
        }
        let response = routes[i].responses.count > 1 ? routes[i].responses.removeFirst() : routes[i].responses[0]
        var headers = response.headers
        headers["Date"] = headers["Date"] ?? "Sat, 31 Oct 2026 22:00:00 GMT"
        let http = HTTPURLResponse(url: record.url, statusCode: response.status, httpVersion: nil, headerFields: headers)!
        return (response.body, http)
    }

    func download(_ request: URLRequest, to destination: URL) async throws -> HTTPURLResponse {
        let (data, response) = try await send(request)
        if (200..<300).contains(response.statusCode) { try data.write(to: destination) }
        return response
    }
}

/// A clock tests move by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date = utc("2026-10-31T22:00:00Z")) { current = start }
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

func testStore() -> CloudStore {
    CloudStore(alias: "pocketbook_de", name: "Pocketbook.de", shopID: "1", iconURL: nil, loggedBy: "password")
}

func tokenJSON(_ access: String, refresh: String? = "r1", expiresIn: Int = 7200) -> String {
    if let refresh { return #"{"access_token":"\#(access)","refresh_token":"\#(refresh)","token_type":"Bearer","expires_in":\#(expiresIn)}"# }
    return #"{"access_token":"\#(access)","token_type":"Bearer","expires_in":\#(expiresIn)}"#
}

func tempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("gatefold-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
