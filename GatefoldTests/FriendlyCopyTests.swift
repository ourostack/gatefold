import Foundation
import Testing
@testable import Gatefold

/// Friendly messages never break a hyphenated word across lines: "lie-down" split in two on the
/// folded shelf (build 14). Joined words use the non-breaking hyphen.
struct FriendlyCopyTests {
    static let all: [FriendlyError] = [.offline, .server, .sessionExpired, .noAccount, .wrongPassword, .notFound, .unreadable, .unknown]

    @Test(arguments: all) func noMessageBreaksAWordAtItsHyphen(_ kind: FriendlyError) throws {
        let message = try #require(kind.message)
        #expect(message.range(of: #"\p{L}-\p{L}"#, options: .regularExpression) == nil, "\(message)")
    }

    @Test func theServerMessageKeepsLieDownTogether() {
        #expect(FriendlyError.server.message?.contains("lie\u{2011}down") == true)
    }
}
