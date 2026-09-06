import Foundation

enum ProfileCredentialVaultError: Error, Equatable {
    case keychain(status: Int32)
    case encoding
}

/// TokenEater's own per-profile credential storage (one Keychain generic
/// password per profile, service `com.tokeneater.profile-credentials`,
/// account = profile id). Items are created by TokenEater, so reads never
/// trigger the ACL prompt the Claude Code item does.
protocol ProfileCredentialVaultProtocol: Sendable {
    func load(profileID: UUID) -> OAuthCredentials?
    func save(_ credentials: OAuthCredentials, profileID: UUID) throws
    func delete(profileID: UUID)
}
