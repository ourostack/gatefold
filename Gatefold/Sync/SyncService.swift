@_exported import GatefoldCloud
import Foundation

// The sync seam is stream A's `SyncService` (Packages/GatefoldCloud). The app codes against it;
// `FakeSyncService` conforms for previews, tests and the prototype, and `PocketBookCloud` is the real one.

extension CloudError: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noAccount: "There's no PocketBook Cloud account with that email."
        case .invalidCredentials: "That password didn't work. Check it and try again."
        case .offline, .network: "You're offline. Your books and place are safe; we'll sync when you're back."
        case .notFound: "That book isn't in your Cloud library any more."
        case .authenticationRequired, .notSignedIn: "Sign in to PocketBook Cloud again to keep syncing."
        default: "PocketBook Cloud didn't answer as expected. Try again in a moment."
        }
    }
}

extension ReadingPosition {
    /// Who moved the place, for the "further ahead" banner (`JumpSuggestion.deviceKind` words it).
    var deviceName: String {
        switch source {
        case .pocketBookNative: "PocketBook InkPad"
        case .pocketBookWeb: "PocketBook web reader"
        case .gatefold, .unknown: ""
        }
    }
}
