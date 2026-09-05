import Foundation

final class MockOAuthTokenRefresher: OAuthTokenRefresherProtocol, @unchecked Sendable {
    var stubbedResult: OAuthCredentials?
    var stubbedError: Error?
    var refreshCallCount = 0
    var lastInput: OAuthCredentials?

    func refresh(_ credentials: OAuthCredentials, proxyConfig: ProxyConfig?) async throws -> OAuthCredentials {
        refreshCallCount += 1
        lastInput = credentials
        if let stubbedError { throw stubbedError }
        if let stubbedResult { return stubbedResult }
        // Default: rotate both tokens, valid for 8 hours.
        return OAuthCredentials(
            accessToken: credentials.accessToken + "-refreshed",
            refreshToken: (credentials.refreshToken ?? "rt") + "-rotated",
            expiresAt: Date().addingTimeInterval(8 * 3600),
            scopes: credentials.scopes,
            subscriptionType: credentials.subscriptionType
        )
    }
}
