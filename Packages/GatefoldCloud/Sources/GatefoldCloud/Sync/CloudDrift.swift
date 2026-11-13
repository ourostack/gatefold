import Foundation
import os

/// What the cloud sent that Gatefold could do without (gatefold#372). PocketBook's cloud is unofficial
/// and changes without notice; when an answer is missing a field we can manage without, or carries it
/// under another name, the app carries on and notes it here instead of failing. Each note is logged
/// once, and the live canary lists them so the change is fixed before it matters.
public final class CloudDrift: @unchecked Sendable {
    public static let shared = CloudDrift()

    private let lock = NSLock()
    private var seen: [String] = []
    private let log = Logger(subsystem: "bot.ouro.gatefold", category: "cloud-drift")

    /// Records a tolerated change once. Never pass a value from the answer, only its shape.
    public func note(_ change: String) {
        lock.lock()
        let fresh = !seen.contains(change)
        if fresh { seen.append(change) }
        lock.unlock()
        if fresh { log.warning("cloud drift tolerated: \(change, privacy: .public)") }
    }

    public var notes: [String] {
        lock.lock(); defer { lock.unlock() }
        return seen
    }
}
