import Foundation

/// The wall-time guard on a wait judged in reads (gatefold#94). It is not the bar, which is the read count: it
/// fires only on a hang, and then fails with the wait's own message, its read count and where it stuck.
///
/// Sized as the wait's reads at the slowest read seen on CI, plus a quarter (gatefold#221, #223), capped so it
/// fires before the step's own end. A guard the step's limit always beats is worth nothing, and a test the step
/// kills uploads nothing to diagnose (gatefold#126).
enum HangGuard {
    /// The slowest look in #207's green probe: 18.6 s (run 42973604069, job 130368394864, "offer taken after 1 looks
    /// in 18.6 s"). That one look was three reads and a tap, just after the book opened, so no read in it took longer.
    /// The quarter on top covers the pause between reads and a slower runner.
    static let worstRead: TimeInterval = 18.6
    /// Before the step's end: ci-within sends SIGINT 120 s before it (scripts/ci-within.py, `GRACE`), and the
    /// test needs about a minute more to record its failure and end before that.
    static let beforeStepEnd: TimeInterval = 180
    /// Never less, so a wait started near the step's end still gets a few reads.
    static let floor: TimeInterval = 30

    /// Seconds a wait of `reads` reads may run before it counts as a hang. On CI the iPad and Duo test steps pass
    /// their end as `GATEFOLD_STEP_UNTIL` (epoch seconds, the time-left action's `until`); without it (a local run)
    /// the cap is left out. Taken when the wait starts, so time the step has already spent counts.
    static func seconds(reads: Int, now: Date = Date()) -> TimeInterval {
        seconds(reads: reads, stepUntil: ProcessInfo.processInfo.environment["GATEFOLD_STEP_UNTIL"].flatMap(TimeInterval.init),
                now: now)
    }

    /// The same, with the step's end given (nil: no cap).
    static func seconds(reads: Int, stepUntil: TimeInterval?, now: Date) -> TimeInterval {
        let sized = Double(reads) * worstRead * 1.25
        guard let stepUntil else { return sized }
        return max(floor, min(sized, stepUntil - now.timeIntervalSince1970 - beforeStepEnd))
    }
}
