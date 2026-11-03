import Foundation
import GatefoldCore
import Observation
import SwiftUI

/// App-wide state: the sync service, the shelf, reading preferences and where the user is.
@MainActor @Observable
final class AppModel {
    let sync: any SyncService
    let library: LibraryStore
    private(set) var account: CloudAccount? {
        didSet {
            guard hasStarted || account != nil else { return }
            accountInitial = account.flatMap { $0.email.first.map { String($0).uppercased() } }
        }
    }
    /// The account's initial from the last launch, so the avatar is right from the first frame instead
    /// of flipping from a silhouette once the sign-in has been read.
    private(set) var accountInitial: String? {
        didSet { UserDefaults.standard.set(accountInitial, forKey: Keys.accountInitial) }
    }
    /// The saved sign-in has been read, so a missing account means signed out, not "not yet known".
    private(set) var hasStarted = false
    /// The Cloud turned the saved sign-in away (expired or revoked). Downloaded books and places stay;
    /// the library offers to reconnect with this email.
    private(set) var needsReconnect: String?
    /// The open reader, so coming back to the app can ask the Cloud where the other device is.
    weak var activeReader: ReaderModel?
    @ObservationIgnored private var lastForegroundRefresh = Date.distantPast
    var preferences: PreferencesStore {
        didSet { savePreferences() }
    }

    /// Whether the welcome has been seen (signed in, or chose to read without an account).
    var hasOnboarded: Bool {
        didSet { UserDefaults.standard.set(hasOnboarded, forKey: Keys.onboarded) }
    }

    /// The open book, if any. Remembered across launches, so that if iOS ends Gatefold while he is
    /// reading (or he relaunches it), it reopens at his page instead of the shelf.
    var openBookID: String? {
        didSet {
            guard LaunchOptions.allowsReopen else { return }
            UserDefaults.standard.set(openBookID, forKey: Keys.reopenBook)
        }
    }
    /// The book being reopened at launch, until its reader is up.
    var reopenBookID: String?
    /// The first turn asked for on the reopen picture (true is forward), played when the live page lands.
    var reopenQueuedTurn: Bool?

    /// The reopen picture's leaf, lifted at the tap and landed on the live page.
    let reopenCurl = CurlModel()

    @discardableResult
    func queueReopenTurn(forward: Bool) -> Bool {
        guard reopenQueuedTurn == nil else { return false }
        reopenQueuedTurn = forward
        readerLog.notice("reopen: a \(forward ? "forward" : "back", privacy: .public) turn asked of the picture at \(LaunchClock.sinceLaunch, privacy: .public) s after launch; kept for the live page")
        return true
    }

    static var keychainRetryDelay: Duration = .seconds(1)

    private enum Keys {
        static let onboarded = "onboarded"
        static let preferences = "readerPreferences"
        static let accountInitial = "accountInitial"
        static let reopenBook = "reopenBook"
    }

    init(sync: (any SyncService)? = nil, libraryRoot: URL = LibraryStore.defaultRoot) {
        if LaunchOptions.resetState {
            UserDefaults.standard.removeObject(forKey: Keys.onboarded)
            UserDefaults.standard.removeObject(forKey: Keys.preferences)
            UserDefaults.standard.removeObject(forKey: Keys.accountInitial)
            UserDefaults.standard.removeObject(forKey: Keys.reopenBook)
        }
        self.accountInitial = UserDefaults.standard.string(forKey: Keys.accountInitial)
        let service = sync ?? Self.makeSyncService()
        self.sync = service
        self.library = LibraryStore(sync: service, root: libraryRoot)
        if LaunchOptions.resetState { library.wipe() }
        LibraryView.startedEmpty = library.books.isEmpty

        var prefs = UserDefaults.standard.data(forKey: Keys.preferences)
            .flatMap { try? JSONDecoder().decode(PreferencesStore.self, from: $0) }
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        if prefs == nil {
            // First launch: the book's type size follows Dynamic Type, then it's the reader's own.
            var first = ReaderPreferences()
            // A regular-width screen (iPad) starts a step larger, as a printed page would be read there.
            first.fontScale = ReaderPreferences.initialFontScale(forContentSizeRank: Self.contentSizeRank, regularWidth: pad)
            #if DEBUG
            if let scale = LaunchOptions.fontScale { first.fontScale = scale }
            #endif
            prefs = PreferencesStore(defaults: first)
        } else if prefs?.densityVersion != PreferencesStore.currentDensity {
            // Saved before build 15: a size never changed moves to the new, larger first size.
            prefs?.adoptCurrentDensity(
                untouched: ReaderPreferences.legacyInitialFontScale(forContentSizeRank: Self.contentSizeRank, regularWidth: pad),
                now: ReaderPreferences.initialFontScale(forContentSizeRank: Self.contentSizeRank, regularWidth: pad)
            )
            if let moved = prefs, let data = try? JSONEncoder().encode(moved) { UserDefaults.standard.set(data, forKey: Keys.preferences) }
        }
        self.preferences = prefs!
        self.hasOnboarded = LaunchOptions.skipWelcome || UserDefaults.standard.bool(forKey: Keys.onboarded)
        if let theme = LaunchOptions.theme {
            // A screenshot switch: every book wears this theme, whatever a book was given before.
            var forced = preferences.defaults
            forced.theme = theme
            forced.matchSystemAppearance = false
            preferences = PreferencesStore(defaults: forced)
        }
        if let turn = LaunchOptions.pageTurn {
            var forced = preferences.defaults
            forced.pageTurn = turn
            preferences = PreferencesStore(defaults: forced)
        }
        if LaunchOptions.openBook == nil, LaunchOptions.allowsReopen, hasOnboarded,
           let id = UserDefaults.standard.string(forKey: Keys.reopenBook) {
            reopenBookID = id
            // His book is what the first frames are for: start reading it in before the shelf.
            if let book = library.book(id), let url = library.fileURL(of: book) { BookOpener.shared.openEarly(url) }
        }
        self.openBookID = LaunchOptions.openBook ?? reopenBookID
    }

    /// PocketBook Cloud, unless a launch argument asks for the fake (previews, UI tests, screenshots).
    static func makeSyncService() -> any SyncService {
        if LaunchOptions.fakeCloud {
            return FakeSyncService(
                signedIn: LaunchOptions.signedIn,
                scenario: LaunchOptions.fakeScenario,
                latency: LaunchOptions.noLatency || LaunchOptions.isUITest ? .zero : .milliseconds(450)
            )
        }
        let storage = URL.applicationSupportDirectory.appending(path: "GatefoldCloud", directoryHint: .isDirectory)
        return PocketBookCloud(configuration: .init(storageDirectory: storage))
    }

    /// Every window runs `start()` (the Duo can show more than one scene); only the first one starts.
    @ObservationIgnored private var startCalled = false

    func start() async {
        guard !startCalled else { return }
        startCalled = true
        // A clean start forgets the Cloud sign-in too (its tokens live in the Keychain, which survives reinstalls).
        // The fake Cloud's sign-in comes from its own launch argument, so a reset leaves it alone.
        if LaunchOptions.resetState, !LaunchOptions.fakeCloud, await sync.account != nil { await sync.signOut() }
        var saved = await sync.account
        if saved == nil, accountInitial != nil {
            // Signed in last time, yet nothing reads back: the Keychain can read empty for a moment (a
            // prewarmed launch, data protection). Look again before calling it signed out.
            for _ in 0..<3 where saved == nil {
                try? await Task.sleep(for: Self.keychainRetryDelay)
                saved = await sync.account
            }
            // The window that started us closed mid-wait: leave the account alone for the next one to read.
            if saved == nil, Task.isCancelled { startCalled = false; return }
        }
        hasStarted = true
        account = saved
        if saved == nil { accountInitial = nil }
        // Listen before the first fetch, so its announcement lands too.
        let changes = sync.changes()
        Task { [weak self] in
            for await change in changes {
                guard let self else { return }
                await self.apply(change)
            }
        }
        // Stamp first, so the launch's own `.active` doesn't fetch the library a second time.
        lastForegroundRefresh = Date()
        await refresh()
        if LaunchOptions.downloadAll {
            for book in library.books where !book.isOnDevice {
                await library.download(book)
            }
        }
        #if DEBUG
        // Screenshots and UI tests: the InkPad reads on while the book is open here.
        let defaults = UserDefaults.standard
        if let fake = sync as? FakeSyncService, let id = LaunchOptions.openBook, defaults.object(forKey: "GatefoldRemoteAheadAfter") != nil {
            let after = defaults.double(forKey: "GatefoldRemoteAheadAfter")
            let to = defaults.object(forKey: "GatefoldRemoteAheadTo") == nil ? 0.3 : defaults.double(forKey: "GatefoldRemoteAheadTo")
            Task {
                try? await Task.sleep(for: .seconds(after))
                await fake.simulateRemoteRead(bookID: id, totalProgression: to)
                readerLog.notice("debug: InkPad read on to \(to, privacy: .public), reader open: \(self.activeReader != nil, privacy: .public)")
                try? await Task.sleep(for: .milliseconds(200))
                await activeReader?.checkRemote()
            }
        }
        #endif
    }

    /// Applies one change from the sync service. Never fetches: the real service announces
    /// `.library` after every fetch, so fetching here would loop.
    func apply(_ change: CloudChange) async {
        switch change {
        case .library, .bookAdded, .bookUpdated:
            // A fetch that finished after sign-out; its books no longer belong on the shelf.
            guard account != nil else { return }
        default:
            break
        }
        switch change {
        case let .library(books):
            await library.merge(books)
        case let .bookAdded(book), let .bookUpdated(book):
            await library.merge([book])
        case let .bookRemoved(fastHash):
            library.cloudBookRemoved(fastHash)
        case let .remotePosition(fastHash, position), let .positionSuperseded(fastHash, position):
            library.update(fastHash) {
                $0.remote = position
                $0.noteOtherDevice(position)
            }
        case let .signedIn(account):
            self.account = account
            needsReconnect = nil
        case .signedOut:
            account = nil
            needsReconnect = nil
            library.forgetCloudOnlyBooks()
        case .authenticationRequired:
            // Keep the shelf and the account's name; the library offers to sign in again.
            needsReconnect = account?.email ?? needsReconnect ?? ""
        case .annotations, .annotationSaved, .outbox:
            break
        }
    }

    func didSignIn(_ account: CloudAccount) async {
        self.account = account
        needsReconnect = nil
        hasOnboarded = true
        await library.refresh()
    }

    func signOut() async {
        await sync.signOut()
        account = nil
        needsReconnect = nil
        library.forgetCloudOnlyBooks()
    }

    /// Fetching the shelf can also discover that the sign-in has expired.
    func refresh() async {
        await library.refresh()
        if library.syncProblem == .signInExpired { needsReconnect = account?.email ?? needsReconnect ?? "" }
    }

    /// Back in the foreground: refresh the shelf (at most every half minute) and ask where the other
    /// device is for the open book.
    func didBecomeActive() async {
        guard account != nil else { return }
        if Date().timeIntervalSince(lastForegroundRefresh) > 30 {
            lastForegroundRefresh = Date()
            await refresh()
        }
        await activeReader?.checkRemote()
        await activeReader?.highlights.refresh()
    }

    /// Sign-in first needs PocketBook's web-app client pair, which takes a while to fetch; start it
    /// while the reader is still admiring the welcome screen or typing their email.
    func prepareSignIn() async {
        await (sync as? PocketBookCloud)?.prepareSignIn()
    }

    /// Leaving the app or closing a book: send the place now rather than after the debounce.
    func sendPlaceNow() async {
        await library.sendPendingPushes()
    }

    private func savePreferences() {
        if let data = try? JSONEncoder().encode(preferences) {
            UserDefaults.standard.set(data, forKey: Keys.preferences)
        }
    }

    private static var contentSizeRank: Int {
        let order: [UIContentSizeCategory] = [
            .extraSmall, .small, .medium, .large, .extraLarge, .extraExtraLarge, .extraExtraExtraLarge,
            .accessibilityMedium, .accessibilityLarge, .accessibilityExtraLarge, .accessibilityExtraExtraLarge, .accessibilityExtraExtraExtraLarge,
        ]
        return order.firstIndex(of: UIApplication.shared.preferredContentSizeCategory) ?? 3
    }
}
