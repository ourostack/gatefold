import Foundation
import Security

/// What survives an app restart: the account and its tokens. Never the password.
public struct StoredSession: Sendable, Codable, Hashable {
    public var account: CloudAccount
    public var token: CloudToken
    public init(account: CloudAccount, token: CloudToken) {
        self.account = account
        self.token = token
    }
}

public protocol TokenStore: Sendable {
    func load() async -> StoredSession?
    func save(_ session: StoredSession) async throws
    func clear() async
}

public actor InMemoryTokenStore: TokenStore {
    private var value: StoredSession?
    public init(_ value: StoredSession? = nil) { self.value = value }
    public func load() -> StoredSession? { value }
    public func save(_ session: StoredSession) { value = session }
    public func clear() { value = nil }
}

public enum KeychainError: Error, Equatable {
    case unavailable
    case status(OSStatus)
}

/// Stores the session as one generic-password item, readable after first unlock and never
/// synced to iCloud Keychain.
public struct KeychainTokenStore: TokenStore {
    public let service: String
    public let account: String

    public init(service: String = "bot.ouro.gatefold.pbcloud", account: String = "session") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecUseDataProtectionKeychain as String: true]
    }

    public func load() async -> StoredSession? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(StoredSession.self, from: data)
    }

    public func save(_ session: StoredSession) async throws {
        let data = try JSONEncoder().encode(session)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        switch status {
        case errSecSuccess: return
        case errSecMissingEntitlement, errSecInteractionNotAllowed, errSecNotAvailable, errSecNoSuchKeychain: throw KeychainError.unavailable
        default: throw KeychainError.status(status)
        }
    }

    public func clear() async {
        SecItemDelete(query as CFDictionary)
    }
}
