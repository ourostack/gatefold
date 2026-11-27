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

    /// Every copy sends the same client ID, so no report can be told apart by phone, and App Privacy has no Device ID.
    @Test func everyCopySendsTheSameClientIDAndKeepsNoneOfItsOwn() throws {
        var ids: [String] = []
        for _ in 0..<2 {
            let sent = Box()
            let suite = "telemetry-test-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            let telemetry = GatefoldTelemetry(configuration: .init(apiKey: "phc_test", captureURL: URL(string: "https://example.invalid/e/")!),
                                              defaults: defaults, send: { sent.requests.append($0) })
            telemetry.capture(DownloadReport(stage: .transfer))
            let body = try #require(sent.requests.first?.httpBody)
            let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["event"] as? String == "gatefold_download")
            ids.append(json["distinct_id"] as? String ?? "")
            #expect(defaults.persistentDomain(forName: suite)?.isEmpty ?? true)
        }
        #expect(ids == [GatefoldTelemetry.sharedClientID, GatefoldTelemetry.sharedClientID])
    }

    /// TestFlight builds kept a random install ID; the first launch after this forgets it.
    @Test func theRandomInstallIDOlderBuildsKeptIsForgotten() throws {
        let defaults = try #require(UserDefaults(suiteName: "telemetry-test-\(UUID().uuidString)"))
        defaults.set(UUID().uuidString, forKey: "GatefoldTelemetryInstallID")
        _ = GatefoldTelemetry(configuration: nil, defaults: defaults, send: { _ in })
        #expect(defaults.string(forKey: "GatefoldTelemetryInstallID") == nil)
    }
}

/// A tap on a book not on the device says what the shelf showed, so a tap that never reached the Cloud still counts.
struct GatefoldDownloadTapTelemetryTests {
    static let allowed: Set<String> = ["state", "has_cloud_copy", "seconds_downloading"]

    @Test func aTapOnAStuckDownloadSaysHowLongItHasRunInABucket() {
        let p = GatefoldTelemetry.tapProperties(state: .downloading, hasCloudCopy: true, secondsDownloading: 400)
        #expect(Set(p.keys) == Self.allowed)
        #expect(p["state"] == .string("downloading"))
        #expect(p["seconds_downloading"] == .int(600))
    }

    @Test func aTapThatStartsADownloadSendsNoTimeAndNoFailureText() {
        let p = GatefoldTelemetry.tapProperties(state: .failed("PocketBook Cloud is having a little lie-down."), hasCloudCopy: false,
                                                secondsDownloading: nil)
        #expect(Set(p.keys).isSubset(of: Self.allowed))
        #expect(p["state"] == .string("failed"))
        #expect(p["has_cloud_copy"] == .bool(false))
        #expect(p["seconds_downloading"] == nil)
    }

    @Test func bucketsRoundUpAndStopAtAnHour() {
        #expect(GatefoldTelemetry.bucket(0) == 5)
        #expect(GatefoldTelemetry.bucket(5) == 15)
        #expect(GatefoldTelemetry.bucket(59.9) == 60)
        #expect(GatefoldTelemetry.bucket(86_400) == 3600)
    }

    @Test func theTapIsSentAsItsOwnEvent() throws {
        let sent = Box()
        let defaults = try #require(UserDefaults(suiteName: "telemetry-tap-\(UUID().uuidString)"))
        let telemetry = GatefoldTelemetry(configuration: .init(apiKey: "phc_test", captureURL: URL(string: "https://example.invalid/e/")!),
                                          defaults: defaults, send: { sent.requests.append($0) })
        telemetry.capture("gatefold_download_tap",
                          properties: GatefoldTelemetry.tapProperties(state: .cloudOnly, hasCloudCopy: true, secondsDownloading: nil))
        let body = try #require(sent.requests.first?.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["event"] as? String == "gatefold_download_tap")
        let props = try #require(json["properties"] as? [String: Any])
        #expect(props["state"] as? String == "cloud_only")
    }
}

/// Place sync telemetry is counts-only too: why a place did or didn't reach the e-reader, never the place.
struct GatefoldPlaceTelemetryTests {
    static let allowedPush: Set<String> = [
        "result", "reason", "app_phase", "has_cfi", "http_status", "error_domain", "error_code", "error_kind", "remote_newer",
        "remote_ahead", "remote_source", "trigger", "sign_in_renewed", "signed_in_again", "sign_in_expired", "background_expired",
        "attempts", "seconds_since_turn", "queued", "had_kept_password", "resign_in_error_kind",
    ]
    static let config = GatefoldTelemetry.Configuration(apiKey: "phc_test", captureURL: URL(string: "https://example.invalid/e/")!)

    static func event(_ request: URLRequest?) throws -> (name: String?, properties: [String: Any]) {
        let body = try #require(request?.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        return (json["event"] as? String, json["properties"] as? [String: Any] ?? [:])
    }

    @Test func aFailedPushSendsWhyAndHowButNotWhat() {
        var report = PlaceReport(direction: .push, result: .failed, reason: .willRetry, trigger: .background, attempts: 3,
                                 hasCFI: true, ageSeconds: 40, queued: 1)
        report.note(CloudError.http(status: 422, message: "position: File not found."))
        let p = GatefoldTelemetry.properties(of: report, phase: "background")
        #expect(Set(p.keys).isSubset(of: Self.allowedPush))
        #expect(p["result"] == .string("failed"))
        #expect(p["reason"] == .string("will_retry"))
        #expect(p["trigger"] == .string("background"))
        #expect(p["app_phase"] == .string("background"))
        #expect(p["http_status"] == .int(422))
        #expect(p["attempts"] == .int(3))
        #expect(p["seconds_since_turn"] == .int(60))
        #expect(p["background_expired"] == .bool(false))
        #expect(!p.values.contains { if case let .string(s) = $0 { s.contains("position") || s.contains("epubcfi") } else { false } })
    }

    @Test func anExpiredSignInSaysSo() {
        var report = PlaceReport(direction: .push, result: .failed, reason: .signInNeeded)
        report.note(CloudError.authenticationRequired)
        let p = GatefoldTelemetry.properties(of: report, phase: "active")
        #expect(p["sign_in_expired"] == .bool(true))
        #expect(p["error_kind"] == .string("authenticationRequired"))
    }

    /// Ari, build 53: "sign in again" with nothing to say whether a password was kept. Now it says.
    @Test func aReSignInSaysWhetherAPasswordWasKeptAndHowItWent() {
        var push = PlaceReport(direction: .push, result: .failed, reason: .signInNeeded)
        push.note(CloudError.authenticationRequired)
        push.note(reSignIn: ReSignInNote(tries: 1, hadKeptPassword: false, errorKind: "no_kept_password"), since: nil)
        let p = GatefoldTelemetry.properties(of: push, phase: "active")
        #expect(Set(p.keys).isSubset(of: Self.allowedPush))
        #expect(p["had_kept_password"] == .bool(false))
        #expect(p["resign_in_error_kind"] == .string("no_kept_password"))
        var pull = PlaceReport(direction: .pull, result: .failed, reason: .error)
        pull.note(reSignIn: ReSignInNote(tries: 3, hadKeptPassword: true, errorKind: "refused_kept"), since: ReSignInNote(tries: 2, hadKeptPassword: true, errorKind: "ok"))
        let q = GatefoldTelemetry.properties(of: pull, phase: "active")
        #expect(q["had_kept_password"] == .bool(true))
        #expect(q["resign_in_error_kind"] == .string("refused_kept"))
    }

    @Test func aCallThatNeverTriedToSignInAgainLeavesItOut() {
        var report = PlaceReport(direction: .push, result: .failed)
        let same = ReSignInNote(tries: 2, hadKeptPassword: true, errorKind: "ok")
        report.note(reSignIn: same, since: same)
        let p = GatefoldTelemetry.properties(of: report, phase: "active")
        #expect(p["had_kept_password"] == nil)
        #expect(p["resign_in_error_kind"] == nil)
    }

    @MainActor @Test func aPlaceFetchThatNeededASignInSaysHowTheReSignInWent() async throws {
        let sync = StubSync()
        let reports = Box()
        let defaults = try #require(UserDefaults(suiteName: "telemetry-pull-\(UUID().uuidString)"))
        let telemetry = GatefoldTelemetry(configuration: Self.config, defaults: defaults, send: { reports.requests.append($0) })
        let store = LibraryStore(sync: sync, root: URL.temporaryDirectory.appending(path: "pull-\(UUID().uuidString)"))
        var book = LibraryBook(id: "b", title: "T", author: "A", origin: .cloud, added: Date(timeIntervalSince1970: 0))
        book.cloud = CloudBook(fastHash: "b", name: "b.epub")
        await sync.setRemoteFailure(.authenticationRequired, reSignIn: ReSignInNote(tries: 1, hadKeptPassword: false, errorKind: "no_kept_password"))
        _ = await store.remotePosition(for: book, telemetry: telemetry)
        let event = try Self.event(reports.requests.first)
        #expect(event.name == "gatefold_place_pull")
        #expect(event.properties["had_kept_password"] as? Bool == false)
        #expect(event.properties["resign_in_error_kind"] as? String == "no_kept_password")
    }

    @Test func aPullSaysWhoWroteTheCloudsPlaceAndWhetherItIsNewer() throws {
        let book = LibraryBook(id: "b", title: "T", author: "A", origin: .cloud, totalProgression: 0.40, lastOpened: Date(timeIntervalSince1970: 1000),
                               added: Date(timeIntervalSince1970: 0))
        let remote = ReadingPosition(cfi: "epubcfi(/6/8!/4/2/1:0)", pointer: "pbr:/webkit?##epubcfi(/6/8!/4/2/1:0)", totalProgression: 0.55,
                                     updated: Date(timeIntervalSince1970: 2000), source: .pocketBookNative)
        let report = LibraryStore.pullReport(remote: remote, local: book)
        let p = GatefoldTelemetry.properties(of: report, phase: "active")
        #expect(GatefoldTelemetry.eventName(of: report) == "gatefold_place_pull")
        #expect(p["result"] == .string("received"))
        #expect(p["remote_source"] == .string("e_reader"))
        #expect(p["remote_newer"] == .bool(true))
        #expect(p["remote_ahead"] == .bool(true))
        #expect(p["has_cfi"] == .bool(true))
        #expect(p["trigger"] == nil)
        #expect(!p.values.contains { if case let .string(s) = $0 { s.contains("epubcfi") || s.contains("pbr:") } else { false } })
    }

    @Test func aPullWithNoCloudPlaceIsSkipped() {
        let book = LibraryBook(id: "b", title: "T", author: "A", origin: .cloud, added: Date(timeIntervalSince1970: 0))
        let report = LibraryStore.pullReport(remote: nil, local: book)
        #expect(report.result == .skipped)
        #expect(report.reason == .noPlace)
    }

    @Test func aPushIsSentAsItsOwnEvent() throws {
        let sent = Box()
        let defaults = try #require(UserDefaults(suiteName: "telemetry-place-\(UUID().uuidString)"))
        let telemetry = GatefoldTelemetry(configuration: Self.config, defaults: defaults, send: { sent.requests.append($0) })
        telemetry.appPhase = "inactive"
        telemetry.capture(PlaceReport(direction: .push, result: .sent, trigger: .debounce))
        let event = try Self.event(sent.requests.first)
        #expect(event.name == "gatefold_place_push")
        #expect(event.properties["result"] as? String == "sent")
        #expect(event.properties["app_phase"] as? String == "inactive")
    }

    @Test func anExpiredBackgroundSendIsKeptForTheNextLaunchAndSentOnce() throws {
        let sent = Box()
        let defaults = try #require(UserDefaults(suiteName: "telemetry-later-\(UUID().uuidString)"))
        let telemetry = GatefoldTelemetry(configuration: Self.config, defaults: defaults, send: { sent.requests.append($0) })
        telemetry.captureLater(PlaceReport(direction: .push, result: .failed, reason: .backgroundExpired, trigger: .background))
        #expect(sent.requests.isEmpty, "nothing gets out while iOS is ending the app's time")

        let nextLaunch = GatefoldTelemetry(configuration: Self.config, defaults: defaults, send: { sent.requests.append($0) })
        nextLaunch.sendDeferred()
        nextLaunch.sendDeferred()
        #expect(sent.requests.count == 1)
        let event = try Self.event(sent.requests.first)
        #expect(event.name == "gatefold_place_push")
        #expect(event.properties["reason"] as? String == "background_expired")
        #expect(event.properties["background_expired"] as? Bool == true)
        #expect(event.properties["app_phase"] as? String == "background")
    }

    /// A jump's and an open's timing go out bucketed, under a fixed set of names, with nothing about the book.
    @Test func aJumpSendsOnlyItsBucketedTimes() {
        let p = GatefoldTelemetry.jumpProperties(riffled: false, msToArrive: 180, msToLift: 7593)
        #expect(Set(p.keys) == ["veil", "ms_to_arrive", "ms_to_lift"])
        #expect(p["veil"] == .string("dim"))
        #expect(p["ms_to_arrive"] == .int(250))
        #expect(p["ms_to_lift"] == .int(8000))
        #expect(GatefoldTelemetry.jumpProperties(riffled: true, msToArrive: 0, msToLift: 90_000)["ms_to_lift"] == .int(64000))
    }

    @Test func anOpenSendsOnlyItsBucketedTimeAndHowItShowed() {
        let p = GatefoldTelemetry.openProperties(msToFirstPage: 10_400, behindShelf: true, forced: false)
        #expect(Set(p.keys) == ["ms_to_first_page", "behind_shelf", "forced"])
        #expect(p["ms_to_first_page"] == .int(16000))
        #expect(p["behind_shelf"] == .bool(true))
        #expect(p["forced"] == .bool(false))
    }

    @Test func aBucketIsTheBoundJustAbove() {
        #expect(GatefoldTelemetry.msBucket(249) == 250)
        #expect(GatefoldTelemetry.msBucket(250) == 500)
        #expect(GatefoldTelemetry.msBucket(63_999) == 64000)
    }

    @Test func nothingIsKeptWithoutAConfiguration() throws {
        let sent = Box()
        let defaults = try #require(UserDefaults(suiteName: "telemetry-off-\(UUID().uuidString)"))
        let telemetry = GatefoldTelemetry(configuration: nil, defaults: defaults, send: { sent.requests.append($0) })
        telemetry.captureLater(PlaceReport(direction: .push, result: .failed, reason: .backgroundExpired))
        #expect(defaults.data(forKey: GatefoldTelemetry.deferredKey) == nil)
    }
}

private final class Box: @unchecked Sendable {
    var count = 0
    var requests: [URLRequest] = []
}
