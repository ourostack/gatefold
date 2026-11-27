import Foundation
import GatefoldCloud
import os
import UIKit

/// Counts-only telemetry for book downloads and reading-place sync, so a download that fails or a place
/// that never reaches the e-reader tells us where and why (P0, 2026-11-13: "can you see the error? if not,
/// you gotta add telemetry"; 2026-11-20: the InkPad didn't pick up where Gatefold left off).
///
/// It sends stages, status codes, error domains and codes, and yes/no facts. Never a title, author,
/// file name, hash, link, email or error message. The install is a random ID, and PostHog is told not to place the event by IP.
/// Off in DEBUG builds, UI tests and the fake Cloud; on in TestFlight and release builds.
final class GatefoldTelemetry: @unchecked Sendable {
    static let shared = GatefoldTelemetry()
    static let distinctIDKey = "GatefoldTelemetryInstallID"
    /// Events from a moment the app can't send in (iOS ending its background time), sent at the next launch or return.
    static let deferredKey = "GatefoldTelemetryDeferred"
    static let deferredLimit = 20

    struct Configuration: Equatable {
        var apiKey: String
        var captureURL: URL
    }

    let configuration: Configuration?
    private let defaults: UserDefaults
    private let send: @Sendable (URLRequest) -> Void
    private let log = Logger(subsystem: "bot.ouro.gatefold", category: "telemetry")
    private let lock = NSLock()
    private var _appPhase = "active"

    /// The scene's phase (`active`, `inactive`, `background`), sent with each place event.
    var appPhase: String {
        get { lock.withLock { _appPhase } }
        set { lock.withLock { _appPhase = newValue } }
    }

    init(configuration: Configuration? = GatefoldTelemetry.loadConfiguration(),
         defaults: UserDefaults = .standard,
         send: @escaping @Sendable (URLRequest) -> Void = GatefoldTelemetry.sendWithBackgroundTime) {
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

    /// Sends a request with its own background time: a place sent as the app leaves reports from the
    /// background, and iOS would otherwise suspend the app before the report goes out.
    static let sendWithBackgroundTime: @Sendable (URLRequest) -> Void = { request in
        Task { @MainActor in
            let finish = BackgroundTaskEnd()
            finish.task = UIApplication.shared.beginBackgroundTask(withName: "Telemetry") { finish.end() }
            _ = try? await URLSession.shared.data(for: request)
            finish.end()
        }
    }

    /// Hands every download and place report to PostHog, and sends what was kept for later. Call once at launch.
    func start() {
        guard configuration != nil else { return }
        DownloadReports.shared.sink = { [weak self] report in self?.capture(report) }
        PlaceReports.shared.sink = { [weak self] report in self?.capture(report) }
        sendDeferred()
    }

    func capture(_ report: PlaceReport) {
        capture(Self.eventName(of: report), properties: Self.properties(of: report, phase: appPhase))
    }

    static func eventName(of report: PlaceReport) -> String {
        report.direction == .push ? "gatefold_place_push" : "gatefold_place_pull"
    }

    /// The properties sent for one place send or fetch. Only fixed names, numbers and booleans: never a
    /// title, hash, pointer, CFI, email or text.
    static func properties(of report: PlaceReport, phase: String) -> [String: Value] {
        var p: [String: Value] = [
            "result": .string(report.result.rawValue),
            "app_phase": .string(phase),
            "has_cfi": .bool(report.hasCFI),
        ]
        if let v = report.reason { p["reason"] = .string(v.rawValue) }
        if let v = report.httpStatus { p["http_status"] = .int(v) }
        if let v = report.errorDomain { p["error_domain"] = .string(v) }
        if let v = report.errorCode { p["error_code"] = .int(v) }
        if let v = report.errorKind { p["error_kind"] = .string(v) }
        if let v = report.remoteSource { p["remote_source"] = .string(v) }
        if let v = report.remoteNewer { p["remote_newer"] = .bool(v) }
        if let v = report.remoteAhead { p["remote_ahead"] = .bool(v) }
        if let v = report.hadKeptPassword { p["had_kept_password"] = .bool(v) }
        if let v = report.reSignInErrorKind { p["resign_in_error_kind"] = .string(v) }
        if report.direction == .push {
            p["trigger"] = .string(report.trigger.rawValue)
            p["sign_in_renewed"] = .bool(report.signInRenewed)
            p["signed_in_again"] = .bool(report.signedInAgain)
            p["sign_in_expired"] = .bool(report.signInExpired)
            p["background_expired"] = .bool(report.reason == .backgroundExpired)
            p["attempts"] = .int(report.attempts)
            if let v = report.ageSeconds { p["seconds_since_turn"] = .int(bucket(v)) }
            if let v = report.queued { p["queued"] = .int(v) }
        } else {
            p["sign_in_expired"] = .bool(report.signInExpired)
        }
        return p
    }

    private struct Deferred: Codable {
        let event: String
        let properties: [String: Value]
    }

    /// Keeps a place report to send at the next launch or return to the app: for a moment when nothing
    /// can be sent (iOS ending the background time). Keeps the latest `deferredLimit`.
    func captureLater(_ report: PlaceReport, phase: String = "background") {
        guard configuration != nil else { return }
        var kept = (defaults.data(forKey: Self.deferredKey)).flatMap { try? JSONDecoder().decode([Deferred].self, from: $0) } ?? []
        kept.append(Deferred(event: Self.eventName(of: report), properties: Self.properties(of: report, phase: phase)))
        if kept.count > Self.deferredLimit { kept.removeFirst(kept.count - Self.deferredLimit) }
        defaults.set(try? JSONEncoder().encode(kept), forKey: Self.deferredKey)
    }

    /// Sends what `captureLater` kept, once.
    func sendDeferred() {
        guard configuration != nil, let data = defaults.data(forKey: Self.deferredKey) else { return }
        defaults.removeObject(forKey: Self.deferredKey)
        for event in (try? JSONDecoder().decode([Deferred].self, from: data)) ?? [] {
            capture(event.event, properties: event.properties)
        }
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

    /// How the shelf's arrival note ended: timed out, closed, Read, or replaced by another arrival.
    enum NoteEnd: String { case timed, closed, read, replaced }

    /// The arrival note's end, as counts only: how it ended and whether it offered Read, never its words or books.
    static func noteProperties(end: NoteEnd, hadRead: Bool) -> [String: Value] {
        ["ended": .string(end.rawValue), "had_read": .bool(hadRead)]
    }

    /// Books coming in from outside the Cloud: which source, and how many were new, already on the shelf, taken by a
    /// PocketBook Cloud book, or refused. Counts and the source's fixed name only: never a title, file name or digest.
    static func addedProperties(source: LibraryBook.Source, result: LibraryStore.ImportResult) -> [String: Value] {
        ["source": .string(source.rawValue),
         "added": .int(result.added.count),
         "already_here": .int(result.alreadyHere.count - result.linkedToCloud),
         "linked_to_cloud": .int(result.linkedToCloud),
         "refused": .int(result.refused)]
    }

    static let buckets = [5, 15, 30, 60, 120, 300, 600, 1800, 3600]
    /// The smallest bucket above `seconds`; 3600 for an hour or more.
    static func bucket(_ seconds: TimeInterval) -> Int { buckets.first { seconds < Double($0) } ?? 3600 }

    /// Upper bounds, in milliseconds, for the time a page takes to show: fine below a second, coarse above.
    static let msBuckets = [250, 500, 1000, 2000, 4000, 8000, 16000, 32000, 64000]
    /// The smallest bucket above `ms`; 64000 for a minute or more.
    static func msBucket(_ ms: Int) -> Int { msBuckets.first { ms < $0 } ?? 64000 }

    /// A jump to a far page (scrubber, search, contents) as he saw it: how long from his tap until the new page
    /// had arrived beneath the veil, and until the veil lifted. Bucketed milliseconds and the kind of veil; nothing
    /// about the book or the place.
    static func jumpProperties(riffled: Bool, msToArrive: Int, msToLift: Int) -> [String: Value] {
        ["veil": .string(riffled ? "riffle" : "dim"),
         "ms_to_arrive": .int(msBucket(msToArrive)),
         "ms_to_lift": .int(msBucket(msToLift))]
    }

    /// A book's first page as he saw it: how long from his tap (or, behind the shelf, from the open) until it
    /// showed, and whether it had to be forced past a load that never finished.
    static func openProperties(msToFirstPage: Int, behindShelf: Bool, forced: Bool) -> [String: Value] {
        ["ms_to_first_page": .int(msBucket(msToFirstPage)),
         "behind_shelf": .bool(behindShelf),
         "forced": .bool(forced)]
    }

    private static func name(of state: DownloadState) -> String {
        switch state {
        case .cloudOnly: "cloud_only"
        case .downloading: "downloading"
        case .onDevice: "on_device"
        case .failed: "failed"
        }
    }

    enum Value: Codable, Equatable {
        case string(String), int(Int), bool(Bool)
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let v = try? c.decode(Bool.self) { self = .bool(v) }
            else if let v = try? c.decode(Int.self) { self = .int(v) }
            else { self = .string(try c.decode(String.self)) }
        }
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
        log.info("telemetry \(event, privacy: .public) stage=\(String(describing: properties["stage"] ?? properties["result"]), privacy: .public)")
        send(request)
    }

}
