#if os(macOS)
import CryptoKit
import Foundation
import Testing
@testable import GatefoldCloud

/// Contract tests against the real PocketBook Cloud. Off unless `GATEFOLD_LIVE=1`.
///
/// Credentials come from the login keychain (`gatefold-pbcloud-test-<n>`, account = email) and are
/// never printed. Account 1 holds Frankenstein for the web-reader round trip; account 2 is scratch.
enum Live {
    static let enabled = ProcessInfo.processInfo.environment["GATEFOLD_LIVE"] == "1"
    static let frankenstein = "56f8619536655be4a1541a40c5702d32"

    struct Account {
        let email: String
        let password: String
    }

    static func account(_ n: Int) throws -> Account {
        let service = "gatefold-pbcloud-test-\(n)"
        let attributes = try run("/usr/bin/security", ["find-generic-password", "-s", service])
        guard let range = attributes.range(of: #""acct"<blob>="([^"]+)""#, options: .regularExpression) else {
            throw LiveError.missing(service)
        }
        let email = String(attributes[range].dropFirst(#""acct"<blob>=""#.count).dropLast())
        let password = try run("/usr/bin/security", ["find-generic-password", "-s", service, "-w"]).trimmingCharacters(in: .newlines)
        return Account(email: email, password: password)
    }

    static func cloud(directory: URL = tempDirectory()) -> PocketBookCloud {
        PocketBookCloud(configuration: .init(storageDirectory: directory, autoFlush: false), tokenStore: InMemoryTokenStore())
    }

    static func signedIn(_ n: Int) async throws -> PocketBookCloud {
        let account = try account(n)
        let cloud = cloud()
        let store = try #require(try await cloud.stores(forEmail: account.email).first { $0.usesPassword })
        _ = try await cloud.signIn(email: account.email, password: account.password, store: store)
        return cloud
    }

    /// Unzips a downloaded EPUB and builds the mapper the app would use.
    static func mapper(forEPUB file: URL) throws -> PositionMapper {
        let root = tempDirectory()
        _ = try run("/usr/bin/unzip", ["-q", "-o", file.path, "-d", root.path])
        let container = try String(contentsOf: root.appendingPathComponent("META-INF/container.xml"), encoding: .utf8)
        guard let r = container.range(of: #"full-path="[^"]+""#, options: .regularExpression) else { throw LiveError.missing("container.xml") }
        let opfPath = String(container[r].dropFirst(#"full-path=""#.count).dropLast())
        let spine = try SpineMap(opf: Data(contentsOf: root.appendingPathComponent(opfPath)), opfPath: opfPath)
        return PositionMapper(spine: spine) { href in try Data(contentsOf: root.appendingPathComponent(href)) }
    }

    static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw LiveError.tool(tool, process.terminationStatus) }
        return String(decoding: data, as: UTF8.self)
    }

    static func log(_ line: String) { print("LIVE \(line)") }
}

enum LiveError: Error { case missing(String), tool(String, Int32) }

func tempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("gatefold-live-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("Live PocketBook Cloud", .serialized, .enabled(if: Live.enabled))
struct LiveCloudTests {
    @Test func discoversClientCredentialsAndSignsIn() async throws {
        let account = try Live.account(1)
        let cloud = Live.cloud()
        let stores = try await cloud.stores(forEmail: account.email)
        #expect(stores.contains { $0.alias == "pocketbook_de" })
        await #expect(throws: CloudError.noAccount) { _ = try await cloud.stores(forEmail: "gatefold-nobody-\(UUID().uuidString.prefix(8))@example.com") }
        await #expect(throws: CloudError.invalidCredentials) {
            _ = try await cloud.signIn(email: account.email, password: "wrong-\(UUID().uuidString)", store: stores[0])
        }
        let signedIn = try await cloud.signIn(email: account.email, password: account.password, store: stores[0])
        #expect(signedIn.email.lowercased() == account.email.lowercased())
        #expect(signedIn.mailInAddress?.hasSuffix("@pbsync.com") == true)
    }

    @Test func refreshesAnExpiredToken() async throws {
        let account = try Live.account(1)
        let tokens = InMemoryTokenStore()
        let first = PocketBookCloud(configuration: .init(storageDirectory: tempDirectory(), autoFlush: false), tokenStore: tokens)
        let store = try #require(try await first.stores(forEmail: account.email).first)
        _ = try await first.signIn(email: account.email, password: account.password, store: store)
        var saved = try #require(await tokens.load())
        let oldAccess = saved.token.accessToken
        saved.token.expiresAt = Date(timeIntervalSinceNow: -60)
        await tokens.save(saved)

        let restored = PocketBookCloud(configuration: .init(storageDirectory: tempDirectory(), autoFlush: false), tokenStore: tokens)
        _ = try await restored.library()
        let renewed = try #require(await tokens.load())
        #expect(renewed.token.accessToken != oldAccess)
        #expect(renewed.token.expiresAt > Date())
    }

    @Test func listsTheLibraryAndDownloadsAVerifiedCopy() async throws {
        let cloud = try await Live.signedIn(1)
        let books = try await cloud.library()
        let book = try #require(books.first { $0.fastHash == Live.frankenstein })
        Live.log("library: \(books.count) books; \(book.title) cover=\(book.coverURL != nil) md5=\(book.md5Base64 ?? "nil")")
        #expect(book.title.contains("Frankenstein"))
        #expect(book.coverURL != nil)
        let file = try await cloud.download(book)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try PocketBookCloud.md5Base64(of: file) == book.md5Base64)
    }

    /// Cross-client (a): what PocketBook's web reader (or whoever wrote last) left, resolved in the EPUB.
    @Test func readsTheCurrentPosition() async throws {
        let cloud = try await Live.signedIn(1)
        let book = try #require(try await cloud.library().first { $0.fastHash == Live.frankenstein })
        let position = try #require(try await cloud.remotePosition(for: book))
        let mapper = try Live.mapper(forEPUB: try await cloud.download(book))
        let location = await mapper.location(for: position)
        Live.log("remote position: pointer=\(position.pointer ?? "nil") cfi=\(position.cfi ?? "nil") percent=\(position.totalProgression) source=\(position.source) updated=\(PBDate.string(position.updated))")
        Live.log("resolves to: href=\(location?.href ?? "nil") progression=\(location?.progression.map { String(format: "%.4f", $0) } ?? "nil") text=\"\(location?.textAfter?.prefix(80) ?? "")\"")
        #expect(position.cfi != nil)
        #expect(location != nil, "the Cloud's CFI resolves in the book")
        if let expected = ProcessInfo.processInfo.environment["GATEFOLD_LIVE_EXPECT_CFI"] {
            #expect(position.cfi == expected)
        }
    }

    /// Cross-client (b): write a position the web reader should then open at.
    /// `GATEFOLD_LIVE_TARGET=<spine idref>:<progression>` picks the place (default: Chapter 5, 30 %).
    @Test func writesAPositionOtherClientsCanOpen() async throws {
        let cloud = try await Live.signedIn(1)
        let book = try #require(try await cloud.library().first { $0.fastHash == Live.frankenstein })
        let mapper = try Live.mapper(forEPUB: try await cloud.download(book))
        let target = (ProcessInfo.processInfo.environment["GATEFOLD_LIVE_TARGET"] ?? "item13:0.3").split(separator: ":")
        let spine = mapper.spine
        let index = try #require(spine.items.firstIndex { $0.idref == String(target[0]) })
        let progression = Double(target[1]) ?? 0
        let location = BookLocation(href: spine.items[index].href, progression: progression,
                                    totalProgression: (Double(index) + progression) / Double(spine.items.count))
        let position = try #require(await mapper.position(for: location, at: Date()))
        await cloud.push(position, for: book)
        await cloud.flushOutbox()
        #expect(await cloud.pendingChanges() == 0)

        let back = try #require(try await cloud.remotePosition(for: book))
        let landed = await mapper.location(for: back)
        Live.log("wrote: cfi=\(position.cfi ?? "nil") percent=\(position.totalProgression)")
        Live.log("read back: pointer=\(back.pointer ?? "nil") source=\(back.source) updated=\(PBDate.string(back.updated)) text=\"\(landed?.textAfter?.prefix(80) ?? "")\"")
        #expect(back.cfi == position.cfi)
        #expect(back.source == .gatefold)
        #expect(Int((back.totalProgression * 100).rounded()) == Int((position.totalProgression * 100).rounded(.up)))
    }

    /// The End's "Mark Finished on InkPad": a 100 % position plus `read_status` "read". Account 2 is
    /// scratch; the book goes back to 5 % and "reading" afterwards.
    @Test func marksABookFinished() async throws {
        let cloud = try await Live.signedIn(2)
        let book = try #require(try await cloud.library().first { $0.fastHash == Live.frankenstein })
        Live.log("before: status=\(book.readStatus ?? "nil") percent=\(book.readPercent.map(String.init) ?? "nil")")
        await cloud.push(ReadingPosition(cfi: nil, progression: 1, totalProgression: 1, updated: Date()), for: book)
        await cloud.markRead(book)
        await cloud.flushOutbox()
        #expect(await cloud.pendingChanges() == 0)
        let finished = try #require(try await cloud.library().first { $0.fastHash == Live.frankenstein })
        Live.log("after mark: status=\(finished.readStatus ?? "nil") percent=\(finished.readPercent.map(String.init) ?? "nil")")
        #expect(finished.readStatus == "read")
        #expect(finished.readPercent == 100)

        await cloud.push(ReadingPosition(cfi: nil, progression: 0.05, totalProgression: 0.05, updated: Date()), for: book)
        await cloud.flushOutbox()
        _ = try? await cloud.session.send(Endpoint(method: "POST", path: "/books/status/\(Endpoint.pathSegment(book.name))/reading"))
        let restored = try #require(try await cloud.library().first { $0.fastHash == Live.frankenstein })
        Live.log("restored: status=\(restored.readStatus ?? "nil") percent=\(restored.readPercent.map(String.init) ?? "nil")")
        #expect(restored.readStatus == "reading")
    }

    @Test func annotationsRoundTrip() async throws {
        let cloud = try await Live.signedIn(2)
        let book = try #require(try await cloud.library().first { $0.fastHash == Live.frankenstein }, "account 2 holds a copy of Frankenstein")
        let marker = "gatefold live \(UUID().uuidString.prefix(8))"
        let created = Date().addingTimeInterval(-5)
        let highlight = CloudAnnotation.highlight(begin: "#epubcfi(/6/16[item9]!/4/4/1:0)", end: "#epubcfi(/6/16[item9]!/4/4/1:24)",
                                                  text: marker, color: .cyan, at: created)
        await cloud.save(highlight, for: book)
        await cloud.flushOutbox()
        #expect(await cloud.pendingChanges() == 0)

        var mine = try #require(try await cloud.annotations(for: book).first { $0.quotation?.value.text == marker })
        #expect(mine.uuid != nil)
        #expect(mine.color?.value == .cyan)
        Live.log("created note \(mine.uuid ?? "")")

        mine.note = .init("edited by Gatefold", updated: Date().addingTimeInterval(-1))
        await cloud.save(mine, for: book)
        await cloud.flushOutbox()
        let edited = try #require(try await cloud.annotations(for: book).first { $0.uuid == mine.uuid })
        #expect(edited.note?.value == "edited by Gatefold")
        #expect(edited.kind.value == .highlight)

        await cloud.deleteAnnotation(edited, for: book)
        await cloud.flushOutbox()
        #expect(try await cloud.annotations(for: book).contains { $0.uuid == mine.uuid } == false)
    }

    @Test func uploadsAndDeletesAPublicDomainEPUB() async throws {
        let cloud = try await Live.signedIn(2)
        let file = try await aliceEPUB()
        let md5 = try PocketBookCloud.md5Base64(of: file)
        if let leftover = try await cloud.library().first(where: { $0.md5Base64 == md5 }) { try await cloud.delete(leftover) }

        let uploaded = try await cloud.upload(fileAt: file)
        Live.log("uploaded: fast_hash=\(uploaded.fastHash) title=\(uploaded.title) bytes=\(uploaded.bytes)")
        #expect(try await cloud.library().contains { $0.fastHash == uploaded.fastHash })
        let copy = try await cloud.download(uploaded)
        #expect(try PocketBookCloud.md5Base64(of: copy) == md5)

        try await cloud.delete(uploaded)
        #expect(try await cloud.library().contains { $0.fastHash == uploaded.fastHash } == false)
        await #expect(throws: CloudError.notFound) { _ = try await cloud.remotePosition(for: uploaded) }
    }

    /// Alice's Adventures in Wonderland (Project Gutenberg #11). `GATEFOLD_LIVE_EPUB` overrides.
    private func aliceEPUB() async throws -> URL {
        if let path = ProcessInfo.processInfo.environment["GATEFOLD_LIVE_EPUB"] { return URL(fileURLWithPath: path) }
        let (data, _) = try await URLSession.shared.data(from: URL(string: "https://www.gutenberg.org/cache/epub/11/pg11.epub")!)
        let file = tempDirectory().appendingPathComponent("Alice's Adventures in Wonderland.epub")
        try data.write(to: file)
        return file
    }
}
#endif
