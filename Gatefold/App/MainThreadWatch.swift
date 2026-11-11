import Foundation

/// Tests only: logs each time the main thread goes a second or more without running a queued block,
/// so a UI query that times out (gatefold#28) can be laid against what the app was doing. A query
/// waits on the app's main thread; if it was held, the stall is the app's, not the runner's.
///
/// A timer on its own queue sends the main queue a ping every 250 ms, one at a time. When a ping comes
/// back a second or more late, the hold is logged with its length; while one is still out it is logged
/// as still held at 1 s and every 5 s after, so a hold the app doesn't outlive (a test relaunching it)
/// still shows. Pings go out on the 250 ms tick, so lengths read up to 250 ms short.
final class MainThreadWatch: @unchecked Sendable {
    // Everything below is touched only on `queue`.
    private let queue = DispatchQueue(label: "bot.ouro.gatefold.main-watch", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var outstanding: DispatchTime?
    private var nextStillHeldMark = MainThreadWatch.logAtMs

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
                nextStillHeldMark = waited + 5_000
            }
            return
        }
        outstanding = now
        nextStillHeldMark = Self.logAtMs
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
