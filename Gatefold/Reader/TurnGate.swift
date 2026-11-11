/// Whether a page turn (arrow key, space, deck button, edge tap or a kept reopen turn) may start.
enum TurnGate {
    static func starts(turning: Bool, veiled: Bool, jumpStarting: Bool) -> Bool {
        !turning
    }
}
