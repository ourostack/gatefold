import Foundation
import GatefoldCloud
import os

/// Counts-only telemetry for book downloads, so a download that fails on a reader's phone tells us
/// where and why (P0, 2026-11-13: "can you see the error? if not, you gotta add telemetry").
///
/// It sends stages, status codes, error domains and codes, and yes/no facts. Never a title, author,
/// file name, hash, link, email or error message. The install is a random ID that names no one.
/// Off in DEBUG builds, UI tests and the fake Cloud; on in TestFlight and release builds.
final class GatefoldTelemetry: @unchecked Sendable {
    static let shared = GatefoldTelemetry()
    static let distinctIDKey = "GatefoldTelemetryInstallID"

    struct Configuration: Equatable {
        var apiKey: String
        var captureURL: URL
    }

    let configuration: Configuration?
    private let defaults: UserDefaults
    private let send: @Sendable (URLRequest) -> Void
    private let log = Logger(subsystem: "bot.ouro.gatefold", category: "telemetry")

    init(configuration: Configuration? = GatefoldTelemetry.loadConfiguration(),
         defaults: UserDefaults = .standard,
         send: @escaping @Sendable (URLRequest) -> Void = { request in
             Task.detached(priority: .utility) { _ = try? await URLSession.shared.data(for: request) }
         }) {
        self.configuration = configuration
        self.defaults = defaults
        self.send = send
    }

    static func loadConfiguration(bundle: Bundle = .main) -> Configuration? {
        #if DEBUG
        return nil
        #else
        if LaunchOptions.isUITest || LaunchOptions.fakeCloud { return nil }
        guard let key = (bundle.object(forInfoDictionaryKey: "GatefoldPostHogKey") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }
        return Configuration(apiKey: key, captureURL: URL(string: "https://us.i.posthog.com/i/v0/e/")!)
        #endif
    }

    /// Hands every download report to PostHog. Call once at launch.
    func start() {
        guard configuration != nil else { return }
        DownloadReports.shared.sink = { [weak self] report in self?.capture(report) }
    }

    func capture(_ report: DownloadReport) {
        capture("gatefold_download", properties: Self.properties(of: report))
    }

    /// The properties sent for one download. Only fixed names, numbers and booleans.
    static func properties(of report: DownloadReport) -> [String: Value] {
        var p: [String: Value] = [
            "outcome": .string(report.stage == nil ? "ok" : "failed"),
            "stage": .string(report.stage?.rawValue ?? "done"),
            "had_listed_link": .bool(report.hadListedLink),
            "refetched": .bool(report.refetched),
            "attempts": .int(report.attempts),
            "check": .string(report.check.rawValue),
            "format": .string(report.format),
            "is_drm": .bool(report.isDRM),
            "reused_local_copy": .bool(report.reusedLocalCopy),
        ]
        if let v = report.httpStatus { p["http_status"] = .int(v) }
        if let v = report.errorDomain { p["error_domain"] = .string(v) }
        if let v = report.errorCode { p["error_code"] = .int(v) }
        if let v = report.errorKind { p["error_kind"] = .string(v) }
        if let v = report.sizeMatched { p["size_matched"] = .bool(v) }
        return p
    }

    enum Value: Encodable, Equatable {
        case string(String), int(Int), bool(Bool)
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case let .string(v): try c.encode(v)
            case let .int(v): try c.encode(v)
            case let .bool(v): try c.encode(v)
            }
        }
    }

    private struct Payload: Encodable {
        let api_key: String
        let event: String
        let distinct_id: String
        let properties: [String: Value]
        let timestamp: String
    }

    func capture(_ event: String, properties: [String: Value]) {
        guard let configuration else { return }
        var props = properties
        let info = Bundle.main.infoDictionary
        props["app"] = .string("gatefold")
        props["app_version"] = .string(info?["CFBundleShortVersionString"] as? String ?? "?")
        props["app_build"] = .string(info?["CFBundleVersion"] as? String ?? "?")
        props["os_version"] = .string(ProcessInfo.processInfo.operatingSystemVersionString)
        props["$process_person_profile"] = .bool(false)
        let payload = Payload(api_key: configuration.apiKey, event: event, distinct_id: distinctID(),
                              properties: props, timestamp: ISO8601DateFormatter().string(from: Date()))
        guard let body = try? JSONEncoder().encode(payload) else { return }
        var request = URLRequest(url: configuration.captureURL)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        log.info("telemetry \(event, privacy: .public) stage=\(String(describing: properties["stage"]), privacy: .public)")
        send(request)
    }

    private func distinctID() -> String {
        if let id = defaults.string(forKey: Self.distinctIDKey) { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: Self.distinctIDKey)
        return id
    }
}
