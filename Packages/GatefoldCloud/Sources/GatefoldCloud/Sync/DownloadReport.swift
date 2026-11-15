import Foundation

/// How one book download went, in counts and codes only: never a title, file name, hash, link or email.
/// The app sends these as telemetry, so a download that fails on a reader's phone says where and why.
public struct DownloadReport: Sendable, Equatable {
    /// Where a download stopped. `nil` on the report of a download that worked.
    public enum Stage: String, Sendable {
        /// The listing had no link and `/fileops/info` gave none either.
        case link
        /// Asking `/fileops/info` for a fresh link failed.
        case refetchLink = "refetch_link"
        /// The transfer itself failed (offline, timed out, TLS…).
        case transfer
        /// The Cloud answered the download with a status that isn't 2xx.
        case status
        /// The file arrived but failed its MD5 or size check.
        case verify
        /// Moving the verified file into place failed.
        case store
        /// After the Cloud's part: putting the book on the shelf (the app's own stage).
        case shelve
        /// The download was called off.
        case cancelled
    }

    /// What the file was checked against.
    public enum Check: String, Sendable { case md5, size, none }

    public var stage: Stage?
    public var httpStatus: Int?
    public var errorDomain: String?
    public var errorCode: Int?
    /// A short, fixed name for the error (`checksumMismatch`, `http`…), never its message.
    public var errorKind: String?
    public var hadListedLink: Bool
    public var refetched: Bool
    public var attempts: Int
    public var check: Check
    /// The format in lower case when it is a known one (epub, pdf, fb2, mobi…), else "other".
    public var format: String
    public var isDRM: Bool
    /// Whether the bytes that arrived matched the listed size (nil when nothing arrived or none was listed).
    public var sizeMatched: Bool?
    public var reusedLocalCopy: Bool

    public init(stage: Stage? = nil, httpStatus: Int? = nil, errorDomain: String? = nil, errorCode: Int? = nil,
                errorKind: String? = nil, hadListedLink: Bool = false, refetched: Bool = false, attempts: Int = 0,
                check: Check = .none, format: String = "other", isDRM: Bool = false, sizeMatched: Bool? = nil,
                reusedLocalCopy: Bool = false) {
        self.stage = stage
        self.httpStatus = httpStatus
        self.errorDomain = errorDomain
        self.errorCode = errorCode
        self.errorKind = errorKind
        self.hadListedLink = hadListedLink
        self.refetched = refetched
        self.attempts = attempts
        self.check = check
        self.format = format
        self.isDRM = isDRM
        self.sizeMatched = sizeMatched
        self.reusedLocalCopy = reusedLocalCopy
    }

    static let knownFormats: Set<String> = ["epub", "pdf", "fb2", "mobi", "azw3", "djvu", "txt", "rtf", "doc", "docx", "cbz", "cbr", "acsm"]

    static func format(of book: CloudBook) -> String {
        let raw = (book.format?.lowercased()).flatMap { $0.isEmpty ? nil : $0 } ?? URL(fileURLWithPath: book.name).pathExtension.lowercased()
        return knownFormats.contains(raw) ? raw : "other"
    }

    /// Records the error's domain, code and kind; never its message.
    public mutating func note(_ error: Error) {
        if let cloud = error as? CloudError {
            errorDomain = "CloudError"
            errorKind = cloud.kind
            if case let .http(status, _) = cloud { httpStatus = httpStatus ?? status }
            if case let .server(status) = cloud { httpStatus = httpStatus ?? status }
            return
        }
        let ns = error as NSError
        errorDomain = ns.domain
        errorCode = ns.code
        errorKind = String(describing: type(of: error))
    }
}

extension CloudError {
    /// The case's name alone, with no associated message.
    var kind: String {
        switch self {
        case .notSignedIn: "notSignedIn"
        case .noAccount: "noAccount"
        case .invalidCredentials: "invalidCredentials"
        case .authenticationRequired: "authenticationRequired"
        case .offline: "offline"
        case .network: "network"
        case .notFound: "notFound"
        case .deleteNotApplied: "deleteNotApplied"
        case .server: "server"
        case .rateLimited: "rateLimited"
        case .http: "http"
        case .unexpectedResponse: "unexpectedResponse"
        case .clientCredentialsUnavailable: "clientCredentialsUnavailable"
        case .checksumMismatch: "checksumMismatch"
        case .fileTooSmall: "fileTooSmall"
        }
    }
}

/// Where download reports go. The app sets `sink` once at launch; tests read `reports`.
public final class DownloadReports: @unchecked Sendable {
    public static let shared = DownloadReports()

    private let lock = NSLock()
    private var _sink: (@Sendable (DownloadReport) -> Void)?
    private var recent: [DownloadReport] = []

    public init() {}

    public var sink: (@Sendable (DownloadReport) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _sink }
        set { lock.lock(); _sink = newValue; lock.unlock() }
    }

    public func record(_ report: DownloadReport) {
        lock.lock()
        recent.append(report)
        if recent.count > 50 { recent.removeFirst(recent.count - 50) }
        let sink = _sink
        lock.unlock()
        sink?(report)
    }

    /// The last 50 reports, oldest first.
    public var reports: [DownloadReport] {
        lock.lock(); defer { lock.unlock() }
        return recent
    }
}
