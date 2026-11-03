import Foundation
import GatefoldCore
import Testing
@testable import Gatefold

/// Build 13 on Ari's Duo: a pull-to-refresh showed "The operation couldn't be completed.
/// (Swift.CancellationError error 1.)", then the shelf lost books and the avatar reset. A refresh that
/// fails in any way must leave the shelf, the account and the sign-in exactly as they were.
@MainActor @Suite(.serialized) struct RefreshSafetyTests {
    let mistborn = CloudBook(fastHash: "mistborn", name: "mistborn.epub", title: "Mistborn: Secret History",
                             position: ReadingPosition(cfi: nil, totalProgression: 0.01, updated: Date(), source: .pocketBookNative))
    let wind = CloudBook(fastHash: "wind", name: "wind.epub", title: "Wind and Truth",
                         position: ReadingPosition(cfi: nil, totalProgression: 0.6, updated: Date(), source: .pocketBookNative))
    let eden = CloudBook(fastHash: "eden", name: "eden.epub", title: "East of Eden",
                         position: ReadingPosition(cfi: nil, totalProgression: 0.09, updated: Date(), source: .pocketBookNative))

    /// Signed in, three books on the shelf, all in Reading Now, as on his phone before the pull.
    private func shelf() async -> (AppModel, StubSync) {
        let sync = StubSync()
        let app = AppModel(sync: sync, libraryRoot: URL.temporaryDirectory.appending(path: "refresh-safety-\(UUID().uuidString)"))
        await sync.setLibrary(.success([eden, mistborn, wind]))
        await app.start()
        #expect(app.library.readingNow.count == 3)
        return (app, sync)
    }

    private func expectUntouched(_ app: AppModel, _ label: Comment) {
        #expect(app.library.books.map(\.id).sorted() == ["eden", "mistborn", "wind"], label)
        #expect(app.library.readingNow.count == 3, label)
        #expect(app.account?.email == "reader@example.com", label)
        #expect(app.accountInitial == "R", label)
    }

    @Test(arguments: [CancellationError() as any Error, URLError(.cancelled), CocoaError(.userCancelled)])
    func aCancelledRefreshShowsNothingAndKeepsTheShelf(_ error: any Error) async {
        let (app, sync) = await shelf()
        await sync.queueLibrary([.failure(error)])
        await app.refresh()
        #expect(app.library.syncProblem == nil, "a cancelled refresh is not a problem")
        #expect(app.needsReconnect == nil)
        expectUntouched(app, "cancelled")
    }

    @Test func aNetworkErrorKeepsTheShelfAndSaysOfflineKindly() async {
        let (app, sync) = await shelf()
        await sync.queueLibrary([.failure(CloudError.offline)])
        await app.refresh()
        #expect(app.library.syncProblem == .offline)
        expectUntouched(app, "offline")
        await sync.queueLibrary([.failure(URLError(.networkConnectionLost))])
        await app.refresh()
        #expect(app.library.syncProblem == .offline)
        expectUntouched(app, "connection lost")
    }

    @Test(arguments: [CloudError.server(status: 503), .server(status: 500), .rateLimited(retryAfter: 30), .unexpectedResponse("library cut short at 100 of 140")])
    func serverTroubleKeepsTheShelfAndSpeaksPlainly(_ error: CloudError) async throws {
        let (app, sync) = await shelf()
        await sync.queueLibrary([.failure(error)])
        await app.refresh()
        guard case let .other(message)? = app.library.syncProblem else { Issue.record("expected a problem line"); return }
        #expect(message == FriendlyError.server.message)
        #expect(app.needsReconnect == nil)
        expectUntouched(app, "server trouble")
    }

    @Test func anEmptyListingDuringTroubleIsAskedAgainBeforeAnyBookLeaves() async {
        let (app, sync) = await shelf()
        await sync.queueLibrary([.success([]), .success([eden, mistborn, wind])])
        await app.refresh()
        expectUntouched(app, "one blank listing")
        #expect(await sync.libraryFetches == 3)
        // A blank listing followed by an error: still nothing leaves.
        await sync.queueLibrary([.success([]), .failure(CloudError.server(status: 502))])
        await app.refresh()
        expectUntouched(app, "blank, then an error")
    }

    @Test func anEmptyListingTwiceInARowReallyIsEmpty() async {
        let (app, sync) = await shelf()
        await sync.queueLibrary([.success([]), .success([])])
        await app.refresh()
        #expect(app.library.books.isEmpty, "he cleared his Cloud: cloud-only books leave")
        #expect(app.account != nil)
    }

    /// The session layer only says `authenticationRequired` once a renewed token was also refused
    /// (GatefoldCloud's SessionTests). Even then: same account, same shelf, a polite ask to sign in again.
    @Test func aConfirmedSignInProblemKeepsEverythingAndAsksPolitely() async {
        let (app, sync) = await shelf()
        await sync.queueLibrary([.failure(CloudError.authenticationRequired)])
        await app.refresh()
        #expect(app.needsReconnect == "reader@example.com")
        #expect(app.library.syncProblem == .signInExpired)
        expectUntouched(app, "sign in again")
        await app.apply(.authenticationRequired)
        expectUntouched(app, "outbox asked too")
    }

    @Test func aSecondWindowStartingDoesNotStartAgain() async {
        let (app, sync) = await shelf()
        await sync.setEmptyAccountReads(5)
        await app.start() // the Duo's other scene
        expectUntouched(app, "second start")
        #expect(await sync.libraryFetches == 1)
    }

    @Test func aKeychainThatReadsEmptyForAMomentAtLaunchIsNotASignOut() async {
        AppModel.keychainRetryDelay = .milliseconds(10)
        UserDefaults.standard.set("R", forKey: "accountInitial") // signed in last launch
        let sync = StubSync()
        await sync.setEmptyAccountReads(2)
        await sync.setLibrary(.success([eden, mistborn, wind]))
        let app = AppModel(sync: sync, libraryRoot: URL.temporaryDirectory.appending(path: "refresh-safety-\(UUID().uuidString)"))
        await app.start()
        expectUntouched(app, "read again")
    }

    @Test func aWindowClosingWhileTheKeychainIsLookedAtAgainLeavesItToTheNextWindow() async {
        AppModel.keychainRetryDelay = .milliseconds(200)
        UserDefaults.standard.set("R", forKey: "accountInitial")
        let sync = StubSync()
        await sync.setEmptyAccountReads(4) // the first window's read and its three looks again
        await sync.setLibrary(.success([eden, mistborn, wind]))
        let app = AppModel(sync: sync, libraryRoot: URL.temporaryDirectory.appending(path: "refresh-safety-\(UUID().uuidString)"))
        let first = Task { await app.start() }
        first.cancel()
        await first.value
        #expect(app.account == nil)
        await app.start() // the next window
        expectUntouched(app, "next window")
    }
}

/// No raw Swift or Foundation error text ever reaches the screen.
@Suite struct FriendlyErrorTests {
    static let raw = ["Swift.", "Error", "error ", "NSURL", "NSCocoa", "operation couldn", "(", "CancellationError"]

    @Test(arguments: [CancellationError() as any Error, URLError(.cancelled), CocoaError(.userCancelled),
                      NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)])
    func cancellationIsNeverShown(_ error: any Error) {
        #expect(FriendlyError.message(for: error) == nil)
        #expect(LibraryStore.SyncProblem(error) == nil)
    }

    @Test(arguments: [
        CloudError.notSignedIn, .noAccount, .invalidCredentials, .authenticationRequired, .notFound, .rateLimited(retryAfter: nil),
        .server(status: 500), .http(status: 418, message: "I'm a teapot"), .offline, .network("The network connection was lost."),
        .clientCredentialsUnavailable, .fileTooSmall(bytes: 12), .checksumMismatch, .deleteNotApplied, .unexpectedResponse("note uuid"),
    ])
    func everyCloudErrorHasKindWords(_ error: CloudError) throws {
        let message = try #require(FriendlyError.message(for: error))
        for fragment in Self.raw { #expect(!message.contains(fragment), "\(error) → \(message)") }
        #expect(error.localizedDescription == message, "even a stray localizedDescription reads kindly")
    }

    @Test(arguments: [NSError(domain: "ReadiumShared.ReadError", code: 3), DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad")) as any Error,
                      URLError(.badURL), URLError(.notConnectedToInternet), URLError(.badServerResponse), CocoaError(.fileReadNoSuchFile)])
    func anythingElseStillHasKindWords(_ error: any Error) throws {
        let message = try #require(FriendlyError.message(for: error))
        for fragment in Self.raw { #expect(!message.contains(fragment), "\(error) → \(message)") }
    }

    @Test func theShelfLineIsNeverRawText() {
        guard case let .other(message)? = LibraryStore.SyncProblem(NSError(domain: "Foo", code: 3)) else { Issue.record("expected .other"); return }
        #expect(message == FriendlyError.unknown.message)
    }

    @Test func retryIsOfferedWhereItCanHelp() {
        #expect(FriendlyError.offline.isRetryable && FriendlyError.server.isRetryable && FriendlyError.unknown.isRetryable)
        #expect(!FriendlyError.wrongPassword.isRetryable && !FriendlyError.cancelled.isRetryable)
    }
}

/// The sign-in hint's words, for every slip `EmailCheck` names (the rules are tested in GatefoldCore).
@Suite struct EmailHintTests {
    @Test func arisTypoGetsAKindHint() {
        let problem = EmailCheck.problem("ari@mendelow@me")
        #expect(problem == .tooManyAts)
        #expect(SignInFlow.hint(for: .tooManyAts).contains("One @"))
    }

    @Test func everySlipHasWords() {
        for problem in [EmailCheck.Problem.space, .missingAt, .tooManyAts, .missingName, .missingDomain, .missingDot] {
            #expect(!SignInFlow.hint(for: problem).isEmpty)
        }
    }
}
