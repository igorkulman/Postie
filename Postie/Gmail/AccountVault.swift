import Foundation
import Security

nonisolated struct StoredAccount: Codable, Equatable, Sendable, Identifiable {
    let identity: GoogleIdentity
    var credentials: GoogleCredentials
    /// Orders accounts; the first one added is the default until another is chosen.
    let addedAt: Date

    var id: String { identity.id }
}

/// Where connected accounts live. The vault is the registry of accounts, not just of their tokens,
/// so an account never exists without its credentials or the other way round.
nonisolated protocol AccountVault: Sendable {
    func loadAll() throws -> [StoredAccount]
    func save(_ account: StoredAccount) throws
    func delete(id: String) throws
}

nonisolated struct KeychainError: Error, LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        String(localized: "The Keychain could not be accessed (error \(status)).")
    }
}

nonisolated struct KeychainAccountVault: AccountVault {
    private let service = "sk.kulman.Postie.google-accounts"

    private func query(id: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true
        ]
        if let id { query[kSecAttrAccount as String] = id }
        return query
    }

    func loadAll() throws -> [StoredAccount] {
        var request = query()
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [Data] else { throw KeychainError(status: status) }
        let decoder = JSONDecoder()
        return items.compactMap { try? decoder.decode(StoredAccount.self, from: $0) }
    }

    func save(_ account: StoredAccount) throws {
        let data = try JSONEncoder().encode(account)
        let update = SecItemUpdate(query(id: account.id) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(status: update) }
        var add = query(id: account.id)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func delete(id: String) throws {
        let status = SecItemDelete(query(id: id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

/// For previews and tests, which must never touch the real Keychain.
nonisolated final class MemoryAccountVault: AccountVault, @unchecked Sendable {
    private let lock = NSLock()
    private var accounts: [String: StoredAccount]

    init(_ accounts: [StoredAccount] = []) {
        self.accounts = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
    }

    func loadAll() throws -> [StoredAccount] { lock.withLock { Array(accounts.values) } }
    func save(_ account: StoredAccount) throws { lock.withLock { accounts[account.id] = account } }
    func delete(id: String) throws { lock.withLock { accounts[id] = nil } }
}
