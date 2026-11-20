import Foundation

/// How one reading-place send or fetch went, in counts and codes only: never a title, hash, pointer, CFI,
/// email or text. The app sends these as telemetry, so a place that never reaches the e-reader says why.
public struct PlaceReport: Sendable, Equatable {
    public enum Direction: String, Sendable { case push, pull }

    public enum Result: String, Sendable {
        /// Push: the Cloud took the place.
        case sent
        /// Pull: the Cloud had a place.
        case received
        case failed
        /// Push: not sent, on purpose (`reason`). Pull: the Cloud has no place for the book.
        case skipped
    }

    public enum Reason: String, Sendable {
        /// Push skipped: another device's place in the Cloud is newer, so it stands.
        case remoteNewer = "remote_newer"
        /// Push failed and stays queued for another try.
        case willRetry = "will_retry"
        /// Push failed and was given up: the e-reader won't get this place.
        case dropped
        /// Push failed because the sign-in has to be renewed by hand; it stays queued until then.
        case signInNeeded = "sign_in_needed"
        /// The app went to the background and iOS ended its time before the send finished.
        case backgroundExpired = "background_expired"
        /// Pull: the Cloud has no place for the book.
        case noPlace = "no_place"
        /// Pull failed.
        case error
    }

    /// What set the send off.
    public enum Trigger: String, Sendable {
        /// The short wait after a page turn.
        case debounce
        /// A try after an earlier one failed.
        case retry
        /// The app went to the background. (Going inactive queues the place; its send is then the
        /// debounce's or the background's. The app adds the phase it was in.)
        case background
        /// The book was closed.
        case close
        /// A fresh sign-in sent what was waiting.
        case signIn = "sign_in"
        /// The library was fetched and found places still waiting.
        case library
        /// "Mark Finished".
        case finished
        case other
    }

    public var direction: Direction
    public var result: Result
    public var reason: Reason?
    public var trigger: Trigger
    public var httpStatus: Int?
    public var errorDomain: String?
    public var errorCode: Int?
    /// A short, fixed name for the error (`authenticationRequired`, `http`…), never its message.
    public var errorKind: String?
    /// The access token was renewed during this call.
    public var signInRenewed: Bool
    /// The renewal was refused and the app signed in again with the kept password.
    public var signedInAgain: Bool
    /// The Cloud turned the sign-in away for good: he has to sign in again by hand.
    public var signInExpired: Bool
    /// Tries so far for this place, this one included.
    public var attempts: Int
    /// The place carried an exact CFI (false: a whole percent only).
    public var hasCFI: Bool
    /// Seconds from the turn that made the place to this report.
    public var ageSeconds: Double?
    /// Writes still waiting in the outbox after this one.
    public var queued: Int?
    /// Who wrote the place the Cloud holds (`gatefold`, `e_reader`, `web`, `unknown`), when it was read.
    public var remoteSource: String?
    /// The Cloud's place is newer than the one here.
    public var remoteNewer: Bool?
    /// The Cloud's place is further into the book than the one here.
    public var remoteAhead: Bool?

    public init(direction: Direction, result: Result, reason: Reason? = nil, trigger: Trigger = .other,
                httpStatus: Int? = nil, errorDomain: String? = nil, errorCode: Int? = nil, errorKind: String? = nil,
                signInRenewed: Bool = false, signedInAgain: Bool = false, signInExpired: Bool = false, attempts: Int = 1,
                hasCFI: Bool = false, ageSeconds: Double? = nil, queued: Int? = nil, remoteSource: String? = nil,
                remoteNewer: Bool? = nil, remoteAhead: Bool? = nil) {
        self.direction = direction
        self.result = result
        self.reason = reason
        self.trigger = trigger
        self.httpStatus = httpStatus
        self.errorDomain = errorDomain
        self.errorCode = errorCode
        self.errorKind = errorKind
        self.signInRenewed = signInRenewed
        self.signedInAgain = signedInAgain
        self.signInExpired = signInExpired
        self.attempts = attempts
        self.hasCFI = hasCFI
        self.ageSeconds = ageSeconds
        self.queued = queued
        self.remoteSource = remoteSource
        self.remoteNewer = remoteNewer
        self.remoteAhead = remoteAhead
    }

    /// Records the error's domain, code and kind; never its message.
    public mutating func note(_ error: Error) {
        if let cloud = error as? CloudError {
            errorDomain = "CloudError"
            errorKind = cloud.kind
            switch cloud {
            case let .http(status, _), let .server(status): httpStatus = status
            case .notFound: httpStatus = 404
            case .authenticationRequired: httpStatus = 401
            case .rateLimited: httpStatus = 429
            default: break
            }
            if cloud == .authenticationRequired || cloud == .notSignedIn { signInExpired = true }
            return
        }
        let ns = error as NSError
        errorDomain = ns.domain
        errorCode = ns.code
        errorKind = String(describing: type(of: error))
    }

    /// Who wrote a place, as a fixed name.
    public static func sourceName(_ source: PositionSource) -> String {
        switch source {
        case .gatefold: "gatefold"
        case .pocketBookNative: "e_reader"
        case .pocketBookWeb: "web"
        case .unknown: "unknown"
        }
    }
}

/// Where place reports go. The app sets `sink` once at launch; tests read `reports`.
public final class PlaceReports: @unchecked Sendable {
    public static let shared = PlaceReports()

    private let lock = NSLock()
    private var _sink: (@Sendable (PlaceReport) -> Void)?
    private var recent: [PlaceReport] = []

    public init() {}

    public var sink: (@Sendable (PlaceReport) -> Void)? {
        get { lock.withLock { _sink } }
        set { lock.withLock { _sink = newValue } }
    }

    public func record(_ report: PlaceReport) {
        let sink = lock.withLock {
            recent.append(report)
            if recent.count > 50 { recent.removeFirst(recent.count - 50) }
            return _sink
        }
        sink?(report)
    }

    /// The last 50 reports, oldest first.
    public var reports: [PlaceReport] { lock.withLock { recent } }
}
