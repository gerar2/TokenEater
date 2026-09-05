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
    var ensureFreshTokenCallCount = 0
    var lastEnsureForce: Bool?
    var _credentialState: ProfileCredentialState = .unknown

    var isBootstrapped: Bool { _isBootstrapped }
    var credentialState: ProfileCredentialState { _credentialState }

    func ensureFreshToken(force: Bool) async -> TokenReadiness {
        ensureFreshTokenCallCount += 1
        lastEnsureForce = force
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
