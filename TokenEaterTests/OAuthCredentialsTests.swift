import Testing
import Foundation

@Suite("OAuthCredentials")
struct OAuthCredentialsTests {

    private let sample = """
    {"claudeAiOauth":{"accessToken":"sk-ant-oat01-abc","refreshToken":"sk-ant-ort01-xyz","expiresAt":1767225600000,"scopes":["user:inference","user:profile"],"subscriptionType":"max","rateLimitTier":"default_claude_max_5x"},"other":{"keep":true}}
    """

    @Test("parses Claude Code's claudeAiOauth payload, expiresAt in epoch ms")
    func parsePayload() throws {
        let parsed = try #require(ClaudeCredentialsPayload.parse(string: sample))
        #expect(parsed.credentials.accessToken == "sk-ant-oat01-abc")
        #expect(parsed.credentials.refreshToken == "sk-ant-ort01-xyz")
        #expect(parsed.credentials.expiresAt == Date(timeIntervalSince1970: 1_767_225_600))
        #expect(parsed.credentials.scopes == ["user:inference", "user:profile"])
        #expect(parsed.credentials.subscriptionType == "max")
        #expect((parsed.raw["other"] as? [String: Any])?["keep"] as? Bool == true)
    }

    @Test("returns nil for payloads without an access token")
    func parseRejectsEmpty() {
        #expect(ClaudeCredentialsPayload.parse(string: "{\"claudeAiOauth\":{\"accessToken\":\"\"}}") == nil)
        #expect(ClaudeCredentialsPayload.parse(string: "not json") == nil)
        #expect(ClaudeCredentialsPayload.parse(string: "{}") == nil)
    }

    @Test("merge replaces the credential fields and keeps every unknown key")
    func mergePreservesUnknownKeys() throws {
        let parsed = try #require(ClaudeCredentialsPayload.parse(string: sample))
        let rotated = OAuthCredentials(
            accessToken: "new-access",
            refreshToken: "new-refresh",
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
            scopes: ["user:inference"],
            subscriptionType: "pro"
        )
        let merged = ClaudeCredentialsPayload.merge(rotated, into: parsed.raw)
        let oauth = try #require(merged["claudeAiOauth"] as? [String: Any])
        #expect(oauth["accessToken"] as? String == "new-access")
        #expect(oauth["refreshToken"] as? String == "new-refresh")
        #expect(oauth["expiresAt"] as? Int == 1_800_000_000_000)
        #expect(oauth["scopes"] as? [String] == ["user:inference"])
        #expect(oauth["subscriptionType"] as? String == "pro")
        #expect(oauth["rateLimitTier"] as? String == "default_claude_max_5x")
        #expect((merged["other"] as? [String: Any])?["keep"] as? Bool == true)

        // Serialised form re-parses to the rotated credentials.
        let data = try #require(ClaudeCredentialsPayload.mergedData(rotated, into: parsed.raw))
        let reparsed = try #require(ClaudeCredentialsPayload.parse(data))
        #expect(reparsed.credentials == rotated)
    }

    @Test("merge keeps the old refresh token when the new set has none")
    func mergeKeepsRefreshWhenAbsent() throws {
        let parsed = try #require(ClaudeCredentialsPayload.parse(string: sample))
        let tokenOnly = OAuthCredentials(accessToken: "only-access")
        let oauth = try #require(ClaudeCredentialsPayload.merge(tokenOnly, into: parsed.raw)["claudeAiOauth"] as? [String: Any])
        #expect(oauth["refreshToken"] as? String == "sk-ant-ort01-xyz")
        #expect(oauth["accessToken"] as? String == "only-access")
    }

    @Test("isExpired honours the leeway and treats unknown expiry as valid")
    func expiry() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let soon = OAuthCredentials(accessToken: "a", expiresAt: now.addingTimeInterval(60))
        let later = OAuthCredentials(accessToken: "a", expiresAt: now.addingTimeInterval(3600))
        let unknown = OAuthCredentials(accessToken: "a", expiresAt: nil)
        #expect(soon.isExpired(now: now, leeway: 120) == true)
        #expect(soon.isExpired(now: now, leeway: 0) == false)
        #expect(later.isExpired(now: now) == false)
        #expect(unknown.isExpired(now: now) == false)
    }

    @Test("same-chain and newer comparisons")
    func chainAndRecency() {
        let now = Date()
        let a = OAuthCredentials(accessToken: "at1", refreshToken: "rt1", expiresAt: now)
        let b = OAuthCredentials(accessToken: "at2", refreshToken: "rt1", expiresAt: now.addingTimeInterval(10))
        let c = OAuthCredentials(accessToken: "at1", refreshToken: "rt9", expiresAt: nil)
        let d = OAuthCredentials(accessToken: "at3", refreshToken: "rt3", expiresAt: now)
        #expect(a.isSameChain(as: b))
        #expect(a.isSameChain(as: c))
        #expect(a.isSameChain(as: d) == false)
        #expect(b.isNewer(than: a))
        #expect(a.isNewer(than: b) == false)
        #expect(c.isNewer(than: a) == false)
        #expect(a.isNewer(than: c))
    }

    @Test("empty scopes fall back to the defaults")
    func defaultScopes() {
        #expect(OAuthCredentials(accessToken: "a", scopes: []).scopes == OAuthCredentials.defaultScopes)
    }

    @Test("credential state classification")
    func credentialState() {
        let now = Date()
        #expect(ProfileCredentialState.from(OAuthCredentials(accessToken: "a"), now: now) == .ok(expiresAt: nil))
        #expect(ProfileCredentialState.from(OAuthCredentials(accessToken: "a", expiresAt: now.addingTimeInterval(-1)), now: now) == .awaitingClaudeCode)
        let soon = now.addingTimeInterval(10 * 60)
        #expect(ProfileCredentialState.from(OAuthCredentials(accessToken: "a", expiresAt: soon), now: now) == .expiringSoon(expiresAt: soon))
        let later = now.addingTimeInterval(3 * 3600)
        #expect(ProfileCredentialState.from(OAuthCredentials(accessToken: "a", expiresAt: later), now: now) == .ok(expiresAt: later))
        #expect(ProfileCredentialState.reauthRequired(reason: "x").rawKind == "reauth")
        #expect(ProfileCredentialState.expiringSoon(expiresAt: soon).isHealthy)
        #expect(ProfileCredentialState.missing.isHealthy == false)
    }
}
