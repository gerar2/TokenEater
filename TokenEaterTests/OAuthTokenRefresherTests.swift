import Testing
import Foundation

@Suite("OAuthTokenRefresher")
struct OAuthTokenRefresherTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let old = OAuthCredentials(
        accessToken: "old-at",
        refreshToken: "old-rt",
        expiresAt: Date(timeIntervalSince1970: 1_799_000_000),
        scopes: ["user:inference", "user:profile"],
        subscriptionType: "max"
    )

    private final class Capture: @unchecked Sendable {
        var requests: [URLRequest] = []
        var proxies: [ProxyConfig?] = []
    }

    private func makeSUT(status: Int = 200, body: String = "", version: String? = "1.2.3") -> (sut: OAuthTokenRefresher, capture: Capture) {
        let capture = Capture()
        let now = self.now
        let sut = OAuthTokenRefresher(
            transport: { request, proxy in
                capture.requests.append(request)
                capture.proxies.append(proxy)
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (Data(body.utf8), response)
            },
            claudeCodeVersion: version,
            now: { now }
        )
        return (sut, capture)
    }

    // MARK: - Success

    @Test("200 with a rotated refresh token replaces both tokens and computes expiresAt from expires_in")
    func rotatedRefreshToken() async throws {
        let (sut, _) = makeSUT(body: #"{"token_type":"Bearer","access_token":"new-at","refresh_token":"new-rt","expires_in":28800,"scope":"user:inference user:profile"}"#)

        let renewed = try await sut.refresh(old, proxyConfig: nil)

        #expect(renewed.accessToken == "new-at")
        #expect(renewed.refreshToken == "new-rt")
        #expect(renewed.expiresAt == now.addingTimeInterval(28800))
        #expect(renewed.scopes == old.scopes)
        #expect(renewed.subscriptionType == "max")
    }

    @Test("200 without a refresh token keeps the old one")
    func keepsOldRefreshToken() async throws {
        let (sut, _) = makeSUT(body: #"{"access_token":"new-at","expires_in":3600}"#)

        let renewed = try await sut.refresh(old, proxyConfig: nil)

        #expect(renewed.accessToken == "new-at")
        #expect(renewed.refreshToken == "old-rt")
        #expect(renewed.expiresAt == now.addingTimeInterval(3600))
    }

    @Test("Request matches Claude Code's refresh grant (endpoint, headers, body, timeout)")
    func requestShape() async throws {
        let (sut, capture) = makeSUT(body: #"{"access_token":"new-at","expires_in":1}"#)

        _ = try await sut.refresh(old, proxyConfig: nil)

        let request = try #require(capture.requests.first)
        #expect(request.url?.absoluteString == "https://platform.claude.com/v1/oauth/token")
        #expect(request.httpMethod == "POST")
        #expect(request.timeoutInterval == 30)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "claude-code/1.2.3")

        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["grant_type"] as? String == "refresh_token")
        #expect(json["refresh_token"] as? String == "old-rt")
        #expect(json["client_id"] as? String == "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
        #expect(json["scope"] as? String == "user:inference user:profile")
        #expect(json.count == 4)
    }

    @Test("User-Agent falls back to 0.0.0 when Claude Code is not installed")
    func userAgentFallback() async throws {
        let (sut, capture) = makeSUT(body: #"{"access_token":"new-at"}"#, version: nil)
        _ = try await sut.refresh(old, proxyConfig: nil)
        #expect(capture.requests.first?.value(forHTTPHeaderField: "User-Agent") == "claude-code/0.0.0")
    }

    @Test("The proxy configuration is handed to the transport")
    func proxyPassthrough() async throws {
        let (sut, capture) = makeSUT(body: #"{"access_token":"new-at"}"#)
        _ = try await sut.refresh(old, proxyConfig: ProxyConfig(enabled: true, host: "10.0.0.1", port: 1080))
        #expect(capture.proxies.first??.host == "10.0.0.1")
        #expect(capture.proxies.first??.port == 1080)
    }

    // MARK: - Failures

    @Test("400 and 401 are invalid grants carrying the body")
    func invalidGrant() async {
        let (sut400, _) = makeSUT(status: 400, body: #"{"error":"invalid_grant"}"#)
        await #expect(throws: OAuthRefreshError.invalidGrant(status: 400, body: #"{"error":"invalid_grant"}"#)) {
            try await sut400.refresh(old, proxyConfig: nil)
        }
        let (sut401, _) = makeSUT(status: 401, body: "unauthorized")
        await #expect(throws: OAuthRefreshError.invalidGrant(status: 401, body: "unauthorized")) {
            try await sut401.refresh(old, proxyConfig: nil)
        }
    }

    @Test("Other HTTP statuses are reported as http(status:)")
    func httpError() async {
        let (sut, _) = makeSUT(status: 500, body: "boom")
        await #expect(throws: OAuthRefreshError.http(status: 500)) {
            try await sut.refresh(old, proxyConfig: nil)
        }
        let (sut429, _) = makeSUT(status: 429)
        await #expect(throws: OAuthRefreshError.http(status: 429)) {
            try await sut429.refresh(old, proxyConfig: nil)
        }
    }

    @Test("Transport failures become network errors")
    func transportError() async {
        let sut = OAuthTokenRefresher(
            transport: { _, _ in throw URLError(.notConnectedToInternet) },
            claudeCodeVersion: nil,
            now: { Date() }
        )
        do {
            _ = try await sut.refresh(old, proxyConfig: nil)
            Issue.record("expected a network error")
        } catch OAuthRefreshError.network(let description) {
            #expect(!description.isEmpty)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("A 200 with an unparsable or empty payload is an invalid response")
    func badJSON() async {
        let (garbage, _) = makeSUT(body: "<html>")
        await #expect(throws: OAuthRefreshError.invalidResponse) {
            try await garbage.refresh(old, proxyConfig: nil)
        }
        let (missingToken, _) = makeSUT(body: #"{"refresh_token":"x"}"#)
        await #expect(throws: OAuthRefreshError.invalidResponse) {
            try await missingToken.refresh(old, proxyConfig: nil)
        }
        let (emptyToken, _) = makeSUT(body: #"{"access_token":""}"#)
        await #expect(throws: OAuthRefreshError.invalidResponse) {
            try await emptyToken.refresh(old, proxyConfig: nil)
        }
    }

    @Test("Credentials without a refresh token never hit the network")
    func noRefreshToken() async {
        let (sut, capture) = makeSUT(body: #"{"access_token":"new-at"}"#)
        await #expect(throws: OAuthRefreshError.noRefreshToken) {
            try await sut.refresh(OAuthCredentials(accessToken: "token-only"), proxyConfig: nil)
        }
        await #expect(throws: OAuthRefreshError.noRefreshToken) {
            try await sut.refresh(OAuthCredentials(accessToken: "token-only", refreshToken: ""), proxyConfig: nil)
        }
        #expect(capture.requests.isEmpty)
    }

    // MARK: - Single-flight

    private actor Counter {
        var value = 0
        func increment() { value += 1 }
    }

    @Test("Concurrent refreshes of the same refresh token share one request")
    func singleFlightCoalesces() async throws {
        let gate = TestGate()
        let counter = Counter()
        let now = self.now
        let sut = OAuthTokenRefresher(
            transport: { request, _ in
                await counter.increment()
                await gate.wait()
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data(#"{"access_token":"new-at","refresh_token":"new-rt","expires_in":100}"#.utf8), response)
            },
            claudeCodeVersion: nil,
            now: { now }
        )

        async let first = sut.refresh(old, proxyConfig: nil)
        async let second = sut.refresh(old, proxyConfig: nil)
        try? await Task.sleep(for: .milliseconds(150))
        await gate.open()
        let (a, b) = try await (first, second)

        #expect(a == b)
        #expect(a.accessToken == "new-at")
        #expect(await counter.value == 1)

        // Once the shared request is done, a new call is a new request.
        _ = try await sut.refresh(old, proxyConfig: nil)
        #expect(await counter.value == 2)
    }

    @Test("Different refresh tokens are not coalesced")
    func singleFlightIsKeyedByRefreshToken() async throws {
        let gate = TestGate()
        let counter = Counter()
        let sut = OAuthTokenRefresher(
            transport: { request, _ in
                await counter.increment()
                await gate.wait()
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data(#"{"access_token":"new-at"}"#.utf8), response)
            },
            claudeCodeVersion: nil,
            now: { Date() }
        )
        let other = OAuthCredentials(accessToken: "other-at", refreshToken: "other-rt")

        async let first = sut.refresh(old, proxyConfig: nil)
        async let second = sut.refresh(other, proxyConfig: nil)
        try? await Task.sleep(for: .milliseconds(150))
        await gate.open()
        _ = try await (first, second)

        #expect(await counter.value == 2)
    }
}
