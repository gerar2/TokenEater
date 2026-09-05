import Foundation
import Security
import os.log

private let logger = Logger(subsystem: "com.tokeneater.app", category: "ProfileCredentialVault")

/// TokenEater's own per-profile credential storage: one Keychain generic
/// password per profile (service `com.tokeneater.profile-credentials`,
/// account = profile id, data = JSON-encoded `OAuthCredentials`).
///
/// Why a separate item rather than Claude Code's: Claude Code's item ACL
/// trusts `/usr/bin/security` only, so every direct read of it would prompt.
/// Items created here belong to TokenEater, so reads and updates are silent
/// (and every query still carries `kSecUseAuthenticationUISkip`, so a lost ACL
/// fails quietly instead of beachballing a headless app). For linked profiles
/// this is a cache re-synced from the live store; for managed (captured)
/// profiles it is the only copy of the refresh-token chain.
///
/// Not unit-tested on purpose (it talks to the real Keychain); consumers are
/// tested against `InMemoryProfileCredentialVault`.
final class ProfileCredentialVault: ProfileCredentialVaultProtocol, @unchecked Sendable {
    static let service = "com.tokeneater.profile-credentials"
    static let label = "TokenEater profile credentials"

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    init() {}

    func load(profileID: UUID) -> OAuthCredentials? {
        var query = silentQuery(profileID: profileID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                logger.info("vault load failed with status \(status, privacy: .public)")
            }
            return nil
        }
        return try? decoder.decode(OAuthCredentials.self, from: data)
    }

    func save(_ credentials: OAuthCredentials, profileID: UUID) throws {
        guard let data = try? encoder.encode(credentials) else {
            throw ProfileCredentialVaultError.encoding
        }
        var attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: Self.label,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        var status = performSave(profileID: profileID, attributes: attributes)
        if status == errSecParam {
            // The file-based macOS Keychain does not support kSecAttrAccessible
            // on every version; drop it rather than lose the save (the item's
            // ACL still restricts it to TokenEater).
            attributes[kSecAttrAccessible as String] = nil
            status = performSave(profileID: profileID, attributes: attributes)
        }
        guard status == errSecSuccess else {
            logger.error("vault save failed with status \(status, privacy: .public)")
            throw ProfileCredentialVaultError.keychain(status: status)
        }
    }

    func delete(profileID: UUID) {
        let status = SecItemDelete(silentQuery(profileID: profileID) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            logger.info("vault delete failed with status \(status, privacy: .public)")
        }
    }

    // MARK: - Private

    /// Update in place when the item exists (keeps its ACL and creation date),
    /// otherwise add it.
    private func performSave(profileID: UUID, attributes: [String: Any]) -> OSStatus {
        let query = silentQuery(profileID: profileID)
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            return SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        }
        let item = baseQuery(profileID: profileID).merging(attributes) { _, new in new }
        return SecItemAdd(item as CFDictionary, nil)
    }

    private func baseQuery(profileID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: profileID.uuidString,
        ]
    }

    private func silentQuery(profileID: UUID) -> [String: Any] {
        var query = baseQuery(profileID: profileID)
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        return query
    }
}
