import Testing
@testable import Gatefold

/// The catch-up tap waits at most 1.5 s for the standby page (`promoteStandby`), then jumps the plain way. The wait
/// was a task group whose child awaited the load's own task: the group's cancel never reached that task, so the group
/// waited out the whole load. On CI's starved iPad a tap waited 4 minutes on a standby still loading, the veil let go
/// after 150 beats, and the page showed no words (merge-queue run 44170382162, ReviewerChecksUITests).
@MainActor @Suite struct StandbyWaitTests {
    /// A load that ends only when let go, or after 400 looks (about 20 s) as a hang guard.
    @MainActor private final class Load {
        var letGo = false
        var ended = false
        lazy var task = Task { @MainActor in
            var looks = 0
            while !letGo, looks < 400 { looks += 1; try? await Task.sleep(for: .milliseconds(50)) }
            ended = true
        }
    }

    @Test(.timeLimit(.minutes(1))) func aStandbyStillLoadingIsLeftAtTheLimit() async {
        let load = Load()
        let loaded = await ReaderHostController.finished(load.task, within: .milliseconds(100))
        let endedFirst = load.ended
        load.letGo = true
        await load.task.value
        #expect(!loaded, "a load still going at the limit counts as not loaded")
        #expect(!endedFirst, "the wait ended at its limit, not when the load did")
    }

    @Test(.timeLimit(.minutes(1))) func aStandbyThatHasLoadedIsTaken() async {
        let load = Load()
        load.letGo = true
        await load.task.value
        #expect(await ReaderHostController.finished(load.task, within: .seconds(30)), "a loaded standby is swapped in")
    }
}
