@_exported import GatefoldCloud
import Foundation

// The sync seam is stream A's `SyncService` (Packages/GatefoldCloud). The app codes against it;
// `FakeSyncService` conforms for previews, tests and the prototype, and `PocketBookCloud` is the real one.

extension CloudError: @retroactive LocalizedError {
    /// The reader's words for it (`FriendlyError`), so even a stray `localizedDescription` reads kindly.
    public var errorDescription: String? { FriendlyError(self).message }
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
