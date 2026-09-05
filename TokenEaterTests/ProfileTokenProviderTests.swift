import Testing
import Foundation

@Suite("ProfileTokenProvider")
struct ProfileTokenProviderTests {

    private let now = Date()

    private struct Env {
        let provider: ProfileTokenProvider
        let vault: InMemoryProfileCredentialVault
        let store: MockClaudeCodeCredentialStore
        let refresher: MockOAuthTokenRefresher
    }

    private func credentials(
        _ token: String,
        refresh: String? = "rt-1",
        ttl: TimeInterval = 8 * 3600,
        subscription: String? = "max"
    ) -> OAuthCredentials {
        OAuthCredentials(
            accessToken: token,
            refreshToken: refresh,
            expiresAt: now.addingTimeInterval(ttl),
            scopes: OAuthCredentials.defaultScopes,
            subscriptionType: subscription
        )
    }

    private func linked(_ dir: String? = nil, policy: TokenRenewalPolicy = .claudeCode) -> AccountProfile {
        AccountProfile(name: "Linked", source: .claudeCode(configDir: dir), renewalPolicy: policy)
    }

    private func managed() -> AccountProfile {
        AccountProfile(name: "Captured", source: .managed, renewalPolicy: .tokenEater)
    }

    private func makeSUT(
        profile: AccountProfile,
        vaultSeed: OAuthCredentials? = nil,
        refresher: OAuthTokenRefresherProtocol? = nil,
        legacyBootstrap: ProfileTokenProvider.LegacyBootstrap? = nil
    ) -> Env {
        let vault = InMemoryProfileCredentialVault()
        if let vaultSeed { vault.storage[profile.id] = vaultSeed }
        let store = MockClaudeCodeCredentialStore()
        let mockRefresher = MockOAuthTokenRefresher()
        let now = self.now
        let provider = ProfileTokenProvider(
            profile: profile,
            vault: vault,
            store: store,
            refresher: refresher ?? mockRefresher,
            proxyProvider: { nil },
            realHome: "/Users/tester",
            now: { now },
            legacyBootstrap: legacyBootstrap ?? {}
        )
        return Env(provider: provider, vault: vault, store: store, refresher: mockRefresher)
    }

    // MARK: - Population and adoption

    @Test("A linked profile seeds the vault from the first live read")
    func seedsVaultFromLiveRead() {
        let profile = linked()
        let env = makeSUT(profile: profile)
        let live = credentials("live-at")
        env.store.stub(configDir: nil, credentials: live)

        #expect(env.provider.currentToken() == "live-at")
        #expect(env.vault.storage[profile.id] == live)
        #expect(env.provider.credentialState == .ok(expiresAt: live.expiresAt))
        #expect(env.provider.lastRead?.backing == .keychain(service: "Claude Code-credentials"))
        #expect(env.refresher.refreshCallCount == 0)
    }

    @Test("currentToken serves the vault without touching the live store or the network")
    func currentTokenUsesVaultFirst() {
        let profile = linked()
        let env = makeSUT(profile: profile, vaultSeed: credentials("vault-at"))
        env.store.stub(configDir: nil, credentials: credentials("live-at"))

        #expect(env.provider.currentToken() == "vault-at")
        #expect(env.store.readCallCount == 0)
        #expect(env.provider.currentToken() == "vault-at")
        #expect(env.refresher.refreshCallCount == 0)
    }

    @Test("Nothing anywhere: currentToken is nil and the state is missing")
    func missingEverywhere() async {
        let env = makeSUT(profile: linked())
        #expect(env.provider.currentToken() == nil)
        #expect(env.provider.credentialState == .missing)
        #expect(await env.provider.ensureFreshToken(force: false) == .missing)
        #expect(env.provider.credentialState == .missing)
    }

    @Test("A linked profile adopts a changed live token instead of refreshing")
    func adoptsNewerLiveForLinked() async {
        let profile = linked("~/.claude-work", policy: .tokenEater)
        let env = makeSUT(profile: profile, vaultSeed: credentials("old-at", refresh: "rt-old", ttl: -60))
        let live = credentials("new-at", refresh: "rt-new")
        env.store.stub(configDir: "~/.claude-work", credentials: live)

        #expect(await env.provider.ensureFreshToken(force: false) == .ready)

        #expect(env.provider.currentToken() == "new-at")
        #expect(env.vault.storage[profile.id] == live)
        #expect(env.refresher.refreshCallCount == 0)
        #expect(env.store.writeCallCount == 0)
        #expect(env.provider.credentialState == .ok(expiresAt: live.expiresAt))
    }

    @Test("A managed profile adopts a newer token of the same chain from the default store")
    func managedAdoptsNewerSameChain() async {
        let profile = managed()
        let env = makeSUT(profile: profile, vaultSeed: credentials("at-old", refresh: "rt-1", ttl: -60))
        let rotatedByClaudeCode = credentials("at-new", refresh: "rt-1", ttl: 3600)
        env.store.stub(configDir: nil, credentials: rotatedByClaudeCode)

        #expect(await env.provider.ensureFreshToken(force: false) == .ready)

        #expect(env.provider.currentToken() == "at-new")
        #expect(env.vault.storage[profile.id] == rotatedByClaudeCode)
        #expect(env.refresher.refreshCallCount == 0)
        #expect(env.store.writeCallCount == 0)
    }

    @Test("A managed profile ignores a live token of another chain")
    func managedIgnoresDifferentChain() async {
        let profile = managed()
        let mine = credentials("at-b", refresh: "rt-b", ttl: 3600)
        let env = makeSUT(profile: profile, vaultSeed: mine)
        env.store.stub(configDir: nil, credentials: credentials("at-a", refresh: "rt-a", ttl: 9 * 3600))

        #expect(await env.provider.ensureFreshToken(force: false) == .ready)
        #expect(env.provider.currentToken() == "at-b")
        #expect(env.vault.storage[profile.id] == mine)
        #expect(env.vault.saveCallCount == 0)
        #expect(env.provider.refreshTokenIfChanged() == false)
        #expect(env.provider.currentToken() == "at-b")
    }

    @Test("A managed profile does not adopt an older token of the same chain")
    func managedIgnoresOlderSameChain() async {
        let profile = managed()
        let mine = credentials("at-new", refresh: "rt-1", ttl: 3600)
        let env = makeSUT(profile: profile, vaultSeed: mine)
        env.store.stub(configDir: nil, credentials: credentials("at-old", refresh: "rt-1", ttl: 600))

        #expect(await env.provider.ensureFreshToken(force: false) == .ready)
        #expect(env.provider.currentToken() == "at-new")
        #expect(env.vault.saveCallCount == 0)
    }

    // MARK: - Renewal policy

    @Test("Linked + claudeCode policy + expired: waits for Claude Code, never refreshes, keeps the cache")
    func linkedClaudeCodePolicyAwaits() async {
        let profile = linked()
        let expired = credentials("expired-at", ttl: -60)
        let env = makeSUT(profile: profile, vaultSeed: expired)
        env.store.stub(configDir: nil, credentials: expired)

        #expect(await env.provider.ensureFreshToken(force: false) == .awaitingClaudeCode)
        #expect(env.provider.credentialState == .awaitingClaudeCode)
        #expect(env.refresher.refreshCallCount == 0)
        #expect(env.provider.currentToken() == "expired-at")

        // Even a forced renewal (after a 401) stays with Claude Code.
        #expect(await env.provider.ensureFreshToken(force: true) == .awaitingClaudeCode)
        #expect(env.refresher.refreshCallCount == 0)
        #expect(env.store.writeCallCount == 0)
    }

    @Test("Linked + tokenEater policy + expired: refreshes, saves to the vault and writes back to the same backing")
    func linkedTokenEaterRefreshesAndWritesBack() async throws {
        let profile = linked("~/.claude-work", policy: .tokenEater)
        let expired = credentials("expired-at", refresh: "rt-1", ttl: -60)
        let env = makeSUT(profile: profile, vaultSeed: expired)
        let path = "/Users/tester/.claude-work/.credentials.json"
        let raw = ClaudeCredentialsPayload.merge(expired, into: ["claudeAiOauth": ["rateLimitTier": "max5x"], "other": ["keep": true]])
        env.store.stub(configDir: "~/.claude-work", credentials: expired, backing: .file(path: path), raw: raw)

        #expect(await env.provider.ensureFreshToken(force: false) == .ready)

        let renewed = try #require(env.vault.storage[profile.id])
        #expect(renewed.accessToken == "expired-at-refreshed")
        #expect(renewed.refreshToken == "rt-1-rotated")
        #expect(env.provider.currentToken() == "expired-at-refreshed")
        #expect(env.refresher.refreshCallCount == 1)
        #expect(env.refresher.lastInput == expired)
        #expect(env.provider.credentialState.rawKind == "ok")

        #expect(env.store.writeCallCount == 1)
        #expect(env.store.lastWrittenBacking == .file(path: path))
        #expect(env.store.lastWrittenCredentials == renewed)
        let writtenOAuth = try #require(env.store.lastWrittenRaw?["claudeAiOauth"] as? [String: Any])
        #expect(writtenOAuth["rateLimitTier"] as? String == "max5x")
        #expect((env.store.lastWrittenRaw?["other"] as? [String: Any])?["keep"] as? Bool == true)
    }

    @Test("Write-back goes to the Keychain backing when that is where the read came from")
    func writeBackToKeychainBacking() async {
        let profile = linked(nil, policy: .tokenEater)
        let expired = credentials("expired-at", ttl: -60)
        let env = makeSUT(profile: profile, vaultSeed: expired)
        env.store.stub(configDir: nil, credentials: expired, backing: .keychain(service: "Claude Code-credentials"))

        #expect(await env.provider.ensureFreshToken(force: false) == .ready)
        #expect(env.store.lastWrittenBacking == .keychain(service: "Claude Code-credentials"))
    }

    @Test("A failed write-back does not fail the renewal")
    func writeBackFailureIsNonFatal() async {
        let profile = linked(nil, policy: .tokenEater)
        let expired = credentials("expired-at", ttl: -60)
        let env = makeSUT(profile: profile, vaultSeed: expired)
        env.store.stub(configDir: nil, credentials: expired)
        env.store.writeError = ClaudeCodeCredentialStoreError.writeFailed("security exited with 45")

        #expect(await env.provider.ensureFreshToken(force: false) == .ready)
        #expect(env.store.writeCallCount == 1)
        #expect(env.provider.currentToken() == "expired-at-refreshed")
        #expect(env.vault.storage[profile.id]?.accessToken == "expired-at-refreshed")
    }

    @Test("Managed + expired: refreshes and saves to the vault, never writes to a Claude Code store")
    func managedExpiredRefreshesWithoutWrite() async {
        let profile = managed()
        let expired = credentials("at-b", refresh: "rt-b", ttl: -60)
        let env = makeSUT(profile: profile, vaultSeed: expired)
        // Another account is logged in on the machine: irrelevant to this chain.
        env.store.stub(configDir: nil, credentials: credentials("at-a", refresh: "rt-a"))

        #expect(await env.provider.ensureFreshToken(force: false) == .ready)

        #expect(env.refresher.refreshCallCount == 1)
        #expect(env.refresher.lastInput == expired)
        #expect(env.provider.currentToken() == "at-b-refreshed")
        #expect(env.vault.storage[profile.id]?.refreshToken == "rt-b-rotated")
        #expect(env.store.writeCallCount == 0)
    }

    @Test("Managed without a refresh token needs re-authentication")
    func managedWithoutRefreshTokenReauth() async {
        let profile = managed()
        let env = makeSUT(profile: profile, vaultSeed: credentials("at", refresh: nil, ttl: -10))

        #expect(await env.provider.ensureFreshToken(force: false) == .reauthRequired)
        #expect(env.provider.credentialState == .reauthRequired(reason: "noRefreshToken"))
        #expect(env.refresher.refreshCallCount == 0)
        #expect(env.provider.currentToken() == "at")
    }

    // MARK: - Refresh failures

    @Test("An invalid grant marks the profile reauthRequired and keeps the cache")
    func invalidGrantReauth() async {
        let profile = managed()
        let expired = credentials("at-old", ttl: -60)
        let env = makeSUT(profile: profile, vaultSeed: expired)
        env.refresher.stubbedError = OAuthRefreshError.invalidGrant(status: 401, body: "invalid_grant")

        #expect(await env.provider.ensureFreshToken(force: false) == .reauthRequired)
        #expect(env.provider.credentialState == .reauthRequired(reason: "invalidGrant(401)"))
        #expect(env.provider.currentToken() == "at-old")
        #expect(env.vault.storage[profile.id] == expired)
        #expect(env.vault.saveCallCount == 0)
        #expect(env.refresher.refreshCallCount == 1)
    }

    @Test("A transient network error keeps the cached credentials")
    func transientErrorKeepsCache() async {
        let profile = managed()
        let expired = credentials("at-old", ttl: -60)
        let env = makeSUT(profile: profile, vaultSeed: expired)
        env.refresher.stubbedError = OAuthRefreshError.network("offline")

        #expect(await env.provider.ensureFreshToken(force: false) == .awaitingClaudeCode)
        #expect(env.provider.currentToken() == "at-old")
        #expect(env.vault.storage[profile.id] == expired)
        #expect(env.vault.saveCallCount == 0)
        #expect(env.provider.credentialState == .awaitingClaudeCode)

        // Back online: the next tick renews.
        env.refresher.stubbedError = nil
        #expect(await env.provider.ensureFreshToken(force: false) == .ready)
        #expect(env.provider.currentToken() == "at-old-refreshed")
    }

    @Test("A transient error on a forced renewal of a still-valid token reports ready")
    func transientErrorWithValidTokenIsReady() async {
        let profile = managed()
        let valid = credentials("at-valid", ttl: 3600)
        let env = makeSUT(profile: profile, vaultSeed: valid)
        env.refresher.stubbedError = OAuthRefreshError.http(status: 503)

        #expect(await env.provider.ensureFreshToken(force: true) == .ready)
        #expect(env.provider.currentToken() == "at-valid")
        #expect(env.provider.credentialState == .ok(expiresAt: valid.expiresAt))
    }

    // MARK: - Force / invalidate

    @Test("force renews a token that is not expired yet")
    func forceRefreshesWhenNotExpired() async {
        let profile = managed()
        let env = makeSUT(profile: profile, vaultSeed: credentials("at-valid", ttl: 3600))

        #expect(await env.provider.ensureFreshToken(force: false) == .ready)
        #expect(env.refresher.refreshCallCount == 0)

        #expect(await env.provider.ensureFreshToken(force: true) == .ready)
        #expect(env.refresher.refreshCallCount == 1)
        #expect(env.provider.currentToken() == "at-valid-refreshed")
    }

    @Test("invalidateToken keeps the cache and forces the next ensureFreshToken once")
    func invalidateTokenForcesNextEnsure() async {
        let profile = managed()
        let env = makeSUT(profile: profile, vaultSeed: credentials("at-valid", ttl: 3600))

        env.provider.invalidateToken()
        #expect(env.provider.currentToken() == "at-valid")

        #expect(await env.provider.ensureFreshToken(force: false) == .ready)
        #expect(env.refresher.refreshCallCount == 1)
        #expect(env.provider.currentToken() == "at-valid-refreshed")

        // The flag is consumed.
        #expect(await env.provider.ensureFreshToken(force: false) == .ready)
        #expect(env.refresher.refreshCallCount == 1)
    }

    // MARK: - refreshTokenIfChanged

    @Test("refreshTokenIfChanged keeps the account-swap semantics of the legacy provider")
    func refreshTokenIfChangedSemantics() {
        let profile = linked()
        let env = makeSUT(profile: profile)
        env.store.stub(configDir: nil, credentials: credentials("tok-A", refresh: "rt-A"))

        // First population is a baseline, not a change.
        #expect(env.provider.refreshTokenIfChanged() == false)
        #expect(env.provider.currentToken() == "tok-A")

        // cswap / claude login rotates the live store.
        env.store.stub(configDir: nil, credentials: credentials("tok-B", refresh: "rt-B"))
        #expect(env.provider.refreshTokenIfChanged() == true)
        #expect(env.provider.currentToken() == "tok-B")
        #expect(env.vault.storage[profile.id]?.accessToken == "tok-B")

        // Unchanged.
        #expect(env.provider.refreshTokenIfChanged() == false)

        // A transient miss never drops the working token.
        env.store.reads.removeAll()
        #expect(env.provider.refreshTokenIfChanged() == false)
        #expect(env.provider.currentToken() == "tok-B")
    }

    @Test("refreshTokenIfChanged for a managed profile only reacts to same-chain rotations")
    func refreshTokenIfChangedManaged() {
        let profile = managed()
        let env = makeSUT(profile: profile, vaultSeed: credentials("at-old", refresh: "rt-1", ttl: 600))

        env.store.stub(configDir: nil, credentials: credentials("at-other", refresh: "rt-other", ttl: 7200))
        #expect(env.provider.refreshTokenIfChanged() == false)
        #expect(env.provider.currentToken() == "at-old")

        env.store.stub(configDir: nil, credentials: credentials("at-new", refresh: "rt-1", ttl: 7200))
        #expect(env.provider.refreshTokenIfChanged() == true)
        #expect(env.provider.currentToken() == "at-new")
    }

    // MARK: - hasTokenSource / state / bootstrap / update

    @Test("hasTokenSource asks the live store for linked profiles and the vault for managed ones")
    func hasTokenSource() {
        let linkedEnv = makeSUT(profile: linked("~/.claude-work"))
        #expect(linkedEnv.provider.hasTokenSource() == false)
        linkedEnv.store.stub(configDir: "~/.claude-work", credentials: credentials("x"))
        #expect(linkedEnv.provider.hasTokenSource() == true)

        let managedProfile = managed()
        let managedEnv = makeSUT(profile: managedProfile)
        managedEnv.store.stub(configDir: nil, credentials: credentials("default-account"))
        #expect(managedEnv.provider.hasTokenSource() == false)
        managedEnv.vault.storage[managedProfile.id] = credentials("mine")
        #expect(managedEnv.provider.hasTokenSource() == true)
    }

    @Test("credentialState mirrors the expiry of the cached credentials")
    func credentialStateValues() async {
        let profile = linked()
        let soon = credentials("soon", ttl: 10 * 60)
        let env = makeSUT(profile: profile, vaultSeed: soon)
        #expect(env.provider.credentialState == .unknown)

        #expect(await env.provider.ensureFreshToken(force: false) == .ready)
        #expect(env.provider.credentialState == .expiringSoon(expiresAt: soon.expiresAt!))
        #expect(env.provider.credentialState.rawKind == "expiring")

        let later = credentials("later", ttl: 3 * 3600)
        env.store.stub(configDir: nil, credentials: later)
        #expect(await env.provider.ensureFreshToken(force: false) == .ready)
        #expect(env.provider.credentialState == .ok(expiresAt: later.expiresAt))

        let noExpiry = OAuthCredentials(accessToken: "desktop-only")
        env.store.stub(configDir: nil, credentials: noExpiry, backing: .claudeDesktop, raw: [:])
        #expect(await env.provider.ensureFreshToken(force: false) == .ready)
        #expect(env.provider.credentialState == .ok(expiresAt: nil))
    }

    @Test("bootstrap delegates to the legacy interactive read for the default profile only")
    func bootstrapDelegatesOnlyForDefaultProfile() throws {
        final class Counter: @unchecked Sendable { var calls = 0 }
        let counter = Counter()
        let bootstrap: ProfileTokenProvider.LegacyBootstrap = { counter.calls += 1 }

        try makeSUT(profile: linked(nil), legacyBootstrap: bootstrap).provider.bootstrap()
        #expect(counter.calls == 1)
        try makeSUT(profile: linked("~/.claude-work"), legacyBootstrap: bootstrap).provider.bootstrap()
        #expect(counter.calls == 1)
        try makeSUT(profile: managed(), legacyBootstrap: bootstrap).provider.bootstrap()
        #expect(counter.calls == 1)
        #expect(makeSUT(profile: managed()).provider.isBootstrapped)
    }

    @Test("update(profile:) applies a policy change without dropping the cache")
    func updateProfileChangesPolicy() async {
        var profile = linked()
        let expired = credentials("expired-at", ttl: -60)
        let env = makeSUT(profile: profile, vaultSeed: expired)
        env.store.stub(configDir: nil, credentials: expired)

        #expect(await env.provider.ensureFreshToken(force: false) == .awaitingClaudeCode)

        profile.renewalPolicy = .tokenEater
        env.provider.update(profile: profile)
        #expect(env.provider.currentProfile.renewalPolicy == .tokenEater)

        #expect(await env.provider.ensureFreshToken(force: false) == .ready)
        #expect(env.refresher.refreshCallCount == 1)
        #expect(env.provider.currentToken() == "expired-at-refreshed")
        #expect(env.store.writeCallCount == 1)
    }

    // MARK: - Serialisation

    private final class GatedRefresher: OAuthTokenRefresherProtocol, @unchecked Sendable {
        let gate = TestGate()
        private let lock = NSLock()
        private var _calls = 0
        var calls: Int { lock.withLock { _calls } }
        let result: OAuthCredentials

        init(result: OAuthCredentials) { self.result = result }

        func refresh(_ credentials: OAuthCredentials, proxyConfig: ProxyConfig?) async throws -> OAuthCredentials {
            lock.withLock { _calls += 1 }
            await gate.wait()
            return result
        }
    }

    @Test("Concurrent ensureFreshToken calls are serialised: one renewal, the second sees the fresh cache")
    func serialisesConcurrentEnsureFreshToken() async {
        let profile = managed()
        let refresher = GatedRefresher(result: credentials("renewed", refresh: "rt-2"))
        let env = makeSUT(profile: profile, vaultSeed: credentials("old", ttl: -60), refresher: refresher)

        async let first = env.provider.ensureFreshToken(force: false)
        async let second = env.provider.ensureFreshToken(force: false)
        try? await Task.sleep(for: .milliseconds(150))
        await refresher.gate.open()
        let (a, b) = await (first, second)

        #expect(a == .ready)
        #expect(b == .ready)
        #expect(refresher.calls == 1)
        #expect(env.provider.currentToken() == "renewed")
        #expect(env.vault.storage[profile.id]?.accessToken == "renewed")
    }
}
