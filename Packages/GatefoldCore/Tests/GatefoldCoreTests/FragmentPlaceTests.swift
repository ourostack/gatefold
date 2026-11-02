import Foundation
import Testing
@testable import GatefoldCore

@Suite struct FragmentPlaceTests {
    private let html = Data("<html><body><h2 id=\"ch8\">VIII</h2><p>aaaaaaaaaaaaaaaaaaaa</p><h2 id='ch9'>IX</h2><p>bbbb</p><a name=\"ch10\"></a></body></html>".utf8)

    @Test func findsTheElementNotTheAttribute() {
        let tag = html.range(of: Data("<h2 id=\"ch8\"".utf8))!.lowerBound
        #expect(FragmentPlace.fraction(of: "ch8", in: html) == Double(tag) / Double(html.count))
    }

    @Test func laterChaptersSitLater() {
        let a = FragmentPlace.fraction(of: "ch8", in: html)!
        let b = FragmentPlace.fraction(of: "ch9", in: html)!
        let c = FragmentPlace.fraction(of: "ch10", in: html)!
        #expect(a < b && b < c && c < 1)
    }

    @Test func unknownFragmentIsNil() {
        #expect(FragmentPlace.fraction(of: "nope", in: html) == nil)
        #expect(FragmentPlace.fraction(of: "", in: html) == nil)
    }

    @Test func noPrefixMatch() {
        // "ch1" must not match "ch10".
        #expect(FragmentPlace.fraction(of: "ch1", in: html) == nil)
    }

    @Test func spreadsAcrossTheFilesShare() {
        #expect(abs(FragmentPlace.progression(fileStart: 0.2, fileEnd: 0.4, fraction: 0.5) - 0.3) < 1e-12)
        #expect(FragmentPlace.progression(fileStart: 0.2, fileEnd: 0.4, fraction: 2) == 0.4)
    }
}
