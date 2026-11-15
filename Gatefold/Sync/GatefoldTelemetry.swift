import Foundation
import GatefoldCloud
import os

/// Counts-only telemetry for book downloads, so a download that fails on a reader's phone tells us
/// where and why (P0, 2026-11-13: "can you see the error? if not, you gotta add telemetry").
///
/// It sends stages, status codes, error domains and codes, and yes/no facts. Never a title, author,
/// file name, hash, link, email or error message. The install is a random ID, and PostHog is told not to place the event by IP.
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
        // Made once, before any download can race to make a second one.
        if configuration != nil, defaults.string(forKey: Self.distinctIDKey) == nil {
            defaults.set(UUID().uuidString, forKey: Self.distinctIDKey)
        }
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
        if let v = report.linkStatus { p["link_status"] = .int(v) }
        if let v = report.errorDomain { p["error_domain"] = .string(v) }
        if let v = report.errorCode { p["error_code"] = .int(v) }
        if let v = report.errorKind { p["error_kind"] = .string(v) }
        if let v = report.sizeMatched { p["size_matched"] = .bool(v) }
        return p
    }

    /// A tap on a book that isn't on the device yet, with what the shelf showed. A tap that never reaches the
    /// Cloud (a download already under way, or a book with no Cloud copy) sends no `gatefold_download`, so
    /// without this a stuck download would look like no tap at all. Seconds are bucketed: the bucket's upper bound.
    static func tapProperties(state: DownloadState, hasCloudCopy: Bool, secondsDownloading: TimeInterval?) -> [String: Value] {
        var p: [String: Value] = ["state": .string(name(of: state)), "has_cloud_copy": .bool(hasCloudCopy)]
        if let s = secondsDownloading { p["seconds_downloading"] = .int(bucket(s)) }
        return p
    }

    static let buckets = [5, 15, 30, 60, 120, 300, 600, 1800, 3600]
    /// The smallest bucket above `seconds`; 3600 for an hour or more.
    static func bucket(_ seconds: TimeInterval) -> Int { buckets.first { seconds < Double($0) } ?? 3600 }

    private static func name(of state: DownloadState) -> String {
        switch state {
        case .cloudOnly: "cloud_only"
        case .downloading: "downloading"
        case .onDevice: "on_device"
        case .failed: "failed"
        }
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
        let distinctID = defaults.string(forKey: Self.distinctIDKey) ?? "unknown"
        var props = properties
        let info = Bundle.main.infoDictionary
        props["app"] = .string("gatefold")
        props["app_version"] = .string(info?["CFBundleShortVersionString"] as? String ?? "?")
        props["app_build"] = .string(info?["CFBundleVersion"] as? String ?? "?")
        props["os_version"] = .string(ProcessInfo.processInfo.operatingSystemVersionString)
        props["$process_person_profile"] = .bool(false)
        props["$geoip_disable"] = .bool(true)
        let payload = Payload(api_key: configuration.apiKey, event: event, distinct_id: distinctID,
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

}
