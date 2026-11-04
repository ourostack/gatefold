import Foundation
import Testing
import UIKit
@testable import Gatefold

/// The page's top clearance is remembered across launches so a reopen cuts the book into the same
/// pages he read. Build 15 also remembered what iOS reported while Gatefold was in the background
/// (laid out again for the app switcher, status bar up): the folded Duo's 62 pt instead of the bare
/// page's 46.33, so the next launch cut every page a line shorter and reopened before his page.
@MainActor
@Suite(.serialized)
struct PageTopTests {
    private let size = CGSize(width: 466, height: 678)

    @Test func aReadingTakenInTheBackgroundIsNotRemembered() {
        PageTop.forgetEverything()
        // He reads: the bare page reports the camera clearance.
        #expect(PageTop.settled(46.33, known: true, size: size, posture: .single, active: true) == 46.33)
        // He leaves: iOS lays the app out again with the status bar up.
        _ = PageTop.settled(0, known: true, size: size, posture: .single, active: false)
        _ = PageTop.settled(62, known: true, size: size, posture: .single, active: false)
        // Gatefold is ended and relaunched: the page is cut as he read it.
        PageTop.forgetLaunch()
        #expect(PageTop.settled(0, known: false, size: size, posture: .single, active: true) == 46.33)
    }

    @Test func aLaunchKeepsTheClearanceItStartedWith() {
        PageTop.forgetEverything()
        #expect(PageTop.settled(46.33, known: true, size: size, posture: .single, active: true) == 46.33)
        // A different reading later in the same launch never moves the page under him.
        #expect(PageTop.settled(62, known: true, size: size, posture: .single, active: true) == 46.33)
    }
}
