import Foundation
import UIKit
import GatefoldCore

/// Reads OPDS catalogs and downloads their books: a page when the reader opens it, a search when they ask,
/// a book when they tap Get. Never in the background: Project Gutenberg's site is for people and blocks automated tools.
/// A user name and password, when the catalog has one, answers the server's own challenge (Basic, or
/// Digest as the calibre content server asks over plain http), and is never sent to anyone else.
struct CatalogClient: Sendable {
    struct Credential: Sendable, Equatable {
        var user: String
        var password: String
        /// The catalog they belong to. Only a challenge from its own scheme, host and port is answered, so a
        /// cover or book the catalog links to on another server never sees them, and an https catalog's
        /// password never goes out over plain http.
        var catalog: URL

        func belongs(to space: URLProtectionSpace) -> Bool {
            guard let scheme = catalog.scheme?.lowercased(), let host = catalog.host()?.lowercased() else { return false }
            let port = catalog.port ?? (scheme == "https" ? 443 : 80)
            return space.protocol?.lowercased() == scheme && space.host.lowercased() == host && space.port == port
        }
    }

    enum Failure: Error, Equatable {
        /// The catalog asked for a user name and password, or turned away the ones it was given.
        case needsSignIn
        /// Plain http to a server that isn't on this network, which iOS doesn't allow.
        case needsHTTPS
        case notACatalog
        /// What a Get link sent back wasn't an EPUB: most often a web page asking to sign in there.
        case notABook
        case offline
        case unreachable
        case refused(status: Int)

        var words: String {
            switch self {
            case .needsSignIn: "This catalog asks for a user name and password."
            case .needsHTTPS: "Gatefold reaches catalogs over https. For a server at home, use its address on your network, such as 192.168.1.20:8083 or calibre.local."
            case .notACatalog: "That address doesn't lead to an OPDS catalog."
            case .notABook: "The catalog sent a web page instead of the book. It may want you to sign in on its website."
            case .offline: "You're offline. Gatefold will reach the catalog once you're connected."
            case .unreachable: "Gatefold couldn't reach this catalog. Check the address, then try again."
            case let .refused(status): "The catalog couldn't send that (error \(status))."
            }
        }
    }

    var session: URLSession = .shared

    /// One page of the catalog.
    func feed(at url: URL, credential: Credential? = nil) async throws -> CatalogFeed {
        let (data, response) = try await get(url, credential: credential)
        // After a redirect, the page's own links are relative to where it was found.
        do { return try CatalogParser.parse(data: data, from: response.url ?? url) } catch { throw Failure.notACatalog }
    }

    /// Where the catalog's results for `query` are, reading its OpenSearch description first when that's
    /// how it searches; nil for a blank query.
    func searchURL(_ search: CatalogSearch, for query: String, credential: Credential? = nil) async throws -> URL? {
        var search = search
        if case let .description(url) = search {
            let (data, response) = try await get(url, credential: credential)
            guard let template = OpenSearchDescription.parse(data, from: response.url ?? url) else { throw Failure.notACatalog }
            search = template
        }
        return search.url(for: query)
    }

    /// Downloads a book into a hand-off folder (tmp/Incoming/<id>/), which the shelf empties once it has
    /// taken the book in.
    func download(_ acquisition: CatalogAcquisition, title: String, credential: Credential? = nil) async throws -> URL {
        let (temp, response) = try await run { try await session.download(for: request(acquisition.url), delegate: SignIn(credential)) }
        defer { try? FileManager.default.removeItem(at: temp) }
        try check(response)
        guard Self.isZip(temp) else { throw Failure.notABook }
        let folder = URL.temporaryDirectory.appending(path: "Incoming/\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appending(path: Self.fileName(for: title))
        try FileManager.default.moveItem(at: temp, to: target)
        return target
    }

    /// A book's cover picture from the catalog, asked for as every request is (its password answers only its own
    /// server), decoded no bigger than `fitting` pixels (calibre-web's thumbnail link is the full-size cover), or nil
    /// when there's none to show: a page, a refusal, or a file over 4 MB.
    func cover(at url: URL, credential: Credential? = nil, fitting: CGSize = CGSize(width: 300, height: 450)) async -> UIImage? {
        guard let got = try? await get(url, credential: credential, accept: "image/*"), got.0.count <= Self.coverLimit,
              let image = UIImage(data: got.0) else { return nil }
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        guard pixels.width > fitting.width || pixels.height > fitting.height else { return await image.byPreparingForDisplay() ?? image }
        let shrink = min(fitting.width / pixels.width, fitting.height / pixels.height)
        let size = CGSize(width: (pixels.width * shrink).rounded(), height: (pixels.height * shrink).rounded())
        return await image.byPreparingThumbnail(ofSize: size) ?? image
    }

    static let coverLimit = 4 << 20

    /// An EPUB is a ZIP archive, which starts "PK\u{3}\u{4}"; a web page or an error message doesn't.
    static func isZip(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data([0x50, 0x4B, 0x03, 0x04])
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

    private func get(_ url: URL, credential: Credential?, accept: String? = nil) async throws -> (Data, URLResponse) {
        var request = request(url)
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        let (data, response) = try await run { try await session.data(for: request, delegate: SignIn(credential)) }
        try check(response)
        return (data, response)
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
            CatalogClient.answer(challenge.protectionSpace, failures: challenge.previousFailureCount, with: credential)
        }
    }

    /// How a sign-in challenge is answered: a password challenge from the catalog's own server once, with
    /// its credential, and never again once that was turned away (the server's 401 then comes back as the
    /// response); a password challenge from anywhere else, never; anything else, such as the server's
    /// certificate, the system's way.
    static func answer(_ space: URLProtectionSpace, failures: Int, with credential: Credential?) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let method = space.authenticationMethod
        guard method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest else {
            return (.performDefaultHandling, nil)
        }
        guard let credential, failures == 0, credential.belongs(to: space) else { return (.rejectProtectionSpace, nil) }
        return (.useCredential, URLCredential(user: credential.user, password: credential.password, persistence: .none))
    }
}
