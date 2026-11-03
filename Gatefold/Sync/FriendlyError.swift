import Foundation

/// Every error the reader can see, in words a person would use. Raw Swift or Foundation text
/// ("The operation couldn't be completed. (Swift.CancellationError error 1.)") never reaches the screen:
/// anything this doesn't recognise becomes `.unknown`, and a cancelled task is not an error at all.
enum FriendlyError: Equatable {
    /// The task was called off (a pull-to-refresh let go, a sheet closed). Never shown.
    case cancelled
    case offline
    /// The Cloud answered, but not well: a 5xx, a rate limit, a reply we couldn't read.
    case server
    case sessionExpired
    case noAccount
    case wrongPassword
    case notFound
    /// A book file we couldn't open.
    case unreadable
    case unknown

    init(_ error: Error) {
        if Self.isCancellation(error) { self = .cancelled; return }
        if let cloud = error as? CloudError {
            switch cloud {
            case .offline, .network: self = .offline
            case .authenticationRequired, .notSignedIn: self = .sessionExpired
            case .noAccount: self = .noAccount
            case .invalidCredentials: self = .wrongPassword
            case .notFound, .deleteNotApplied: self = .notFound
            case .server, .rateLimited, .http, .unexpectedResponse, .clientCredentialsUnavailable: self = .server
            case .checksumMismatch, .fileTooSmall: self = .unreadable
            }
            return
        }
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost,
                 .dataNotAllowed, .internationalRoamingOff, .dnsLookupFailed, .secureConnectionFailed:
                self = .offline
            case .badServerResponse, .cannotParseResponse, .zeroByteResource: self = .server
            default: self = .unknown
            }
            return
        }
        if error is BookOpener.OpenError || error is DecodingError { self = .unreadable; return }
        self = .unknown
    }

    /// Cancellation in any of its costumes: Swift's, URLSession's, Cocoa's.
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let url = error as? URLError, url.code == .cancelled { return true }
        if let cocoa = error as? CocoaError, cocoa.code == .userCancelled { return true }
        let ns = error as NSError
        return (ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled)
            || (ns.domain == NSCocoaErrorDomain && ns.code == NSUserCancelledError)
    }

    /// What to show, or nil for a cancellation (show nothing).
    static func message(for error: Error) -> String? { FriendlyError(error).message }

    var message: String? {
        switch self {
        case .cancelled: nil
        case .offline: "You're offline. Your books and places are tucked in safe; we'll catch up the moment you're back."
        case .server: "PocketBook Cloud is having a little lie\u{2011}down. Give it a moment and try again."
        case .sessionExpired: "PocketBook Cloud would like you to sign in again."
        case .noAccount: "We couldn't find a PocketBook Cloud account for that email. A stray letter, perhaps?"
        case .wrongPassword: "That password didn't open the door. Give it another go?"
        case .notFound: "That book has wandered out of your Cloud library."
        case .unreadable: "This book's pages seem stuck together, so it wouldn't open. Is it an EPUB?"
        case .unknown: "Something went sideways on the way. Give it another try?"
        }
    }

    /// Worth offering "Try Again" for: it may well work in a moment.
    var isRetryable: Bool {
        switch self {
        case .offline, .server, .unknown: true
        default: false
        }
    }
}
