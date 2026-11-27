import Foundation
import GatefoldCore

/// Reads OPDS catalogs and downloads their books: a page when the reader opens it, a search when they ask,
/// a book when they tap Get. Never in the background, as Project Gutenberg asks of software that reads it.
/// A user name and password, when the catalog has one, answers the server's own challenge (Basic, or
/// Digest as the calibre content server asks over plain http), and is never sent to anyone else.
struct CatalogClient: Sendable {
    struct Credential: Sendable, Equatable {
        var user: String
        var password: String
    }

    enum Failure: Error, Equatable {
        /// The catalog asked for a user name and password, or turned away the ones it was given.
        case needsSignIn
        /// Plain http to a server that isn't on this network, which iOS doesn't allow.
        case needsHTTPS
        case notACatalog
        case offline
        case unreachable
        case refused(status: Int)

        var words: String {
            switch self {
            case .needsSignIn: "This catalog asks for a user name and password."
            case .needsHTTPS: "Gatefold reaches catalogs over https, or on your own network."
            case .notACatalog: "That address doesn't lead to an OPDS catalog."
            case .offline: "You're offline. Gatefold will reach the catalog once you're connected."
            case .unreachable: "Gatefold couldn't reach this catalog. Check the address, then try again."
            case let .refused(status): "The catalog couldn't send that (error \(status))."
            }
        }
    }

    var session: URLSession = .shared

    /// One page of the catalog.
    func feed(at url: URL, credential: Credential? = nil) async throws -> CatalogFeed {
        let data = try await get(url, credential: credential)
        do { return try CatalogParser.parse(data: data, from: url) } catch { throw Failure.notACatalog }
    }

    /// Where the catalog's results for `query` are, reading its OpenSearch description first when that's
    /// how it searches; nil for a blank query.
    func searchURL(_ search: CatalogSearch, for query: String, credential: Credential? = nil) async throws -> URL? {
        var search = search
        if case let .description(url) = search {
            let data = try await get(url, credential: credential)
            guard let template = OpenSearchDescription.parse(data, from: url) else { throw Failure.notACatalog }
            search = template
        }
        return search.url(for: query)
    }

    /// Downloads a book into a hand-off folder (tmp/Incoming/<id>/), which the shelf empties once it has
    /// taken the book in.
    func download(_ acquisition: CatalogAcquisition, title: String, credential: Credential? = nil) async throws -> URL {
        let (temp, response) = try await run { try await session.download(for: request(acquisition.url), delegate: SignIn(credential)) }
        try check(response)
        let folder = URL.temporaryDirectory.appending(path: "Incoming/\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appending(path: Self.fileName(for: title))
        try FileManager.default.moveItem(at: temp, to: target)
        return target
    }

    /// The book's title as a file name: what the shelf would show if its own metadata said nothing.
    static func fileName(for title: String) -> String {
        let unsafe = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters).union(.whitespacesAndNewlines)
        let words = title.components(separatedBy: unsafe).filter { !$0.isEmpty }.joined(separator: " ")
        return String((words.isEmpty ? "Book" : words).prefix(80)) + ".epub"
    }

    /// A catalog address as typed: one with no scheme is https, except a name or address on this network.
    static func address(_ typed: String) -> URL? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.contains("://") {
            guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else { return nil }
            return url
        }
        let host = text.split(separator: "/").first.map { $0.split(separator: ":").first.map(String.init) ?? "" } ?? ""
        let local = host.hasSuffix(".local") || !host.contains(".") || host.allSatisfy { $0.isNumber || $0 == "." }
        return URL(string: (local ? "http://" : "https://") + text)
    }

    private func get(_ url: URL, credential: Credential?) async throws -> Data {
        let (data, response) = try await run { try await session.data(for: request(url), delegate: SignIn(credential)) }
        try check(response)
        return data
    }

    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("application/atom+xml;profile=opds-catalog, application/opds+json;q=0.9, application/xml;q=0.8, */*;q=0.5",
                         forHTTPHeaderField: "Accept")
        return request
    }

    /// Turns the system's errors into the few the reader is told about; a cancellation stays one.
    private func run<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .appTransportSecurityRequiresSecureConnection: throw Failure.needsHTTPS
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: throw Failure.offline
            case .userAuthenticationRequired, .userCancelledAuthentication: throw Failure.needsSignIn
            default: throw Failure.unreachable
            }
        }
    }

    private func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300: return
        case 401, 403: throw Failure.needsSignIn
        default: throw Failure.refused(status: http.statusCode)
        }
    }

    /// Answers the server's sign-in challenge once with the catalog's own user name and password.
    private final class SignIn: NSObject, URLSessionTaskDelegate, Sendable {
        let credential: Credential?

        init(_ credential: Credential?) { self.credential = credential }

        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async
            -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            CatalogClient.answer(challenge.protectionSpace.authenticationMethod, failures: challenge.previousFailureCount, with: credential)
        }
    }

    /// How a sign-in challenge is answered: a password challenge once with the catalog's own credential,
    /// and never again once that was turned away (the server's 401 then comes back as the response);
    /// anything else, such as the server's certificate, the system's way.
    static func answer(_ method: String, failures: Int, with credential: Credential?) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest else {
            return (.performDefaultHandling, nil)
        }
        guard let credential, failures == 0 else { return (.rejectProtectionSpace, nil) }
        return (.useCredential, URLCredential(user: credential.user, password: credential.password, persistence: .none))
    }
}
