import Foundation
import Testing
@testable import GatefoldCloud

/// A book served in pieces, with its length, through a real URLSession.
final class PiecesProtocol: URLProtocol, @unchecked Sendable {
    static let body = Data(repeating: 3, count: 256 * 1024)
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "pieces.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": "\(Self.body.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let piece = Self.body.count / 8
        for i in 0..<8 {
            client?.urlProtocol(self, didLoad: Self.body.subdata(in: i * piece..<(i + 1) * piece))
            Thread.sleep(forTimeInterval: 0.02)
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite struct TransportProgressTests {
    @Test func aDownloadWithAKnownLengthReportsItsFractionAsItGoes() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PiecesProtocol.self]
        let transport = URLSessionTransport(session: URLSession(configuration: config))
        let destination = tempDirectory().appendingPathComponent("book.epub")
        let seen = Fractions()
        let response = try await transport.download(URLRequest(url: URL(string: "https://pieces.test/book.epub")!), to: destination) { seen.add($0) }
        #expect(response.statusCode == 200)
        #expect(try Data(contentsOf: destination) == PiecesProtocol.body)
        let fractions = seen.all
        #expect(fractions.contains { $0 > 0 && $0 < 1 }, "a fraction on the way: \(fractions)")
        #expect(fractions.last == 1, "ends whole: \(fractions)")
        #expect(fractions == fractions.sorted(), "never goes back: \(fractions)")
    }
}
