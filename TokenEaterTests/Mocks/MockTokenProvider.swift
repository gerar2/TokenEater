import Foundation

final class MockTokenProvider: TokenProviderProtocol, @unchecked Sendable {
    var token: String?
    var _isBootstrapped: Bool = true
    var _hasTokenSource: Bool = true
    var bootstrapError: Error?
    var bootstrapCallCount = 0
    var currentTokenCallCount = 0
    var invalidateCallCount = 0
    var refreshTokenIfChangedCallCount = 0
    /// What `refreshTokenIfChanged()` returns. Tests flip this to simulate an
    /// account swap detected on the Keychain.
    var tokenDidChange = false
    /// Multi-profile: what `ensureFreshToken` reports and the exposed state.
    var readiness: TokenReadiness = .ready
    /// Consumed first, in order, before falling back to `readiness`. Lets a
    /// test answer `.ready` to the pre-fetch check and something else to the
    /// forced post-401 check.
    var readinessQueue: [TokenReadiness] = []
    var ensureFreshTokenCallCount = 0
    var lastEnsureForce: Bool?
    var ensureForceHistory: [Bool] = []
    var _credentialState: ProfileCredentialState = .unknown
    /// When set, `invalidateToken()` swaps `token` to it: simulates a
    /// provider that renews / re-reads a rotated token after a 401.
    var rotatedToken: String?
    /// When true, `invalidateToken()` clears `token`: simulates a source
    /// that vanished between the fetch and the re-read.
    var dropTokenOnInvalidate = false

    var isBootstrapped: Bool { _isBootstrapped }
    var credentialState: ProfileCredentialState { _credentialState }

    func ensureFreshToken(force: Bool) async -> TokenReadiness {
        ensureFreshTokenCallCount += 1
        lastEnsureForce = force
        ensureForceHistory.append(force)
        if !readinessQueue.isEmpty {
            return readinessQueue.removeFirst()
        }
        return readiness
    }

    func currentToken() -> String? {
        currentTokenCallCount += 1
        return token
    }

    func hasTokenSource() -> Bool {
        _hasTokenSource
    }

    func invalidateToken() {
        invalidateCallCount += 1
        if dropTokenOnInvalidate {
            token = nil
        } else if let rotatedToken {
            token = rotatedToken
        }
    }

    func refreshTokenIfChanged() -> Bool {
        refreshTokenIfChangedCallCount += 1
        return tokenDidChange
    }

    func bootstrap() throws {
        bootstrapCallCount += 1
        if let error = bootstrapError { throw error }
        _isBootstrapped = true
    }
}
