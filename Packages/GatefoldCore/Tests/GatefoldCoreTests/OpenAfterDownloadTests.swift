import Testing
@testable import GatefoldCore

/// One tap on a book still in the Cloud means "read this" (Ari, 2026-11-27: a cloud book needed a second tap to
/// open once it had downloaded). Each test is one intent and what finishing it looks like, so an Ouro Feel check of
/// "an intent that needs repeating" can stand in for them later.
@Suite struct OpenAfterDownloadTests {
    @Test func aTappedBookOpensWhenItLandsWithTheShelfInFront() {
        var intent = OpenAfterDownload()
        intent.tapped("moby")
        #expect(intent.landed("moby", shelfInFront: true) == .open)
        #expect(intent.awaited == nil)
        #expect(!intent.isReady("moby"))
    }

    @Test func goingElsewhereFirstLeavesItReadyInsteadOfYankingHimBack() {
        var intent = OpenAfterDownload()
        intent.tapped("moby")
        intent.left()
        #expect(intent.landed("moby", shelfInFront: true) == .ready)
        #expect(intent.isReady("moby"))
    }

    @Test func somethingOverTheShelfWhenItLandsLeavesItReady() {
        var intent = OpenAfterDownload()
        intent.tapped("moby")
        #expect(intent.landed("moby", shelfInFront: false) == .ready)
        #expect(intent.isReady("moby"))
    }

    @Test func theLastBookTappedIsTheOneHeIsWaitingFor() {
        var intent = OpenAfterDownload()
        intent.tapped("moby")
        intent.tapped("emma")
        #expect(intent.awaited == "emma")
        // The first lands while he waits for the second: it waits for his next tap.
        #expect(intent.landed("moby", shelfInFront: true) == .ready)
        #expect(intent.landed("emma", shelfInFront: true) == .open)
    }

    @Test func stoppingTheDownloadDropsTheOpen() {
        var intent = OpenAfterDownload()
        intent.tapped("moby")
        intent.stopped("moby")
        #expect(intent.awaited == nil)
        // A copy that lands anyway (the stop came as it finished) opens nothing and claims nothing.
        #expect(intent.landed("moby", shelfInFront: true) == .nothing)
        #expect(!intent.isReady("moby"))
    }

    @Test func stoppingAnotherBookKeepsTheWait() {
        var intent = OpenAfterDownload()
        intent.tapped("moby")
        intent.tapped("emma")
        intent.stopped("moby")
        #expect(intent.landed("emma", shelfInFront: true) == .open)
    }

    @Test func aFailedDownloadOpensNothingAndATryAgainWaitsAgain() {
        var intent = OpenAfterDownload()
        intent.tapped("moby")
        intent.failed("moby")
        #expect(intent.awaited == nil)
        intent.tapped("moby")
        #expect(intent.landed("moby", shelfInFront: true) == .open)
    }

    @Test func aDownloadNobodyTappedOpensNothing() {
        var intent = OpenAfterDownload()
        #expect(intent.landed("moby", shelfInFront: true) == .nothing)
        #expect(!intent.isReady("moby"))
    }

    @Test func openingAnotherBookEndsTheWait() {
        var intent = OpenAfterDownload()
        intent.tapped("moby")
        intent.opened("dracula")
        #expect(intent.landed("moby", shelfInFront: true) == .ready)
    }

    @Test func openingAReadyBookMakesItAnyOtherBook() {
        var intent = OpenAfterDownload()
        intent.tapped("moby")
        intent.left()
        _ = intent.landed("moby", shelfInFront: true)
        intent.opened("moby")
        #expect(!intent.isReady("moby"))
    }

    @Test func aLandingOpensOnlyOnce() {
        var intent = OpenAfterDownload()
        intent.tapped("moby")
        #expect(intent.landed("moby", shelfInFront: true) == .open)
        #expect(intent.landed("moby", shelfInFront: true) == .nothing)
    }
}
