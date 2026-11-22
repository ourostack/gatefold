import Foundation
import Security

/// What survives an app restart: the account, its tokens, and the password and address he signed in
/// with, kept so the app can sign him in again on its own.
public struct StoredSession: Sendable, Codable, Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    public var account: CloudAccount
    public var token: CloudToken
    /// The password he signed in with, kept only in this device's Keychain so the app can sign him in
    /// again on its own when the Cloud refuses to renew the token. Nil for sessions saved before it was
    /// kept, and after the Cloud refused it. Never logged: `description` leaves it out.
    public var password: String?
    /// The address he typed to sign in, which `/user` may spell differently. Kept with the password.
    public var login: String?
    /// Re-sign-ins in a row the Cloud refused the kept password on. The Cloud refuses a correct password
    /// now and then with the same answer as a wrong one, so the password is forgotten only after
    /// `CloudSession.reSignInRefusalsBeforeForgetting` of them. Nil after a sign-in that worked.
    public var refusedReSignIns: Int?
    public init(account: CloudAccount, token: CloudToken, password: String? = nil, login: String? = nil) {
        self.account = account
        self.token = token
        self.password = password
        self.login = login
    }

    public var description: String { "StoredSession(account: \(account.email), password: \(password == nil ? "none" : "kept"))" }
    public var debugDescription: String { description }
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
