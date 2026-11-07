/// A jump to a place, sent until the page says it is there.
///
/// A web view still loading takes a jump, opens the jump's file at its first page and drops the place
/// inside it (CI's Duo: a jump to 0.993 opened at 0.938, its file's start, and stayed there while the
/// web view took 27 s to load). Waiting longer never brings it; sending the jump again does.
@MainActor
public enum JumpLanding {
    /// How near the page's report must come to the target's total progression.
    public static let tolerance = 0.015
    /// How many reads of the page's place one landing may make. Counted in reads, not seconds.
    public static let reads = 150
    /// While the page is short, the jump is sent again once every this many reads.
    public static let resendEvery = 10

    /// Sends the jump (again while the page refuses it or reports a place short of `target`) until a
    /// read is within `tolerance`. True once landed; false when the reads run out.
    public static func land(target: Double, go: () async -> Bool, reported: () -> Double?, beat: () async -> Void) async -> Bool {
        var taken = await go()
        for read in 1...reads {
            await beat()
            if taken, let at = reported(), abs(at - target) <= tolerance { return true }
            if !taken || read % resendEvery == 0 { taken = await go() }
        }
        return false
    }
}
