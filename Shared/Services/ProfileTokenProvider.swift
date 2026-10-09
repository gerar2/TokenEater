import Foundation
import os.log

private let logger = Logger(subsystem: "com.tokeneater.app", category: "ProfileTokenProvider")

/// Token provider for one `AccountProfile` (`docs/multi-profile-plan.md` §3.5).
///
/// It keeps the profile's credentials in memory, mirrors them into the vault,
/// adopts newer credentials from Claude Code's live store, and - when the
/// renewal policy allows - renews them through the OAuth refresh grant.
///
/// - Linked profiles read their own config dir. With policy `.claudeCode`
///   (the default, today's behaviour) an expired token is reported as
///   "waiting for Claude Code"; with `.tokenEater` it is renewed and the
///   rotated credentials are written back to the backing the read came from so
///   Claude Code keeps working.
/// - Managed profiles hold the only copy of their chain, so they always renew
///   and never write to a Claude Code store. Before renewing they re-read the
///   default store: right after a capture both hold the same chain, and
///   whichever refreshed first must win (owner precedence).
///
/// Threading: mutable state sits behind an `NSLock`; I/O (vault, live store,
/// network) runs outside it. `ensureFreshToken` is serialised per provider so
/// two ticks never race one refresh-token chain. `currentToken()` stays
/// synchronous and never touches the network.
final class ProfileTokenProvider: TokenProviderProtocol, @unchecked Sendable {
    typealias LegacyBootstrap = @Sendable () throws -> Void

    private let lock = NSLock()
    private var profile: AccountProfile
    private var cached: OAuthCredentials?
    private var _lastRead: ClaudeCodeCredentialRead?
    private var _credentialState: ProfileCredentialState = .unknown
    /// Renewal backoff. A failed refresh grant (429 or a transport error) blocks
    /// further grants until `renewalBlockedUntil`; the delay follows
    /// `Retry-After` when the server sends one, else an exponential ladder.
    /// Without this a profile whose token expired kept hitting the token
    /// endpoint on every tick, which is exactly what keeps a 429 going.
    private var renewalBlockedUntil: Date?
    private var consecutiveRenewalFailures = 0
    private var lastRenewalFailureWasRateLimit = false

    /// Backoff ladder after a 429 without a usable `Retry-After`.
    static let rateLimitBackoff: [TimeInterval] = [120, 300, 900, 1800, 3600]
    /// Backoff ladder after a transport / server error.
    static let transientBackoff: [TimeInterval] = [60, 120, 300, 600]

    private let vault: ProfileCredentialVaultProtocol
    private let store: ClaudeCodeCredentialStoreProtocol
    private let refresher: OAuthTokenRefresherProtocol
    private let proxyProvider: @Sendable () -> ProxyConfig?
    private let realHome: String
    private let now: @Sendable () -> Date
    private let legacyBootstrap: LegacyBootstrap
    private let serialQueue = AsyncSerialQueue()

    /// - Parameters:
    ///   - proxyProvider: the current SOCKS proxy setting, read at refresh time
    ///     so a settings change applies without rebuilding the provider.
    ///   - legacyBootstrap: the interactive first-connect read used during
    ///     onboarding for the default profile only; injectable so tests never
    ///     touch the Keychain.
    init(
        profile: AccountProfile,
        vault: ProfileCredentialVaultProtocol,
        store: ClaudeCodeCredentialStoreProtocol,
        refresher: OAuthTokenRefresherProtocol,
        proxyProvider: @escaping @Sendable () -> ProxyConfig?,
        realHome: String = ClaudeKeychainServiceName.realHome,
        now: @escaping @Sendable () -> Date = { Date() },
        legacyBootstrap: @escaping LegacyBootstrap = { try TokenProvider().bootstrap() }
    ) {
        self.profile = profile
        self.vault = vault
        self.store = store
        self.refresher = refresher
        self.proxyProvider = proxyProvider
        self.realHome = realHome
        self.now = now
        self.legacyBootstrap = legacyBootstrap
    }

    // MARK: - Profile

    /// The profile this provider serves (name / policy may change at runtime).
    var currentProfile: AccountProfile { lock.withLock { profile } }

    /// Applies a policy / name change without dropping the cached credentials.
    func update(profile: AccountProfile) {
        lock.withLock { self.profile = profile }
    }

    /// The last live read from Claude Code's store, kept so a write-back goes
    /// to the same backing with every unknown key preserved.
    var lastRead: ClaudeCodeCredentialRead? { lock.withLock { _lastRead } }

    var credentialState: ProfileCredentialState { lock.withLock { _credentialState } }

    /// When the next refresh grant may be attempted; nil when not backing off.
    var nextRenewalAttempt: Date? { lock.withLock { renewalBlockedUntil } }

    /// Drops the renewal backoff so the next `ensureFreshToken` may call the
    /// token endpoint again. For an explicit user action ("Refresh now"), not
    /// for the automatic loop.
    func clearRenewalBackoff() {
        lock.withLock {
            renewalBlockedUntil = nil
            consecutiveRenewalFailures = 0
        }
    }

    // MARK: - TokenProviderProtocol

    var isBootstrapped: Bool { true }

    /// Cached access token; on first use loads the vault, then the live store
    /// (seeding the vault). Synchronous and network-free: the live read may
    /// shell out to `/usr/bin/security`, exactly like the legacy provider.
    func currentToken() -> String? {
        if let token = lock.withLock({ cached?.accessToken }) { return token }
        return populate()?.accessToken
    }

    func hasTokenSource() -> Bool {
        let profile = currentProfile
        if profile.isLinked {
            return store.exists(configDir: profile.configDir)
        }
        if lock.withLock({ cached }) != nil { return true }
        return vault.load(profileID: profile.id) != nil
    }

    /// A 401 arrived, or a watched credential file changed. The cache is kept
    /// on purpose: for a managed profile it is the only copy of the chain, and
    /// the next `ensureFreshToken` re-reads the live store and adopts whatever
    /// is newer. It deliberately does NOT force a renewal: `UsageStore` passes
    /// `force: true` explicitly on a 401, and a file-change notification must
    /// never renew, otherwise a renewal whose write-back touches the watched
    /// credentials file would trigger the watcher and renew again, forever.
    func invalidateToken() {
        logger.info("Token invalidated for profile \(self.idPrefix, privacy: .public) - next ensureFreshToken re-reads the live store")
    }

    /// Steps 2-3 of §3.5 only. Returns true when the access token changed
    /// between two non-nil reads (an account swap or a rotation), which is
    /// what `UsageStore.reconcileTokenIfChanged` treats as "force a refresh".
    /// First population and a transient miss return false so a working token
    /// is never dropped.
    func refreshTokenIfChanged() -> Bool {
        let profile = currentProfile
        loadVaultIfNeeded(profile: profile)
        let previous = lock.withLock { cached?.accessToken }
        reconcileWithLiveStore(profile: profile)
        let current = lock.withLock { cached?.accessToken }
        guard let previous, let current else { return false }
        if previous != current {
            logger.info("Token changed in the live store for profile \(self.idPrefix, privacy: .public)")
            return true
        }
        return false
    }

    /// The interactive first-connect read belongs to the default `~/.claude`
    /// profile only; every other profile is created from an already working
    /// store or capture.
    func bootstrap() throws {
        guard currentProfile.isDefaultClaudeCodeProfile else { return }
        try legacyBootstrap()
    }

    func ensureFreshToken(force: Bool) async -> TokenReadiness {
        await serialQueue.run { [self] in
            await self.performEnsureFreshToken(force: force)
        }
    }

    // MARK: - ensureFreshToken

    private func performEnsureFreshToken(force: Bool) async -> TokenReadiness {
        let profile = currentProfile

        // 1. In-memory cache, else the vault.
        loadVaultIfNeeded(profile: profile)

        // 2-3. Live store read + adoption. Off the cooperative pool: it may
        // block up to 3 s on `/usr/bin/security`.
        _ = await blocking { self.reconcileWithLiveStore(profile: profile) }

        // 4. Nothing anywhere.
        guard let current = lock.withLock({ cached }) else {
            setState(.missing)
            return .missing
        }

        // 5. Still valid (and no forced renewal).
        let now = self.now()
        let expired = force || current.isExpired(now: now)
        if !expired {
            setState(ProfileCredentialState.from(current, now: now))
            return .ready
        }

        // 6. Renewal belongs to Claude Code: re-read on the next tick.
        guard profile.effectiveRenewalPolicy == .tokenEater else {
            setState(.awaitingClaudeCode)
            return .awaitingClaudeCode
        }

        // 7. Nothing to renew with (Claude Desktop-only credentials).
        guard current.refreshToken != nil else {
            setState(.reauthRequired(reason: "noRefreshToken"))
            return .reauthRequired
        }

        // 8. Refresh grant, unless a previous failure put us in backoff: the
        // token endpoint must not be hit on every tick.
        if let blockedUntil = lock.withLock({ renewalBlockedUntil }), blockedUntil > now {
            let rateLimited = lock.withLock { lastRenewalFailureWasRateLimit }
            setState(Self.stateDuringBackoff(current, until: blockedUntil, rateLimited: rateLimited, now: now))
            return current.isExpired(now: now) ? .awaitingClaudeCode : .ready
        }
        setState(ProfileCredentialState.from(current, now: now))
        let renewed: OAuthCredentials
        do {
            renewed = try await refresher.refresh(current, proxyConfig: proxyProvider())
        } catch let error as OAuthRefreshError {
            switch error {
            case .invalidGrant(let status, _):
                logger.error("Refresh grant rejected (\(status, privacy: .public)) for profile \(self.idPrefix, privacy: .public)")
                setState(.reauthRequired(reason: "invalidGrant(\(status))"))
                return .reauthRequired
            case .noRefreshToken:
                setState(.reauthRequired(reason: "noRefreshToken"))
                return .reauthRequired
            case .rateLimited(let retryAfter, _):
                let until = scheduleRenewalBackoff(for: current, now: now, serverRetryAfter: retryAfter, rateLimited: true)
                logger.error("Refresh grant rate-limited for profile \(self.idPrefix, privacy: .public); next attempt at \(until, privacy: .public)")
                return current.isExpired(now: now) ? .awaitingClaudeCode : .ready
            case .network, .http, .invalidResponse:
                // Transient: keep the cached chain, back off briefly.
                let until = scheduleRenewalBackoff(for: current, now: now, serverRetryAfter: nil, rateLimited: false)
                logger.info("Refresh grant failed transiently for profile \(self.idPrefix, privacy: .public): \(String(describing: error), privacy: .public); next attempt at \(until, privacy: .public)")
                return current.isExpired(now: now) ? .awaitingClaudeCode : .ready
            }
        } catch {
            let until = scheduleRenewalBackoff(for: current, now: now, serverRetryAfter: nil, rateLimited: false)
            logger.info("Refresh grant failed for profile \(self.idPrefix, privacy: .public): \(error.localizedDescription, privacy: .public); next attempt at \(until, privacy: .public)")
            return current.isExpired(now: now) ? .awaitingClaudeCode : .ready
        }
        lock.withLock {
            renewalBlockedUntil = nil
            consecutiveRenewalFailures = 0
        }

        // 9. Persist, then hand the rotated chain back to Claude Code when it
        // was ours to renew and the backing can take it.
        let writeBack: ClaudeCodeCredentialRead? = lock.withLock {
            cached = renewed
            _credentialState = ProfileCredentialState.from(renewed, now: self.now())
            guard profile.isLinked, profile.effectiveRenewalPolicy == .tokenEater,
                  let read = _lastRead, read.backing.isWritable else { return nil }
            return read
        }
        do {
            try vault.save(renewed, profileID: profile.id)
        } catch {
            logger.error("Vault save failed for profile \(self.idPrefix, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        if let read = writeBack {
            let store = self.store
            await blocking {
                do {
                    try store.write(renewed, raw: read.raw, backing: read.backing)
                } catch {
                    logger.error("Write-back to Claude Code's store failed for profile \(self.idPrefix, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        }
        logger.info("Token renewed for profile \(self.idPrefix, privacy: .public)")
        return .ready
    }

    // MARK: - Cache population

    /// First population for `currentToken()`: the vault, else the live store.
    private func populate() -> OAuthCredentials? {
        let profile = currentProfile
        loadVaultIfNeeded(profile: profile)
        if let stored = lock.withLock({ cached }) { return stored }
        reconcileWithLiveStore(profile: profile)
        return lock.withLock {
            if cached == nil { _credentialState = .missing }
            return cached
        }
    }

    private func loadVaultIfNeeded(profile: AccountProfile) {
        guard lock.withLock({ cached }) == nil,
              let stored = vault.load(profileID: profile.id) else { return }
        lock.withLock {
            guard cached == nil else { return }
            cached = stored
            _credentialState = ProfileCredentialState.from(stored, now: now())
        }
    }

    /// Steps 2-3 of §3.5: read the relevant live store and adopt what it holds
    /// when that is new for this profile. Linked profiles follow their own
    /// config dir (any change is an account swap or a rotation to adopt).
    /// Managed profiles look at the default store, where the capture came
    /// from: only a newer set of the *same chain* is adopted, anything else is
    /// another account and is ignored.
    @discardableResult
    private func reconcileWithLiveStore(profile: AccountProfile) -> ClaudeCodeCredentialRead? {
        guard let live = store.read(configDir: profile.isLinked ? profile.configDir : nil) else {
            return nil
        }
        let adopted: Bool = lock.withLock {
            let previousRead = _lastRead?.credentials
            _lastRead = live
            guard Self.shouldAdopt(live.credentials, over: cached, lastRead: previousRead, profile: profile) else { return false }
            cached = live.credentials
            _credentialState = ProfileCredentialState.from(live.credentials, now: now())
            return true
        }
        if adopted {
            do {
                try vault.save(live.credentials, profileID: profile.id)
            } catch {
                logger.error("Vault save failed for profile \(self.idPrefix, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            logger.info("Adopted live credentials for profile \(self.idPrefix, privacy: .public) from \(self.describe(live.backing, profile: profile), privacy: .public)")
        }
        return live
    }

    /// Adoption rule for a live read.
    ///
    /// - Linked profile: adopt when the live store CHANGED since our previous
    ///   read (a rotation by Claude Code or an account swap). Comparing against
    ///   the previous read rather than the cache matters after a renewal whose
    ///   write-back failed: the store still holds the pre-renewal token, which
    ///   must not be re-adopted (it would drag the chain back and the next
    ///   refresh grant would be rejected). With no previous read the cache is
    ///   the only baseline.
    /// - Managed profile: adopt only a newer set of the SAME chain (owner
    ///   precedence after a capture). Never adopt without a baseline: a lost
    ///   vault item must surface as "no credentials", not silently attach
    ///   whichever account is signed in to `~/.claude`.
    static func shouldAdopt(
        _ live: OAuthCredentials,
        over cached: OAuthCredentials?,
        lastRead: OAuthCredentials?,
        profile: AccountProfile
    ) -> Bool {
        guard let cached else { return profile.isLinked }
        if profile.isLinked {
            guard live.accessToken != cached.accessToken else { return false }
            if let lastRead { return live.accessToken != lastRead.accessToken }
            return true
        }
        return live.isSameChain(as: cached) && live.isNewer(than: cached)
    }

    // MARK: - Helpers

    /// Records a failed renewal and returns when the next attempt is allowed:
    /// the server's `Retry-After` when positive, else the ladder step for the
    /// number of consecutive failures (capped at the last step).
    /// A backoff only changes the visible state once the token is actually
    /// expired: a still-valid token keeps the profile "connected", the
    /// deferred renewal is an internal matter until then.
    private static func stateDuringBackoff(_ current: OAuthCredentials, until: Date, rateLimited: Bool, now: Date) -> ProfileCredentialState {
        current.isExpired(now: now)
            ? .renewalDeferred(until: until, rateLimited: rateLimited)
            : ProfileCredentialState.from(current, now: now)
    }

    @discardableResult
    private func scheduleRenewalBackoff(for current: OAuthCredentials, now: Date, serverRetryAfter: TimeInterval?, rateLimited: Bool) -> Date {
        lock.withLock {
            let ladder = rateLimited ? Self.rateLimitBackoff : Self.transientBackoff
            let step = ladder[min(consecutiveRenewalFailures, ladder.count - 1)]
            let delay: TimeInterval
            if let serverRetryAfter, serverRetryAfter > 0 {
                delay = serverRetryAfter
            } else {
                delay = step
            }
            consecutiveRenewalFailures += 1
            lastRenewalFailureWasRateLimit = rateLimited
            let until = now.addingTimeInterval(delay)
            renewalBlockedUntil = until
            _credentialState = Self.stateDuringBackoff(current, until: until, rateLimited: rateLimited, now: now)
            return until
        }
    }

    private func setState(_ state: ProfileCredentialState) {
        lock.withLock { _credentialState = state }
    }

    private var idPrefix: String {
        String(currentProfile.id.uuidString.prefix(8))
    }

    /// Log-safe description of a backing: the config dir's last path
    /// component at most, never a full path.
    private func describe(_ backing: ClaudeCodeCredentialBacking, profile: AccountProfile) -> String {
        let dir: String
        if profile.isLinked {
            dir = URL(fileURLWithPath: profile.resolvedConfigDir(realHome: realHome)).lastPathComponent
        } else {
            dir = ".claude"
        }
        switch backing {
        case .keychain: return "keychain(…/\(dir))"
        case .file: return "file(…/\(dir))"
        case .claudeDesktop: return "claudeDesktop"
        }
    }

    /// Live-store I/O can block for seconds on `/usr/bin/security`; keep it
    /// off the cooperative thread pool (and, transitively, off the main actor).
    private func blocking<T>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }
}

// MARK: - AsyncSerialQueue

/// FIFO serialisation of async work: each `run` waits for the previous one to
/// finish before starting, so a provider never has two renewals in flight.
actor AsyncSerialQueue {
    private var tail: Task<Void, Never>?

    func run<T: Sendable>(_ operation: @escaping @Sendable () async -> T) async -> T {
        let previous = tail
        let task = Task<T, Never> {
            await previous?.value
            return await operation()
        }
        tail = Task { _ = await task.value }
        return await task.value
    }
}
