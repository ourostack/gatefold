import Foundation
import GatefoldCore
import Observation
import SwiftUI

/// App-wide state: the sync service, the shelf, reading preferences and where the user is.
@MainActor @Observable
final class AppModel {
    let sync: any SyncService
    let library: LibraryStore
    private(set) var account: CloudAccount?
    var preferences: PreferencesStore {
        didSet { savePreferences() }
    }

    /// Whether the welcome has been seen (signed in, or chose to read without an account).
    var hasOnboarded: Bool {
        didSet { UserDefaults.standard.set(hasOnboarded, forKey: Keys.onboarded) }
    }

    /// The open book, if any.
    var openBookID: String?

    private enum Keys {
        static let onboarded = "onboarded"
        static let preferences = "readerPreferences"
    }

    init(sync: (any SyncService)? = nil) {
        if LaunchOptions.resetState {
            UserDefaults.standard.removeObject(forKey: Keys.onboarded)
            UserDefaults.standard.removeObject(forKey: Keys.preferences)
        }
        let service = sync ?? FakeSyncService(
            signedIn: LaunchOptions.signedIn,
            latency: LaunchOptions.noLatency || LaunchOptions.isUITest ? .zero : .milliseconds(450)
        )
        self.sync = service
        self.library = LibraryStore(sync: service)
        if LaunchOptions.resetState { library.wipe() }

        var prefs = UserDefaults.standard.data(forKey: Keys.preferences)
            .flatMap { try? JSONDecoder().decode(PreferencesStore.self, from: $0) }
        if prefs == nil {
            // First launch: the book's type size follows Dynamic Type, then it's the reader's own.
            var first = ReaderPreferences()
            first.fontScale = ReaderPreferences.initialFontScale(forContentSizeRank: Self.contentSizeRank)
            prefs = PreferencesStore(defaults: first)
        }
        self.preferences = prefs!
        self.hasOnboarded = LaunchOptions.skipWelcome || UserDefaults.standard.bool(forKey: Keys.onboarded)
        if let theme = LaunchOptions.theme {
            preferences.updateDefaults {
                $0.theme = theme
                $0.matchSystemAppearance = false
            }
        }
        self.openBookID = LaunchOptions.openBook
    }

    func start() async {
        account = await sync.account
        await library.refresh()
        if LaunchOptions.downloadAll {
            for book in library.books where !book.isOnDevice {
                await library.download(book)
            }
        }
        Task { [weak self] in
            guard let self else { return }
            for await change in sync.changes() {
                switch change {
                case .library, .bookAdded, .bookUpdated, .bookRemoved, .signedIn, .signedOut, .authenticationRequired:
                    self.account = await self.sync.account
                    await self.library.refresh()
                case let .remotePosition(fastHash, position), let .positionSuperseded(fastHash, position):
                    self.library.update(fastHash) { $0.remote = position }
                case .annotations, .annotationSaved, .outbox:
                    break
                }
            }
        }
    }

    func didSignIn(_ account: CloudAccount) async {
        self.account = account
        hasOnboarded = true
        await library.refresh()
    }

    func signOut() async {
        await sync.signOut()
        account = nil
        library.forgetCloudOnlyBooks()
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
