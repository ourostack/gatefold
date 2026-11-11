/// Whether a page turn (arrow key, space, deck button, edge tap or a kept reopen turn) may start.
enum TurnGate {
    static func starts(turning: Bool, veiled: Bool, jumpStarting: Bool) -> Bool {
        // Under a jump's veil the page beneath is on its way somewhere; a turn would move it from
        // wherever the jump has got to, and the place he chose is lost.
        !turning && !veiled && !jumpStarting
    }
}
