import Foundation
import os.log

private let logger = Logger(subsystem: "com.tokeneater.app", category: "OAuthTokenRefresher")

/// Exchanges a refresh token for a new access token at Claude Code's OAuth
/// token endpoint, the way Claude Code 2.1.x does it: same public client id,
/// same `anthropic-beta` header, same JSON body. The rotated refresh token
/// replaces the old one; when the server omits it the old one is kept.
///
/// Single-flight: callers refreshing the same refresh token share one request.
/// A refresh token is single-use on the server, so a second concurrent request
/// would burn the chain with an `invalid_grant`.
final class OAuthTokenRefresher: OAuthTokenRefresherProtocol, @unchecked Sendable {
    typealias HTTPTransport = @Sendable (URLRequest, ProxyConfig?) async throws -> (Data, HTTPURLResponse)

    static let endpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let betaHeader = "oauth-2025-04-20"
    static let timeout: TimeInterval = 30
    /// How much of an error body is kept for diagnostics.
    static let maxErrorBodyBytes = 1024

    private let transport: HTTPTransport
    private let now: @Sendable () -> Date
    private let userAgent: String
    private let inFlight = InFlightRefreshes()

    /// - Parameters:
    ///   - transport: replaces `URLSession` (tests). The default goes through
    ///     `URLSessionFactory` so the proxy setting applies.
    ///   - claudeCodeVersion: for the `User-Agent`; nil renders `0.0.0` like
    ///     `APIClient`.
    init(
        transport: HTTPTransport? = nil,
        claudeCodeVersion: String? = ProcessResolver.detectClaudeCodeVersion(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.transport = transport ?? Self.urlSessionTransport
        self.userAgent = "claude-code/\(claudeCodeVersion ?? "0.0.0")"
        self.now = now
    }

    func refresh(_ credentials: OAuthCredentials, proxyConfig: ProxyConfig?) async throws -> OAuthCredentials {
        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
            throw OAuthRefreshError.noRefreshToken
        }
        return try await inFlight.run(key: refreshToken) { [self] in
            try await self.perform(credentials, refreshToken: refreshToken, proxyConfig: proxyConfig)
        }
    }

    // MARK: - Private

    private struct TokenRequest: Encodable {
        let grantType: String
        let refreshToken: String
        let clientID: String
        let scope: String

        enum CodingKeys: String, CodingKey {
            case grantType = "grant_type"
            case refreshToken = "refresh_token"
            case clientID = "client_id"
            case scope
        }
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Double?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    private func perform(_ credentials: OAuthCredentials, refreshToken: String, proxyConfig: ProxyConfig?) async throws -> OAuthCredentials {
        let request = try makeRequest(refreshToken: refreshToken, scopes: credentials.scopes)

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport(request, proxyConfig)
        } catch let error as OAuthRefreshError {
            throw error
        } catch {
            logger.info("refresh transport failed: \(error.localizedDescription, privacy: .public)")
            throw OAuthRefreshError.network(error.localizedDescription)
        }

        switch response.statusCode {
        case 200:
            guard let payload = try? JSONDecoder().decode(TokenResponse.self, from: data),
                  !payload.accessToken.isEmpty else {
                throw OAuthRefreshError.invalidResponse
            }
            logger.info("refresh grant succeeded (rotated refresh token: \(payload.refreshToken != nil, privacy: .public))")
            return OAuthCredentials(
                accessToken: payload.accessToken,
                refreshToken: payload.refreshToken ?? credentials.refreshToken,
                expiresAt: payload.expiresIn.map { now().addingTimeInterval($0) },
                scopes: credentials.scopes,
                subscriptionType: credentials.subscriptionType
            )
        case 400, 401:
            let body = String(decoding: data.prefix(Self.maxErrorBodyBytes), as: UTF8.self)
            logger.info("refresh grant rejected with \(response.statusCode, privacy: .public)")
            throw OAuthRefreshError.invalidGrant(status: response.statusCode, body: body)
        default:
            logger.info("refresh grant failed with HTTP \(response.statusCode, privacy: .public)")
            throw OAuthRefreshError.http(status: response.statusCode)
        }
    }

    private func makeRequest(refreshToken: String, scopes: [String]) throws -> URLRequest {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: Self.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let body = TokenRequest(
            grantType: "refresh_token",
            refreshToken: refreshToken,
            clientID: Self.clientID,
            scope: scopes.joined(separator: " ")
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            request.httpBody = try encoder.encode(body)
        } catch {
            throw OAuthRefreshError.invalidResponse
        }
        return request
    }

    private static let urlSessionTransport: HTTPTransport = { request, proxyConfig in
        let (data, response) = try await URLSessionFactory.make(proxyConfig: proxyConfig).data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OAuthRefreshError.invalidResponse }
        return (data, http)
    }
}

/// Coalesces concurrent refreshes of one refresh token into a single request;
/// every waiter receives the same result or error.
private actor InFlightRefreshes {
    private var tasks: [String: Task<OAuthCredentials, Error>] = [:]

    func run(key: String, _ operation: @escaping @Sendable () async throws -> OAuthCredentials) async throws -> OAuthCredentials {
        if let existing = tasks[key] {
            return try await existing.value
        }
        let task = Task { try await operation() }
        tasks[key] = task
        defer { tasks[key] = nil }
        return try await task.value
    }
}
