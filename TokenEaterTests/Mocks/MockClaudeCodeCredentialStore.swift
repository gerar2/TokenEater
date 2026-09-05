import Foundation

final class MockClaudeCodeCredentialStore: ClaudeCodeCredentialStoreProtocol, @unchecked Sendable {
    /// Live reads keyed by config dir (`"default"` for nil).
    var reads: [String: ClaudeCodeCredentialRead] = [:]
    var readCallCount = 0
    var writeCallCount = 0
    var writeError: Error?
    var lastWrittenCredentials: OAuthCredentials?
    var lastWrittenBacking: ClaudeCodeCredentialBacking?
    var lastWrittenRaw: [String: Any]?

    static func key(_ configDir: String?) -> String { configDir ?? "default" }

    func stub(configDir: String?, credentials: OAuthCredentials, backing: ClaudeCodeCredentialBacking = .keychain(service: "Claude Code-credentials"), raw: [String: Any]? = nil) {
        let payload = raw ?? ClaudeCredentialsPayload.merge(credentials, into: [:])
        reads[Self.key(configDir)] = ClaudeCodeCredentialRead(credentials: credentials, raw: payload, backing: backing)
    }

    func read(configDir: String?) -> ClaudeCodeCredentialRead? {
        readCallCount += 1
        return reads[Self.key(configDir)]
    }

    func exists(configDir: String?) -> Bool {
        reads[Self.key(configDir)] != nil
    }

    func write(_ credentials: OAuthCredentials, raw: [String: Any], backing: ClaudeCodeCredentialBacking) throws {
        writeCallCount += 1
        if let writeError { throw writeError }
        lastWrittenCredentials = credentials
        lastWrittenBacking = backing
        lastWrittenRaw = raw
    }
}
