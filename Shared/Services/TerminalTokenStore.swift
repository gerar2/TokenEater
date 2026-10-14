import Foundation

/// Phase 0 placeholder: lane T1 replaces this file with the `/usr/bin/security`
/// implementation described in `docs/terminal-accounts-plan.md` §3.1.
final class TerminalTokenStore: TerminalTokenStoreProtocol, @unchecked Sendable {
    init() {}

    func save(token: String, profileID: UUID, profileName: String) throws {
        guard TerminalTokenFormat.isPlausible(token) else { throw TerminalTokenStoreError.implausibleToken }
        throw TerminalTokenStoreError.writeFailed("not implemented")
    }

    func exists(profileID: UUID) -> Bool { false }

    func delete(profileID: UUID) {}
}
