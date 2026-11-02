import Foundation
import Testing
@testable import GatefoldCore

/// After landing on the InkPad's place, the shelf and the Cloud keep the Cloud's own number for it,
/// and reading on only ever adds to it: a formula difference never shows as lost progress.
@Suite("Progress never goes backwards because two readers count differently")
struct CloudScaleTests {
    // The Cloud said 36 %; Readium's whole-book scale puts the same words at 25 %.
    let scale = CloudScale(cloud: 0.36, landed: 0.25)!

    @Test func theLandedPlaceReadsAsTheCloudsPercent() {
        #expect(ReadingPercent.whole(scale.onCloudScale(0.25)) == 36)
    }

    @Test func readingThreePagesOnNeverShowsLessThanTheCloud() {
        // About a page in a long book is 0.002 of it.
        var last = scale.onCloudScale(0.25)
        for page in 1...3 {
            let shown = scale.onCloudScale(0.25 + Double(page) * 0.002)
            #expect(shown >= 0.36)
            #expect(shown > last)
            last = shown
        }
    }

    @Test func goingBackBeforeTheLandedPlaceKeepsTheCloudsPercent() {
        #expect(scale.onCloudScale(0.10) == 0.36)
    }

    @Test func theEndOfTheBookIsStillTheEnd() {
        #expect(scale.onCloudScale(1) == 1)
        #expect(scale.onCloudScale(0.99) < 1)
    }

    @Test func itNeverDecreasesAcrossTheWholeBook() {
        var last = 0.0
        for i in 0...1000 {
            let shown = scale.onCloudScale(Double(i) / 1000)
            #expect(shown >= last)
            #expect(shown >= 0.36)
            last = shown
        }
    }

    @Test func noScaleIsNeededWhenOurNumberIsAlreadyAtOrAboveTheClouds() {
        #expect(CloudScale(cloud: 0.20, landed: 0.25) == nil)
        #expect(CloudScale(cloud: 0.25, landed: 0.25) == nil)
    }

    @Test func badNumbersMakeNoScale() {
        #expect(CloudScale(cloud: .nan, landed: 0.25) == nil)
        #expect(CloudScale(cloud: 0.5, landed: 1) == nil)
    }

    @Test func itSurvivesBeingSaved() throws {
        let data = try JSONEncoder().encode(scale)
        #expect(try JSONDecoder().decode(CloudScale.self, from: data) == scale)
    }
}
