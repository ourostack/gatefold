import Foundation
import GatefoldCloud
import Testing
@testable import Gatefold

/// Download telemetry is counts-only: a fixed set of property names, and nothing that names a book or a reader.
struct GatefoldTelemetryTests {
    static let allowed: Set<String> = [
        "outcome", "stage", "had_listed_link", "refetched", "attempts", "check", "format", "is_drm",
        "reused_local_copy", "http_status", "link_status", "error_domain", "error_code", "error_kind", "size_matched",
    ]

    @Test func aFailedDownloadSendsOnlyItsStageAndCodes() {
        var report = DownloadReport(stage: .verify, httpStatus: 200, hadListedLink: true, refetched: true, attempts: 2,
                                    check: .md5, format: "epub", sizeMatched: true)
        report.note(CloudError.checksumMismatch)
        let p = GatefoldTelemetry.properties(of: report)
        #expect(Set(p.keys).isSubset(of: Self.allowed))
        #expect(p["outcome"] == .string("failed"))
        #expect(p["stage"] == .string("verify"))
        #expect(p["error_kind"] == .string("checksumMismatch"))
        #expect(p["http_status"] == .int(200))
    }

    @Test func anHTTPErrorKeepsItsStatusButNotItsMessage() {
        var report = DownloadReport(stage: .status)
        report.note(CloudError.http(status: 400, message: "Frankenstein.epub: payload should not be null"))
        let p = GatefoldTelemetry.properties(of: report)
        #expect(p["http_status"] == .int(400))
        #expect(!p.values.contains { if case let .string(s) = $0 { s.contains("Frankenstein") || s.contains("payload") } else { false } })
    }

    @Test func aDownloadThatWorkedSaysOK() {
        let p = GatefoldTelemetry.properties(of: DownloadReport(attempts: 1, check: .size))
        #expect(p["outcome"] == .string("ok"))
        #expect(p["stage"] == .string("done"))
    }

    @Test func nothingIsSentWithoutAConfiguration() {
        let sent = Box()
        let telemetry = GatefoldTelemetry(configuration: nil, send: { _ in sent.count += 1 })
        telemetry.capture(DownloadReport(stage: .transfer))
        #expect(sent.count == 0)
    }

    @Test func aConfiguredSenderPostsTheEventWithARandomInstallID() throws {
        let sent = Box()
        let defaults = try #require(UserDefaults(suiteName: "telemetry-test-\(UUID().uuidString)"))
        let telemetry = GatefoldTelemetry(configuration: .init(apiKey: "phc_test", captureURL: URL(string: "https://example.invalid/e/")!),
                                          defaults: defaults, send: { sent.requests.append($0) })
        telemetry.capture(DownloadReport(stage: .transfer))
        let body = try #require(sent.requests.first?.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["event"] as? String == "gatefold_download")
        #expect(UUID(uuidString: json["distinct_id"] as? String ?? "") != nil)
    }
}

private final class Box: @unchecked Sendable {
    var count = 0
    var requests: [URLRequest] = []
}
