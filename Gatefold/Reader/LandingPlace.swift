import Foundation

/// The place to record after landing on another device's place.
enum LandingPlace {
    /// `settled` is the first words on screen once the landing settled; `target` is where we landed.
    /// The page usually starts a few lines above the target, and recording that would hand the other
    /// device its own place back a few lines behind. So: the settled place when it is at or past the
    /// target, else the target itself. Never earlier than the target.
    static func choose(settled: ReadingPosition?, target: ReadingPosition?, at now: Date) -> ReadingPosition? {
        guard var target else { return settled }
        target.updated = now
        target.source = .gatefold
        guard let settled else { return target }
        let behind: Bool
        if let a = settled.parsedCFI, let b = target.parsedCFI {
            behind = a < b
        } else {
            behind = settled.totalProgression < target.totalProgression
        }
        guard behind else { return settled }
        target.totalProgression = max(target.totalProgression, settled.totalProgression)
        return target
    }
}
