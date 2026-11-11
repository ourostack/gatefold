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

    /// Looks at the old page before the jump starts.
    static func tries(stillLoading: Bool) -> Int { 10 }

    /// What the veil holds, given whether the old page's picture came back bare (or black).
    static func hold(bare: Bool) -> Hold { .picture }
}
