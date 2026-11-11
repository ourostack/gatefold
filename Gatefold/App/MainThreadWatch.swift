import Foundation

/// Tests only: logs each time the main thread goes a second or more without running a queued block,
/// so a UI query that times out (gatefold#28) can be laid against what the app was doing. A query
/// waits on the app's main thread; if it was held, the stall is the app's, not the runner's.
///
/// A timer on its own queue sends the main queue a ping every 250 ms, one at a time. When a ping comes
/// back a second or more late, the hold is logged with its length; while one is still out, every 5 s
/// it is logged as still held, so a hold the test never outlives still shows.
final class MainThreadWatch: @unchecked Sendable {
    // Everything below is touched only on `queue`.
    private let queue = DispatchQueue(label: "bot.ouro.gatefold.main-watch", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var outstanding: DispatchTime?
    private var nextStillHeldMark = 5_000

    private static let shared = MainThreadWatch()
    private static let logAtMs = 1_000

    /// Starts the watch in a UI-test launch; does nothing otherwise.
    @MainActor
    static func startIfUITest() {
        guard LaunchOptions.isUITest else { return }
        shared.queue.async { shared.start() }
    }

    private func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250), leeway: .milliseconds(20))
        timer.setEventHandler { [unowned self] in tick() }
        self.timer = timer
        timer.resume()
        readerLog.notice("main: watch started")
    }

    private func tick() {
        let now = DispatchTime.now()
        if let sent = outstanding {
            let waited = Self.ms(from: sent, to: now)
            if waited >= nextStillHeldMark {
                readerLog.notice("main: still held after \(waited, privacy: .public) ms")
                nextStillHeldMark += 5_000
            }
            return
        }
        outstanding = now
        nextStillHeldMark = 5_000
        DispatchQueue.main.async { [self] in
            let answered = DispatchTime.now()
            queue.async { self.answered(sent: now, at: answered) }
        }
    }

    private func answered(sent: DispatchTime, at answered: DispatchTime) {
        outstanding = nil
        let held = Self.ms(from: sent, to: answered)
        if held >= Self.logAtMs { readerLog.notice("main: held \(held, privacy: .public) ms") }
    }

    private static func ms(from start: DispatchTime, to end: DispatchTime) -> Int {
        Int((end.uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000)
    }
}
