import Foundation
import GatefoldCloud
import Testing
@testable import Gatefold

/// Ari, build 53: the Cloud wanted him to sign in again while he read, and only the shelf said so. The reader
/// shows its sign-in slip whenever that is true, except where it would sit on something else.
@Suite struct SignInSlipTests {
    @Test func showsWhileTheCloudWantsASignIn() {
        #expect(ReaderScreen.showsSignInSlip(needsReconnect: true, later: false, offerUp: false, pageReady: true, atTheEnd: false))
    }

    @Test func staysAwayOtherwise() {
        #expect(!ReaderScreen.showsSignInSlip(needsReconnect: false, later: false, offerUp: false, pageReady: true, atTheEnd: false), "signed in")
        #expect(!ReaderScreen.showsSignInSlip(needsReconnect: true, later: true, offerUp: false, pageReady: true, atTheEnd: false), "he chose Later")
        #expect(!ReaderScreen.showsSignInSlip(needsReconnect: true, later: false, offerUp: true, pageReady: true, atTheEnd: false), "the InkPad's offer is up")
        #expect(!ReaderScreen.showsSignInSlip(needsReconnect: true, later: false, offerUp: false, pageReady: false, atTheEnd: false), "the page isn't up yet")
        #expect(!ReaderScreen.showsSignInSlip(needsReconnect: true, later: false, offerUp: false, pageReady: true, atTheEnd: true), "the end leaf")
    }

    @Test func itsWordsSayWhatWaitsAndWhatToDo() {
        #expect(SignInSlipView.title == "Your place is waiting to reach your e-reader")
        #expect(SignInSlipView.detail.contains("sign in again"))
    }
}

/// The fake Cloud the reader's sign-in prompt is screenshot against: the shelf comes over, then a place is turned away.
@MainActor @Suite(.serialized) struct ExpiresWhileReadingTests {
    @Test func aPlaceTurnedAwayAsksToSignInAgain() async throws {
        let sync = FakeSyncService(signedIn: true, scenario: .expiresWhileReading, latency: .zero)
        let app = AppModel(sync: sync, libraryRoot: URL.temporaryDirectory.appending(path: "expires-\(UUID().uuidString)"))
        await app.start()
        let book = try #require(app.library.books.first { $0.cloud != nil })
        #expect(app.needsReconnect == nil)
        app.library.recordPlace(bookID: book.id, locatorJSON: "{}", totalProgression: 0.2, progression: 0.5)
        await app.library.sendPendingPushes()
        for _ in 0..<50 where app.needsReconnect == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(app.needsReconnect == "reader@example.com")
    }

    @Test func openingABookAsksToSignInAgainAndSigningInClearsIt() async throws {
        let sync = FakeSyncService(signedIn: true, scenario: .expiresWhileReading, latency: .zero)
        let app = AppModel(sync: sync, libraryRoot: URL.temporaryDirectory.appending(path: "expires-\(UUID().uuidString)"))
        await app.start()
        let book = try #require(app.library.books.first { $0.cloud != nil })
        #expect(await app.library.remotePosition(for: book) == nil)
        for _ in 0..<50 where app.needsReconnect == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(app.needsReconnect == "reader@example.com")
        let account = try await sync.signIn(email: "reader@example.com", password: "synthetic", store: FakeSyncService.stores[0])
        await app.didSignIn(account)
        #expect(app.needsReconnect == nil)
        await #expect(throws: Never.self) { _ = try await sync.remotePosition(for: try #require(book.cloud)) }
    }
}
