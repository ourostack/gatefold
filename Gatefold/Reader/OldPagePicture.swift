import Foundation

/// How a jump pictures the page he leaves for its veil (gatefold#155).
enum OldPagePicture {
    /// What the veil holds over the page while the jump runs.
    enum Hold: Equatable {
        /// The picture taken of the old page.
        case picture
        /// What is on screen now, copied as it is: never a bare picture of a page that hadn't painted.
        case onScreen
    }

    /// Looks at the old page before the jump starts. A page still loading can't come good in a few
    /// tries, and each try held the jump back (1.7 to 2.7 s for ten on CI's iPad): one look, then the
    /// jump. A loaded page only briefly bare (a turn settling) keeps its few tries.
    static func tries(stillLoading: Bool) -> Int { stillLoading ? 1 : 10 }

    /// What the veil holds, given whether the old page's picture came back bare (or black).
    /// A bare picture held over the jump is a blank flash: the screen as it is stays instead.
    static func hold(bare: Bool) -> Hold { bare ? .onScreen : .picture }
}
