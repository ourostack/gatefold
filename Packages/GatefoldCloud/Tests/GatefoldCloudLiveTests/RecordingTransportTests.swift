#if os(macOS)
import Foundation
import Testing
@testable import GatefoldCloud

/// Runs offline in every `swift test`: what the canary's capture keeps, and what it never keeps.
@Suite("Recording transport")
struct RecordingTransportTests {
    struct Canned: HTTPTransport {
        let body: String
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        func download(_ request: URLRequest, to destination: URL) async throws -> HTTPURLResponse {
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        }
    }

    func capture(_ url: String, body: String) async throws -> String {
        let dir = tempDirectory()
        let transport = RecordingTransport(inner: Canned(body: body), directory: dir)
        _ = try await transport.send(URLRequest(url: URL(string: url)!))
        let file = try #require(try FileManager.default.contentsOfDirectory(atPath: dir.path).first)
        return try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
    }

    @Test func keepsTheShapeAndLosesTheSecrets() async throws {
        let text = try await capture(
            "https://cloud.pocketbook.digital/api/v1.1/auth/login/pocketbook_de?username=a%40b.com&client_secret=s3cret&fast_hash=56f8",
            body: #"{"access_token":"eyJabc","refresh_token":"r3fresh","expires_in":3600,"email":"a@b.com","#
                + #""download_link":"https://x/y?payload=p4y&signature=s1g","note":"mail me at c@d.org","md5_hash":"HpCKqamClMQ9Aai870mKVQ=="}"#)
        for secret in ["eyJabc", "r3fresh", "a@b.com", "a%40b.com", "s3cret", "p4y", "s1g", "c@d.org"] {
            #expect(!text.contains(secret), "\(secret) leaked into the capture")
        }
        #expect(text.contains("expires_in") && text.contains("3600"))
        #expect(text.contains("HpCKqamClMQ9Aai870mKVQ=="), "non-secret values stay, so a format change shows")
        #expect(text.contains(#""fast_hash" : "56f8""#))
    }

    @Test func keepsOnlyTheSizeOfTheWebAppsPages() async throws {
        let text = try await capture("https://cloud.pocketbook.com/_nuxt/app.js", body: #"const clientSecret="s3cret""#)
        #expect(!text.contains("s3cret"))
        #expect(text.contains("bytes"))
    }
}
#endif
