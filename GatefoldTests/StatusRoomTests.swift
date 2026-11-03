import Foundation
import SwiftUI
import Testing
@testable import Gatefold

/// A slip keeps below the status bar's room as last seen in portrait, even once the reader hides the bar.
@MainActor
@Suite(.serialized)
struct StatusRoomTests {
    private let portrait = CGSize(width: 440, height: 956)
    private let landscape = CGSize(width: 956, height: 440)

    private func withRemembered(_ body: () -> Void) {
        let saved = UserDefaults.standard.object(forKey: "GatefoldStatusRoom")
        UserDefaults.standard.removeObject(forKey: "GatefoldStatusRoom")
        body()
        if let saved { UserDefaults.standard.set(saved, forKey: "GatefoldStatusRoom") } else { UserDefaults.standard.removeObject(forKey: "GatefoldStatusRoom") }
    }

    @Test func aSlipKeepsBelowTheIslandWithTheStatusBarHidden() {
        withRemembered {
            ReaderChrome.StatusRoom.note(EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0), size: portrait)
            // Status bar hidden: the safe area's top falls to nothing, the slip still clears 62 pt.
            #expect(ReaderChrome.StatusRoom.slipSafeTop(12, size: portrait) == 62)
            // Landscape has no island at the top: the safe area alone decides.
            #expect(ReaderChrome.StatusRoom.slipSafeTop(12, size: landscape) == 12)
        }
    }

    @Test func onlyAPortraitStatusBarIsRemembered() {
        withRemembered {
            ReaderChrome.StatusRoom.note(EdgeInsets(top: 0, leading: 62, bottom: 21, trailing: 62), size: landscape)
            ReaderChrome.StatusRoom.note(EdgeInsets(top: 12, leading: 0, bottom: 0, trailing: 0), size: portrait)
            #expect(ReaderChrome.StatusRoom.slipSafeTop(12, size: portrait) == 12)
        }
    }
}
