import Foundation
import Security

/// The pointers this app last wrote, per account and book, so its own place is recognised when the
/// Cloud hands it back. The Cloud's position record has no device or client id, and a reinstall
/// wipes the outbox, so these are kept where a reinstall can't reach them.
public protocol PushedPlaces: Sendable {
    func load() -> [String: String]
    func save(_ places: [String: String])
}

public final class InMemoryPushedPlaces: PushedPlaces, @unchecked Sendable {
    private let lock = NSLock()
    private var places: [String: String]
    public init(_ places: [String: String] = [:]) { self.places = places }
    public func load() -> [String: String] { lock.withLock { places } }
    public func save(_ places: [String: String]) { lock.withLock { self.places = places } }
}

/// One generic-password item, kept on this device only. It survives deleting and reinstalling the app.
/// A Keychain that can't be reached (tests, a locked device before first unlock) just remembers nothing.
public struct KeychainPushedPlaces: PushedPlaces {
    public let service: String
    public let account: String

    public init(service: String = "bot.ouro.gatefold.pbcloud", account: String = "pushed-places") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecUseDataProtectionKeychain as String: true]
    }

    public func load() -> [String: String] {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    public func save(_ places: [String: String]) {
        guard let data = try? JSONEncoder().encode(places) else { return }
        if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

extension PocketBookCloud {
    static func placeKey(account: String?, fastHash: String) -> String { "\((account ?? "").lowercased())|\(fastHash)" }
}
