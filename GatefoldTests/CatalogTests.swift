import Foundation
import GatefoldCore
import Synchronization
import Testing
@testable import Gatefold

/// Browsing an OPDS catalog and getting a book from it, against a stand-in server: each test answers from
/// its own made-up host, so tests running side by side never see each other's pages.
@MainActor @Suite struct CatalogTests {
    private let host = "catalog-\(UUID().uuidString.prefix(8).lowercased()).test"
    private var base: URL { URL(string: "https://\(host)")! }
    private var client: CatalogClient { CatalogClient(session: StandInServer.session) }

    nonisolated private static let feed = """
    <?xml version="1.0" encoding="utf-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <id>urn:test:root</id><title>Home library</title>
      <link rel="search" type="application/opensearchdescription+xml" href="/opds/search.xml"/>
      <link rel="next" type="application/atom+xml;profile=opds-catalog" href="/opds?page=2"/>
      <entry>
        <id>urn:test:frankenstein</id><title>Frankenstein</title><author><name>Mary Shelley</name></author>
        <link rel="http://opds-spec.org/acquisition" type="application/epub+zip" href="/books/1/frankenstein.epub"/>
      </entry>
    </feed>
    """

    nonisolated private static let description = """
    <?xml version="1.0" encoding="UTF-8"?>
    <OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
      <ShortName>Home library</ShortName>
      <Url type="application/atom+xml;profile=opds-catalog" template="https://HOST/opds/search?q={searchTerms}"/>
    </OpenSearchDescription>
    """

    @Test func aPageIsReadAndItsBookArrivesWhereTheShelfTakesItFrom() async throws {
        let book = try Data(contentsOf: #require(Bundle.main.url(forResource: "frankenstein", withExtension: "epub")))
        StandInServer.answer(host) { request in
            switch request.url?.path() {
            case "/opds": (200, Data(Self.feed.utf8))
            case "/books/1/frankenstein.epub": (200, book)
            default: (404, Data())
            }
        }
        let feed = try await client.feed(at: base.appending(path: "opds"))
        #expect(feed.title == "Home library")
        #expect(feed.next == URL(string: "https://\(host)/opds?page=2"))
        let entry = try #require(feed.entries.first)
        #expect(entry.author == "Mary Shelley")
        let epub = try #require(entry.epub)
        #expect(epub.url == URL(string: "https://\(host)/books/1/frankenstein.epub"))

        let file = try await client.download(epub, title: entry.title)
        #expect(file.lastPathComponent == "Frankenstein.epub")
        #expect(try Data(contentsOf: file) == book)
        // In a hand-off folder, so the shelf deletes it once it has taken the book in.
        #expect(AppModel.isHandOffCopy(file))
    }

    @Test func eachWayACatalogCanSayNoIsToldApart() async throws {
        StandInServer.answer(host) { request in
            switch request.url?.path() {
            case "/locked": (401, Data())
            case "/forbidden": (403, Data())
            case "/gone": (404, Data())
            case "/web-page": (200, Data("<!doctype html><html><body>Hello</body></html>".utf8))
            default: (500, Data())
            }
        }
        await #expect(throws: CatalogClient.Failure.needsSignIn) { try await client.feed(at: base.appending(path: "locked")) }
        await #expect(throws: CatalogClient.Failure.needsSignIn) { try await client.feed(at: base.appending(path: "forbidden")) }
        await #expect(throws: CatalogClient.Failure.refused(status: 404)) { try await client.feed(at: base.appending(path: "gone")) }
        await #expect(throws: CatalogClient.Failure.notACatalog) { try await client.feed(at: base.appending(path: "web-page")) }
        let epub = CatalogAcquisition(url: base.appending(path: "locked"), mediaType: "application/epub+zip", rel: "http://opds-spec.org/acquisition", length: nil, title: nil)
        await #expect(throws: CatalogClient.Failure.needsSignIn) { try await client.download(epub, title: "Locked") }
    }

    @Test func searchReadsTheCatalogsOpenSearchDescriptionFirst() async throws {
        let host = host
        StandInServer.answer(host) { request in
            request.url?.path() == "/opds/search.xml" ? (200, Data(Self.description.replacingOccurrences(of: "HOST", with: host).utf8)) : (404, Data())
        }
        let search = CatalogSearch.description(base.appending(path: "opds/search.xml"))
        let url = try await client.searchURL(search, for: "mary shelley")
        #expect(url == URL(string: "https://\(host)/opds/search?q=mary%20shelley"))
        #expect(try await client.searchURL(search, for: "   ") == nil)
    }

    @Test func aPasswordIsGivenOnceAndOnlyWhenAPasswordIsAskedFor() {
        let credential = CatalogClient.Credential(user: "reader", password: "public-domain")
        let first = CatalogClient.answer(NSURLAuthenticationMethodHTTPDigest, failures: 0, with: credential)
        #expect(first.0 == .useCredential)
        #expect(first.1?.user == "reader")
        #expect(first.1?.persistence == URLCredential.Persistence.none)
        #expect(CatalogClient.answer(NSURLAuthenticationMethodHTTPBasic, failures: 1, with: credential).0 == .rejectProtectionSpace)
        #expect(CatalogClient.answer(NSURLAuthenticationMethodHTTPBasic, failures: 0, with: nil).0 == .rejectProtectionSpace)
        #expect(CatalogClient.answer(NSURLAuthenticationMethodServerTrust, failures: 0, with: credential).0 == .performDefaultHandling)
    }

    @Test func anAddressIsReadTheWayItWasTyped() {
        #expect(CatalogClient.address("books.example.com/opds") == URL(string: "https://books.example.com/opds"))
        #expect(CatalogClient.address(" calibre.local:8080/opds ") == URL(string: "http://calibre.local:8080/opds"))
        #expect(CatalogClient.address("192.168.1.20:8083/opds") == URL(string: "http://192.168.1.20:8083/opds"))
        #expect(CatalogClient.address("nas:5000/opds") == URL(string: "http://nas:5000/opds"))
        #expect(CatalogClient.address("http://books.example.com/opds") == URL(string: "http://books.example.com/opds"))
        #expect(CatalogClient.address("ftp://books.example.com") == nil)
        #expect(CatalogClient.address("") == nil)
    }

    @Test func aTitleBecomesAFileNameTheFilesAppAccepts() {
        #expect(CatalogClient.fileName(for: "Pride and Prejudice: A Novel") == "Pride and Prejudice A Novel.epub")
        #expect(CatalogClient.fileName(for: "AC/DC\n\"Live\"") == "AC DC Live.epub")
        #expect(CatalogClient.fileName(for: " :/ ") == "Book.epub")
        #expect(CatalogClient.fileName(for: String(repeating: "a", count: 200)).count == 85)
    }

    @Test func yourCatalogsComeBackAfterARelaunchWithPasswordsOnlyInTheKeychain() throws {
        let root = URL.temporaryDirectory.appending(path: "catalogs-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let keychain = MemoryPasswords()
        let shelf = CatalogShelf(root: root, keychain: keychain)
        let home = shelf.add(name: " ", url: URL(string: "http://calibre.local:8080/opds")!, user: "reader", password: "public-domain")
        let free = shelf.add(name: "Club", url: URL(string: "https://club.example.org/opds")!, user: "", password: "ignored")
        #expect(home.name == "calibre.local")
        #expect(free.user == nil)

        let saved = try String(contentsOf: root.appending(path: "catalogs.json"), encoding: .utf8)
        #expect(!saved.contains("public-domain"))

        let relaunched = CatalogShelf(root: root, keychain: keychain)
        #expect(relaunched.own.map(\.id) == [home.id, free.id])
        #expect(relaunched.credential(for: home) == .init(user: "reader", password: "public-domain"))
        #expect(relaunched.credential(for: free) == nil)
        #expect(relaunched.all.prefix(2).map(\.id) == ["gutenberg", "standard-ebooks"])

        relaunched.remove(home)
        #expect(keychain.password(for: home.id) == nil)
        relaunched.forgetAll()
        #expect(CatalogShelf(root: root, keychain: keychain).own.isEmpty)
    }

    @Test func aCatalogIsSavedOnlyOnceItOpens() async throws {
        let root = URL.temporaryDirectory.appending(path: "catalog-draft-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let shelf = CatalogShelf(root: root, keychain: MemoryPasswords())
        StandInServer.answer(host) { request in
            request.url?.path() == "/opds" ? (200, Data(Self.feed.utf8)) : (404, Data())
        }
        let draft = CatalogDraft()
        draft.address = "https://\(host)/nothing-here"
        #expect(await draft.add(to: shelf, client: client) == nil)
        #expect(draft.problem == CatalogClient.Failure.refused(status: 404).words)
        #expect(shelf.own.isEmpty)

        draft.address = "ftp://\(host)/opds"
        #expect(await draft.add(to: shelf, client: client) == nil)
        #expect(draft.problem == "That isn't a web address.")

        draft.address = "https://\(host)/opds"
        let saved = try #require(await draft.add(to: shelf, client: client))
        #expect(draft.problem == nil)
        #expect(shelf.own == [saved])
    }

    @Test func aBookFromACatalogJoinsTheShelfSayingWhereItCameFrom() async throws {
        let root = URL.temporaryDirectory.appending(path: "catalog-arrival-\(UUID().uuidString)")
        let app = AppModel(sync: FakeSyncService(signedIn: false, latency: .zero), libraryRoot: root)
        let incoming = URL.temporaryDirectory.appending(path: "Incoming/\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        let file = incoming.appending(path: "Frankenstein.epub")
        try FileManager.default.copyItem(at: #require(Bundle.main.url(forResource: "frankenstein", withExtension: "epub")), to: file)

        let result = await app.receive([file], source: .catalog)
        let book = try #require(result.single)
        #expect(book.arrivalLabel == "From a catalog")
        #expect(!FileManager.default.fileExists(atPath: incoming.path))
    }
}

/// Catalog passwords kept in memory, as a test build has no Keychain.
final class MemoryPasswords: CatalogPasswords {
    private let kept = Mutex<[String: String]>([:])
    func set(_ password: String?, for id: String) { kept.withLock { $0[id] = password } }
    func password(for id: String) -> String? { kept.withLock { $0[id] } }
}

/// A stand-in OPDS server: answers each made-up host from the test that owns it.
final class StandInServer: URLProtocol {
    typealias Answer = @Sendable (URLRequest) -> (Int, Data)
    private static let answers = Mutex<[String: Answer]>([:])

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StandInServer.self]
        return URLSession(configuration: configuration)
    }()

    static func answer(_ host: String, with answer: @escaping Answer) {
        answers.withLock { $0[host] = answer }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host() else { return false }
        return answers.withLock { $0[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host(), let answer = Self.answers.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let (status, body) = answer(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "\(body.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
