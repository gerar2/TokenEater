import Foundation

enum OAuthRefreshError: Error, Equatable {
    case noRefreshToken
    /// HTTP 400 / 401: the refresh token is revoked or already rotated away.
    case invalidGrant(status: Int, body: String)
    case http(status: Int)
    case network(String)
    case invalidResponse
}

/// Exchanges a refresh token for a new access token at Claude Code's OAuth
/// token endpoint (`POST https://platform.claude.com/v1/oauth/token`,
/// `grant_type=refresh_token`, Claude Code's public client id). Returns the
/// rotated credentials; the old refresh token is kept when the server sends
/// none, mirroring Claude Code.
protocol OAuthTokenRefresherProtocol: Sendable {
    func refresh(_ credentials: OAuthCredentials, proxyConfig: ProxyConfig?) async throws -> OAuthCredentials
}
