import Foundation
import Observation
import Security

/// The OPDS catalogs the reader can browse: two free libraries built in, and their own (a calibre or
/// Calibre-Web server at home, Kavita, Komga, any OPDS address). Addresses and user names are kept with
/// the shelf; passwords only in the Keychain.
@MainActor @Observable
final class CatalogShelf {
    struct Catalog: Codable, Identifiable, Hashable, Sendable {
        var id: String
        var name: String
        var url: URL
        var user: String?
        var about: String?
        var builtIn = false
    }

    /// Free books, ready with no setup. Project Gutenberg's catalog of books whose US copyright has ended,
    /// and Standard Ebooks' newest releases, the only feed it serves without a Patrons Circle membership.
    static let builtIn: [Catalog] = [
        Catalog(id: "gutenberg", name: "Project Gutenberg", url: URL(string: "https://www.gutenberg.org/ebooks.opds/")!,
                about: "Free books whose copyright has ended", builtIn: true),
        Catalog(id: "standard-ebooks", name: "Standard Ebooks", url: URL(string: "https://standardebooks.org/feeds/atom/new-releases")!,
                about: "Carefully made free editions of classics, newest first", builtIn: true),
    ]

    private(set) var own: [Catalog] = [] {
        didSet { save() }
    }
    var all: [Catalog] { Self.builtIn + own }

    private let savedURL: URL
    private let keychain: any CatalogPasswords

    init(root: URL = LibraryStore.defaultRoot, keychain: any CatalogPasswords = CatalogKeychain()) {
        savedURL = root.appending(path: "catalogs.json")
        self.keychain = keychain
        if let data = try? Data(contentsOf: savedURL), let saved = try? JSONDecoder().decode([Catalog].self, from: data) {
            own = saved
        }
    }

    @discardableResult
    func add(name: String, url: URL, user: String?, password: String?) -> Catalog {
        let user = user?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let catalog = Catalog(id: UUID().uuidString, name: trimmedName.isEmpty ? (url.host() ?? url.absoluteString) : trimmedName, url: url, user: user)
        if user != nil, let password, !password.isEmpty { keychain.set(password, for: catalog.id) }
        own.append(catalog)
        return catalog
    }

    func remove(_ catalog: Catalog) {
        keychain.set(nil, for: catalog.id)
        own.removeAll { $0.id == catalog.id }
    }

    /// Forgets every catalog the reader added, and their passwords (a clean start).
    func forgetAll() {
        for catalog in own { keychain.set(nil, for: catalog.id) }
        own = []
    }

    func credential(for catalog: Catalog) -> CatalogClient.Credential? {
        guard let user = catalog.user, let password = keychain.password(for: catalog.id) else { return nil }
        return CatalogClient.Credential(user: user, password: password)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(own) { try? data.write(to: savedURL, options: .atomic) }
    }
}

/// Where catalog passwords are kept: the Keychain in the app, memory in tests (a test build has no Keychain).
protocol CatalogPasswords: Sendable {
    func set(_ password: String?, for id: String)
    func password(for id: String) -> String?
}

/// Catalog passwords, one Keychain item per catalog, readable only on this device once it has been unlocked.
struct CatalogKeychain: CatalogPasswords {
    var service = "bot.ouro.gatefold.catalogs"

    func set(_ password: String?, for id: String) {
        let match: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id,
                                    kSecUseDataProtectionKeychain as String: true]
        SecItemDelete(match as CFDictionary)
        guard let password else { return }
        var item = match
        item[kSecValueData as String] = Data(password.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    func password(for id: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id,
                                    kSecUseDataProtectionKeychain as String: true, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var found: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let data = found as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
