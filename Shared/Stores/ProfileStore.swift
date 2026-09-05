import Foundation
import Combine

enum ProfileStoreError: LocalizedError, Equatable {
    case duplicateConfigDir
    case duplicateAccount(existingName: String)
    case notFound
    case noCredentials
    case noRefreshToken
    case identityFailed(String)
    case cannotRemoveLast
    case vault(String)

    var errorDescription: String? {
        switch self {
        case .duplicateConfigDir: return String(localized: "accounts.error.duplicateDir")
        case .duplicateAccount(let name): return String(format: String(localized: "accounts.error.duplicateAccount"), name)
        case .notFound: return String(localized: "accounts.error.notFound")
        case .noCredentials: return String(localized: "accounts.error.noCredentials")
        case .noRefreshToken: return String(localized: "accounts.error.noRefreshToken")
        case .identityFailed(let msg): return String(format: String(localized: "accounts.error.identityFailed"), msg)
        case .cannotRemoveLast: return String(localized: "accounts.error.cannotRemoveLast")
        case .vault(let msg): return String(format: String(localized: "accounts.error.vault"), msg)
        }
    }
}

extension Notification.Name {
    /// Posted once when the catalog goes from one profile to several, so the
    /// popover can surface its profile switcher (one-shot, see SettingsStore).
    static let profilesBecameMultiple = Notification.Name("profilesBecameMultiple")
}

/// Owns the profile catalog and one `UsageStore` per profile. The active
/// profile drives the menu bar / popover / dashboard hero; every enabled
/// profile refreshes on its own. See `docs/multi-profile-plan.md` §4.1.
///
/// Child stores relay their `objectWillChange` here so a single observer
/// (`StatusBarController`) sees every profile's updates.
@MainActor
final class ProfileStore: ObservableObject {
    typealias UsageStoreFactory = (AccountProfile) -> UsageStore
    typealias StoreConfigurator = (UsageStore) -> Void

    @Published private(set) var profiles: [AccountProfile] = []
    @Published private(set) var activeProfileID: UUID
    @Published private(set) var credentialStates: [UUID: ProfileCredentialState] = [:]
    @Published private(set) var lastError: ProfileStoreError?

    private(set) var usageStores: [UUID: UsageStore] = [:]
    private var relays: [UUID: AnyCancellable] = [:]

    private let persistence: ProfilePersistenceProtocol
    private let vault: ProfileCredentialVaultProtocol
    private let credentialStore: ClaudeCodeCredentialStoreProtocol
    private let refresher: OAuthTokenRefresherProtocol
    private let sharedFileService: SharedFileServiceProtocol
    private let identityClient: APIClientProtocol
    private let realHome: String
    private var usageStoreFactory: UsageStoreFactory!
    private var configurator: StoreConfigurator?
    private var thresholds: UsageThresholds = .default
    private var didBootstrap = false

    /// Default profile created on first launch / after migration (§1.4).
    static let defaultProfileName = "Claude Code"
    /// Seconds between consecutive profile auto-refresh loop starts.
    static let bootstrapStagger: TimeInterval = 5

    init(
        persistence: ProfilePersistenceProtocol = UserDefaultsProfilePersistence(),
        vault: ProfileCredentialVaultProtocol = UnavailableProfileCredentialVault(),
        credentialStore: ClaudeCodeCredentialStoreProtocol = UnavailableClaudeCodeCredentialStore(),
        refresher: OAuthTokenRefresherProtocol = UnavailableOAuthTokenRefresher(),
        sharedFileService: SharedFileServiceProtocol = SharedFileService(),
        identityClient: APIClientProtocol = APIClient(),
        realHome: String = ClaudeKeychainServiceName.realHome,
        usageStoreFactory: UsageStoreFactory? = nil
    ) {
        self.persistence = persistence
        self.vault = vault
        self.credentialStore = credentialStore
        self.refresher = refresher
        self.sharedFileService = sharedFileService
        self.identityClient = identityClient
        self.realHome = realHome

        let stored = persistence.loadProfiles()
        self.profiles = stored
        self.activeProfileID = persistence.loadActiveProfileID() ?? stored.first?.id ?? UUID()

        // Wired after every stored property so the closure can capture self.
        self.usageStoreFactory = usageStoreFactory ?? { [weak self] profile in
            Self.makeDefaultUsageStore(for: profile, owner: self)
        }

        ensureDefaultProfileIfNeeded()
        if !profiles.contains(where: { $0.id == activeProfileID }), let first = profiles.first {
            activeProfileID = first.id
            persistence.saveActiveProfileID(first.id)
        }
    }

    // MARK: - Derived

    var enabledProfiles: [AccountProfile] { profiles.filter(\.isEnabled) }

    var activeProfile: AccountProfile {
        profiles.first { $0.id == activeProfileID } ?? profiles[0]
    }

    /// The store the menu bar / popover / dashboard render.
    var activeUsageStore: UsageStore {
        usageStore(for: activeProfileID) ?? usageStore(for: profiles[0].id)!
    }

    var isMultiProfile: Bool { profiles.count > 1 }

    func profile(for id: UUID) -> AccountProfile? {
        profiles.first { $0.id == id }
    }

    /// Creates the store lazily and relays its changes. Returns nil for an
    /// unknown id.
    func usageStore(for id: UUID) -> UsageStore? {
        if let existing = usageStores[id] { return existing }
        guard let profile = profile(for: id) else { return nil }
        let store = usageStoreFactory(profile)
        store.isActiveProfile = (id == activeProfileID)
        usageStores[id] = store
        relays[id] = store.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        return store
    }

    /// `<configDir>/.credentials.json` for every linked profile, for the
    /// filesystem watcher. Managed profiles have no file to watch.
    var watchedCredentialFiles: [(directory: String, filename: String)] {
        var seen = Set<String>()
        var result: [(directory: String, filename: String)] = []
        for profile in profiles where profile.isLinked {
            let dir = profile.resolvedConfigDir(realHome: realHome)
            guard seen.insert(dir).inserted else { continue }
            result.append((directory: dir, filename: ".credentials.json"))
        }
        return result
    }

    // MARK: - Migration

    /// Guarantees at least one profile: the default Claude Code profile bound
    /// to `~/.claude`, behaving exactly like the pre-multi-profile app.
    func ensureDefaultProfileIfNeeded() {
        guard profiles.isEmpty else { return }
        let profile = AccountProfile(
            name: Self.defaultProfileName,
            colorHex: ProfilePalette.presets[0],
            source: .claudeCode(configDir: nil),
            renewalPolicy: .claudeCode
        )
        profiles = [profile]
        activeProfileID = profile.id
        persist()
    }

    // MARK: - Mutations

    /// Links a Claude Code config directory (`nil` = default). Reads the live
    /// credentials once to validate and seed the vault, then fetches the
    /// account identity (best effort) to fill email / plan and reject a
    /// duplicate account.
    @discardableResult
    func addLinkedProfile(name: String, configDir: String?) async throws -> AccountProfile {
        let resolved = ClaudeKeychainServiceName.normalize(configDir ?? (realHome + "/.claude"), realHome: realHome)
        if profiles.contains(where: { $0.isLinked && $0.resolvedConfigDir(realHome: realHome) == resolved }) {
            throw record(.duplicateConfigDir)
        }
        let normalizedDir: String? = ClaudeKeychainServiceName.isDefaultDir(configDir, realHome: realHome) ? nil : resolved
        guard let live = await readLiveOffMain(configDir: normalizedDir) else {
            throw record(.noCredentials)
        }
        var profile = AccountProfile(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            colorHex: ProfilePalette.next(after: profiles.map(\.colorHex)),
            source: .claudeCode(configDir: normalizedDir),
            renewalPolicy: .claudeCode
        )
        do {
            try vault.save(live.credentials, profileID: profile.id)
        } catch {
            throw record(.vault(String(describing: error)))
        }
        try await fillIdentity(&profile, accessToken: live.credentials.accessToken)
        insert(profile)
        return profile
    }

    /// Captures the credentials Claude Code currently holds in the default
    /// store into a managed profile owned (and renewed) by TokenEater.
    @discardableResult
    func captureCurrentLogin(name: String) async throws -> AccountProfile {
        guard let live = await readLiveOffMain(configDir: nil) else {
            throw record(.noCredentials)
        }
        guard live.credentials.refreshToken != nil else {
            throw record(.noRefreshToken)
        }
        var profile = AccountProfile(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            colorHex: ProfilePalette.next(after: profiles.map(\.colorHex)),
            source: .managed,
            renewalPolicy: .tokenEater
        )
        do {
            try vault.save(live.credentials, profileID: profile.id)
        } catch {
            throw record(.vault(String(describing: error)))
        }
        try await fillIdentity(&profile, accessToken: live.credentials.accessToken)
        insert(profile)
        return profile
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(id) { $0.name = trimmed }
    }

    func setColor(_ id: UUID, hex: String) {
        update(id) { $0.colorHex = hex }
    }

    func setEnabled(_ id: UUID, _ enabled: Bool) {
        guard let profile = profile(for: id), profile.isEnabled != enabled else { return }
        update(id) { $0.isEnabled = enabled }
        if enabled {
            startIfBootstrapped(id)
        } else {
            usageStores[id]?.stopAutoRefresh()
            if id == activeProfileID, let fallback = enabledProfiles.first {
                setActive(fallback.id)
            }
        }
    }

    func setRenewalPolicy(_ id: UUID, _ policy: TokenRenewalPolicy) {
        update(id) { $0.renewalPolicy = policy }
    }

    func remove(_ id: UUID) throws {
        guard profiles.contains(where: { $0.id == id }) else { throw record(.notFound) }
        guard profiles.count > 1 else { throw record(.cannotRemoveLast) }
        usageStores[id]?.stopAutoRefresh()
        usageStores[id] = nil
        relays[id] = nil
        credentialStates[id] = nil
        vault.delete(profileID: id)
        sharedFileService.removeProfile(id: id)
        profiles.removeAll { $0.id == id }
        if activeProfileID == id, let fallback = enabledProfiles.first ?? profiles.first {
            setActive(fallback.id)
        } else {
            persist()
        }
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        profiles.move(fromOffsets: fromOffsets, toOffset: toOffset)
        persist()
    }

    /// Switches the profile the menu bar / popover / dashboard render. Also
    /// republishes that profile's last usage as the legacy top-level snapshot
    /// so unpinned widgets flip immediately.
    func setActive(_ id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        activeProfileID = id
        for (storeID, store) in usageStores {
            store.isActiveProfile = (storeID == id)
        }
        persistence.saveActiveProfileID(id)
        if let cached = sharedFileService.profileSnapshots.first(where: { $0.id == id })?.cachedUsage {
            sharedFileService.updateAfterSync(usage: cached, syncDate: cached.fetchDate)
        }
        syncCatalogToSharedFile()
    }

    // MARK: - Lifecycle

    /// Starts every enabled profile: applies the configurator, reloads the
    /// cached snapshot, and starts the staggered auto-refresh loops.
    func bootstrap(configure: @escaping StoreConfigurator, thresholds: UsageThresholds) {
        self.configurator = configure
        self.thresholds = thresholds
        didBootstrap = true
        for (index, profile) in enabledProfiles.enumerated() {
            guard let store = usageStore(for: profile.id) else { continue }
            configure(store)
            store.reloadConfig(thresholds: thresholds)
            store.startAutoRefresh(
                thresholds: thresholds,
                initialDelay: TimeInterval(index) * Self.bootstrapStagger
            )
        }
        syncCatalogToSharedFile()
    }

    func stopAll() {
        for store in usageStores.values { store.stopAutoRefresh() }
    }

    func refreshAll(force: Bool) async {
        for profile in enabledProfiles {
            guard let store = usageStores[profile.id] else { continue }
            await store.refresh(thresholds: thresholds, force: force)
            recordCredentialState(for: profile.id)
        }
    }

    func handleTokenChange() {
        for profile in enabledProfiles {
            guard let store = usageStores[profile.id] else { continue }
            store.handleTokenChange()
            Task { [weak self] in
                await store.refresh(thresholds: self?.thresholds ?? .default, force: true)
                self?.recordCredentialState(for: profile.id)
            }
        }
    }

    func refreshIfStaleAll() async {
        for profile in enabledProfiles {
            guard let store = usageStores[profile.id] else { continue }
            await store.refreshIfStale(thresholds: thresholds)
            recordCredentialState(for: profile.id)
        }
    }

    /// Re-applies the settings-derived configuration to every store (called
    /// when a new profile is added after bootstrap).
    func reconfigureAll() {
        guard let configurator else { return }
        for store in usageStores.values { configurator(store) }
    }

    // MARK: - Private

    private func insert(_ profile: AccountProfile) {
        let wasSingle = profiles.count == 1
        profiles.append(profile)
        persist()
        startIfBootstrapped(profile.id)
        if wasSingle && profiles.count == 2 {
            NotificationCenter.default.post(name: .profilesBecameMultiple, object: nil)
        }
    }

    private func update(_ id: UUID, _ transform: (inout AccountProfile) -> Void) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        transform(&profiles[index])
        persist()
    }

    private func startIfBootstrapped(_ id: UUID) {
        guard didBootstrap, let profile = profile(for: id), profile.isEnabled,
              let store = usageStore(for: id) else { return }
        configurator?(store)
        store.reloadConfig(thresholds: thresholds)
        store.startAutoRefresh(thresholds: thresholds)
    }

    private func persist() {
        persistence.saveProfiles(profiles)
        persistence.saveActiveProfileID(activeProfileID)
        syncCatalogToSharedFile()
    }

    private func syncCatalogToSharedFile() {
        sharedFileService.updateProfileCatalog(
            profiles.map(SharedProfileSnapshot.init(profile:)),
            activeProfileID: activeProfileID
        )
        WidgetReloader.scheduleReload()
    }

    private func recordCredentialState(for id: UUID) {
        guard let store = usageStores[id] else { return }
        credentialStates[id] = store.credentialState
    }

    @discardableResult
    private func record(_ error: ProfileStoreError) -> ProfileStoreError {
        lastError = error
        return error
    }

    /// Live reads may shell out to `/usr/bin/security` (up to 3 s): keep them
    /// off the main actor.
    private func readLiveOffMain(configDir: String?) async -> ClaudeCodeCredentialRead? {
        let store = credentialStore
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: store.read(configDir: configDir))
            }
        }
    }

    /// Best-effort identity fetch: fills email / uuid / plan and rejects a
    /// duplicate account. A transport failure keeps the profile (no identity).
    private func fillIdentity(_ profile: inout AccountProfile, accessToken: String) async throws {
        guard let response = try? await identityClient.fetchProfile(token: accessToken, proxyConfig: nil) else {
            return
        }
        if let existing = profiles.first(where: { $0.accountUUID == response.account.uuid }) {
            vault.delete(profileID: profile.id)
            throw record(.duplicateAccount(existingName: existing.name))
        }
        profile.accountEmail = response.account.email
        profile.accountUUID = response.account.uuid
        profile.planTypeRaw = PlanType(from: response.account, organization: response.organization).rawValue
    }

    /// Production factory. Phase 0: the default profile keeps the legacy
    /// `TokenProvider` (identical behaviour); other profiles get a placeholder
    /// until `ProfileTokenProvider` lands (integration swaps this).
    private static func makeDefaultUsageStore(for profile: AccountProfile, owner: ProfileStore?) -> UsageStore {
        let isDefault = profile.isDefaultClaudeCodeProfile
        let provider: TokenProviderProtocol = isDefault ? TokenProvider() : PlaceholderTokenProvider()
        return UsageStore(
            repository: UsageRepository(profileID: profile.id),
            tokenProvider: provider,
            profileID: profile.id,
            legacyKeys: isDefault
        )
    }
}

// MARK: - Placeholders (replaced at integration)

/// Token provider that never yields a token. Stands in for
/// `ProfileTokenProvider` until the credentials lane lands.
final class PlaceholderTokenProvider: TokenProviderProtocol, @unchecked Sendable {
    var isBootstrapped: Bool { true }
    func currentToken() -> String? { nil }
    func hasTokenSource() -> Bool { false }
    func invalidateToken() {}
    func refreshTokenIfChanged() -> Bool { false }
    func bootstrap() throws {}
    func ensureFreshToken(force: Bool) async -> TokenReadiness { .missing }
    var credentialState: ProfileCredentialState { .missing }
}

final class UnavailableProfileCredentialVault: ProfileCredentialVaultProtocol, @unchecked Sendable {
    func load(profileID: UUID) -> OAuthCredentials? { nil }
    func save(_ credentials: OAuthCredentials, profileID: UUID) throws {
        throw ProfileCredentialVaultError.keychain(status: -1)
    }
    func delete(profileID: UUID) {}
}

final class UnavailableClaudeCodeCredentialStore: ClaudeCodeCredentialStoreProtocol, @unchecked Sendable {
    func read(configDir: String?) -> ClaudeCodeCredentialRead? { nil }
    func exists(configDir: String?) -> Bool { false }
    func write(_ credentials: OAuthCredentials, raw: [String: Any], backing: ClaudeCodeCredentialBacking) throws {
        throw ClaudeCodeCredentialStoreError.readOnlyBacking
    }
}

final class UnavailableOAuthTokenRefresher: OAuthTokenRefresherProtocol, @unchecked Sendable {
    func refresh(_ credentials: OAuthCredentials, proxyConfig: ProxyConfig?) async throws -> OAuthCredentials {
        throw OAuthRefreshError.noRefreshToken
    }
}
