import Foundation

/// Which backing store a live credential read came from. A write-back always
/// targets the same backing so Claude Code finds the rotated tokens where it
/// keeps them.
enum ClaudeCodeCredentialBacking: Equatable {
    case keychain(service: String)
    case file(path: String)
    /// Claude Desktop's `config.json` (Electron safeStorage). Token only,
    /// never writable.
    case claudeDesktop

    var isWritable: Bool {
        if case .claudeDesktop = self { return false }
        return true
    }
}

struct ClaudeCodeCredentialRead {
    let credentials: OAuthCredentials
    /// The whole parsed payload, for merge-preserving write-back (`[:]` for
    /// the Claude Desktop path).
    let raw: [String: Any]
    let backing: ClaudeCodeCredentialBacking
}

enum ClaudeCodeCredentialStoreError: Error, Equatable {
    case readOnlyBacking
    case writeFailed(String)
    case serializationFailed
}

/// Reads and writes Claude Code's own credential store for a config directory
/// (`nil` = default `~/.claude`). Reads may shell out to `/usr/bin/security`
/// (up to a few seconds): never call from the main thread.
protocol ClaudeCodeCredentialStoreProtocol: Sendable {
    func read(configDir: String?) -> ClaudeCodeCredentialRead?
    func exists(configDir: String?) -> Bool
    /// Writes to the SAME backing the read came from, merging into `raw` so
    /// unknown keys survive. Throws `ClaudeCodeCredentialStoreError`.
    func write(_ credentials: OAuthCredentials, raw: [String: Any], backing: ClaudeCodeCredentialBacking) throws
}
