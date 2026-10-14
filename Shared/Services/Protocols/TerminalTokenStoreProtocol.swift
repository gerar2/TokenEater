import Foundation

enum TerminalTokenStoreError: Error, Equatable {
    /// Not shaped like a `claude setup-token` token (see `TerminalTokenFormat`).
    case implausibleToken
    case writeFailed(String)
}

/// Stores each profile's terminal token (from `claude setup-token`) in the
/// login Keychain under `TerminalTokenKeychain.service(for:)`, written through
/// `/usr/bin/security` so the generated shell functions can read it back with
/// `security find-generic-password -w` without an access prompt. TokenEater
/// itself never reads the secret back. See `docs/terminal-accounts-plan.md` §3.1.
protocol TerminalTokenStoreProtocol: Sendable {
    /// Validates and stores (replacing any previous token). The token must
    /// never reach a process's argv. Blocking: call off the main thread.
    func save(token: String, profileID: UUID, profileName: String) throws
    /// Whether a token is stored (attributes only, the secret is not read).
    func exists(profileID: UUID) -> Bool
    func delete(profileID: UUID)
}
