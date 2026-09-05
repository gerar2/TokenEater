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
/// (`StatusBarController`) sees every profile's updates, and their
/// `credentialState` is mirrored into `credentialStates` on every change
/// (including changes made by a store's own auto-refresh loop).
@MainActor
final class ProfileStore: ObservableObject {
    typealias UsageStoreFactory = (AccountProfile) -> UsageStore
    typealias StoreConfigurator = (UsageStore) -> Void
    typealias TokenProviderFactory = (AccountProfile) -> TokenProviderProtocol
    typealias NotificationServiceFactory = (AccountProfile) -> NotificationServiceProtocol
    typealias WatchedFile = (directory: String, filename: String)

    @Published private(set) var profiles: [AccountProfile] = []
    @Published private(set) var activeProfileID: UUID
    /// Mirror of every store's `credentialState`. Seeded at `bootstrap` / on
    /// insert and kept current by a relay; an entry is missing only for a
    /// store created outside those paths that has not refreshed yet (use
    /// `credentialState(for:)`, which falls back to the store).
    @Published private(set) var credentialStates: [UUID: ProfileCredentialState] = [:]
    @Published private(set) var lastError: ProfileStoreError?

    private(set) var usageStores: [UUID: UsageStore] = [:]
    /// Providers built by the production factory, keyed by profile (empty
    /// when a `usageStoreFactory` is injected). Lets the app forward runtime
    /// profile edits (renewal policy) to the provider.
    private(set) var tokenProviders: [UUID: TokenProviderProtocol] = [:]
    /// Notification services built by the production factory, so a removed
    /// profile's pending reminders can be cancelled in its own scope.
    private var notificationServices: [UUID: NotificationServiceProtocol] = [:]
    /// Thread-safe view of profile names for the notification title prefix
    /// (`NotificationScope.displayName` is `@Sendable`).
    private let nameRegistry = ProfileNameRegistry()
    private var relays: [UUID: [AnyCancellable]] = [:]

    private let persistence: ProfilePersistenceProtocol
    private let vault: ProfileCredentialVaultProtocol
    private let credentialStore: ClaudeCodeCredentialStoreProtocol
    private let refresher: OAuthTokenRefresherProtocol
    private let sharedFileService: SharedFileServiceProtocol
    private let identityClient: APIClientProtocol
    private let realHome: String
    private let injectedUsageStoreFactory: UsageStoreFactory?
    private var configurator: StoreConfigurator?
    private var thresholds: UsageThresholds = .default
    private var didBootstrap = false

    // MARK: Integration seams (set before the first store is created)

    /// Builds the token provider for a profile. `nil` = `makeDefaultTokenProvider`.
    /// Stores are created lazily (at `bootstrap`, on insert, or on first
    /// access), so assign this right after `init` for it to apply everywhere.
    var tokenProviderFactory: TokenProviderFactory?
    /// Builds the notification service for a profile. `nil` =
    /// `makeDefaultNotificationService`: the default profile keeps the legacy
    /// unsuffixed keys, every other profile gets a scoped service, and all of
    /// them prefix titles with the profile name while several profiles exist
    /// (see §3.7).
    var notificationServiceFactory: NotificationServiceFactory?
    /// Proxy for the identity fetch and the per-profile token providers. Read
    /// from the persisted settings so it is always current and usable off the
    /// main actor.
    var proxyProvider: @Sendable () -> ProxyConfig? = { ProxyConfig.fromUserDefaults() }
    /// Called after a profile's fields change (rename / colour / enable /
    /// policy / identity) with the provider that serves it, so a
    /// `ProfileTokenProvider` can pick up a policy change at runtime.
    var onProfileUpdated: ((AccountProfile, TokenProviderProtocol?) -> Void)?
    /// Where `.profilesBecameMultiple` is posted (tests use a private center
    /// so a `SettingsStore` alive in another suite never sees the post).
    var notificationCenter: NotificationCenter = .default
    /// Directory check for `addLinkedProfile` (tests inject `{ _ in true }`).
    var directoryExists: (String) -> Bool = { path in
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Default profile created on first launch / after migration (§1.4).
    static let defaultProfileName = "Claude Code"
    /// Seconds between consecutive profile auto-refresh loop starts.
    static let bootstrapStagger: TimeInterval = 5

    init(
        persistence: ProfilePersistenceProtocol = UserDefaultsProfilePersistence(),
        vault: ProfileCredentialVaultProtocol = ProfileCredentialVault(),
        credentialStore: ClaudeCodeCredentialStoreProtocol = ClaudeCodeCredentialStore(),
        refresher: OAuthTokenRefresherProtocol = OAuthTokenRefresher(),
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
        self.injectedUsageStoreFactory = usageStoreFactory

        let stored = persistence.loadProfiles()
        self.profiles = stored
        self.activeProfileID = persistence.loadActiveProfileID() ?? stored.first?.id ?? UUID()

        ensureDefaultProfileIfNeeded()
        // A stale active id (profile removed by an older build, corrupted
        // default) must never leave the app without an active profile.
        if !profiles.contains(where: { $0.id == activeProfileID }), let first = profiles.first {
            activeProfileID = first.id
            persistence.saveActiveProfileID(first.id)
        }
        nameRegistry.update(profiles: profiles)
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

    /// The mirrored state, falling back to the store for an entry that has
    /// not been seeded yet.
    func credentialState(for id: UUID) -> ProfileCredentialState {
        credentialStates[id] ?? usageStores[id]?.credentialState ?? .unknown
    }

    /// Creates the store lazily and wires its relays. Returns nil for an
    /// unknown id. Creation publishes nothing on this store (the relays skip
    /// the initial values), so a SwiftUI body reading `activeUsageStore` for
    /// the first time never mutates state mid-render.
    func usageStore(for id: UUID) -> UsageStore? {
        if let existing = usageStores[id] { return existing }
        guard let profile = profile(for: id) else { return nil }
        let store = injectedUsageStoreFactory?(profile) ?? makeDefaultUsageStore(for: profile)
        store.isActiveProfile = (id == activeProfileID)
        usageStores[id] = store
        relays[id] = [
            // The piège (same as SettingsStore): a child ObservableObject does
            // not bubble its changes up. Relay so one observer sees all stores.
            store.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            },
            store.$credentialState
                .dropFirst()
                .removeDuplicates()
                .sink { [weak self] state in
                    self?.credentialStates[id] = state
                },
            store.$accountIdentity
                .dropFirst()
                .compactMap { $0 }
                .removeDuplicates()
                .sink { [weak self] identity in
                    self?.applyIdentity(identity, to: id)
                },
        ]
        return store
    }

    /// `<configDir>/.credentials.json` for every linked profile on top of the
    /// two legacy entries (Claude Desktop `config.json`, default
    /// `~/.claude/.credentials.json`), for the filesystem watcher. Managed
    /// profiles have no file to watch. De-duplicated: the default profile's
    /// entry is the legacy one.
    var watchedCredentialFiles: [WatchedFile] {
        var result = TokenFileMonitor.legacyWatchedFiles(realHome: realHome)
        var seen = Set(result.map { $0.directory + "/" + $0.filename })
        for profile in profiles where profile.isLinked {
            let dir = profile.resolvedConfigDir(realHome: realHome)
            let filename = ".credentials.json"
            guard seen.insert(dir + "/" + filename).inserted else { continue }
            result.append((directory: dir, filename: filename))
        }
        return result
    }

    // MARK: - Migration

    /// Guarantees at least one profile: the default Claude Code profile bound
    /// to `~/.claude`, behaving exactly like the pre-multi-profile app (legacy
    /// pacing-sample and notification keys, legacy widget snapshot).
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
        if let dir = normalizedDir, !directoryExists(dir) {
            throw record(.noCredentials)
        }
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
        // Without a refresh token TokenEater could never renew the copy: the
        // profile would die with the access token (Claude Desktop-only users).
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

    /// Pausing the active profile hands the active role to the first enabled
    /// one so the menu bar never shows a profile that stopped refreshing.
    func setEnabled(_ id: UUID, _ enabled: Bool) {
        guard let current = profile(for: id), current.isEnabled != enabled else { return }
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
        relays[id] = nil
        usageStores[id] = nil
        tokenProviders[id] = nil
        notificationServices[id]?.cancelPendingReminders()
        notificationServices[id] = nil
        credentialStates[id] = nil
        vault.delete(profileID: id)
        sharedFileService.removeProfile(id: id)
        profiles.removeAll { $0.id == id }
        if activeProfileID == id, let fallback = enabledProfiles.first ?? profiles.first {
            activate(fallback.id)
        }
        persist()
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        profiles.move(fromOffsets: fromOffsets, toOffset: toOffset)
        persist()
    }

    /// Switches the profile the menu bar / popover / dashboard render. Also
    /// republishes that profile's last usage as the legacy top-level snapshot
    /// so unpinned widgets flip immediately. The UI only offers enabled
    /// profiles; any known id is accepted here.
    func setActive(_ id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        activate(id)
        persistence.saveActiveProfileID(id)
        syncCatalogToSharedFile()
    }

    func clearError() {
        lastError = nil
    }

    // MARK: - Lifecycle

    /// Starts every enabled profile: applies the configurator, reloads the
    /// cached snapshot, and starts the staggered auto-refresh loops. Every
    /// profile gets a store (the Accounts UI observes paused ones too); only
    /// enabled ones refresh.
    func bootstrap(configure: @escaping StoreConfigurator, thresholds: UsageThresholds) {
        self.configurator = configure
        self.thresholds = thresholds
        didBootstrap = true
        for profile in profiles {
            _ = usageStore(for: profile.id)
        }
        for (index, profile) in enabledProfiles.enumerated() {
            guard let store = usageStores[profile.id] else { continue }
            configure(store)
            store.reloadConfig(thresholds: thresholds)
            store.startAutoRefresh(
                thresholds: thresholds,
                initialDelay: TimeInterval(index) * Self.bootstrapStagger
            )
        }
        syncCredentialStates()
        syncCatalogToSharedFile()
    }

    func stopAll() {
        for store in usageStores.values { store.stopAutoRefresh() }
    }

    /// Sequential on purpose: "Refresh now" must not burst N requests at the
    /// same instant any more than the staggered loops do.
    func refreshAll(force: Bool) async {
        for profile in enabledProfiles {
            guard let store = usageStores[profile.id] else { continue }
            await store.refresh(thresholds: thresholds, force: force)
        }
    }

    /// A watched credential file changed. Only linked profiles read those
    /// files; a managed profile's credentials live in the vault, so
    /// invalidating them would only force a needless refresh-grant round
    /// trip (its provider adopts newer same-chain credentials on its next
    /// tick anyway).
    func handleTokenChange() {
        for profile in enabledProfiles where profile.isLinked {
            guard let store = usageStores[profile.id] else { continue }
            store.handleTokenChange()
            Task { [weak self] in
                await store.refresh(thresholds: self?.thresholds ?? .default, force: true)
            }
        }
    }

    func refreshIfStaleAll() async {
        for profile in enabledProfiles {
            guard let store = usageStores[profile.id] else { continue }
            await store.refreshIfStale(thresholds: thresholds)
        }
    }

    /// Re-applies the settings-derived configuration to every store (called
    /// when a setting changes after bootstrap).
    func reconfigureAll() {
        guard let configurator else { return }
        for store in usageStores.values { configurator(store) }
    }

    // MARK: - Private

    private func insert(_ profile: AccountProfile) {
        let wasSingle = profiles.count == 1
        profiles.append(profile)
        persist()
        _ = usageStore(for: profile.id)
        syncCredentialState(for: profile.id)
        startIfBootstrapped(profile.id)
        if wasSingle && profiles.count == 2 {
            notificationCenter.post(name: .profilesBecameMultiple, object: nil)
        }
    }

    private func update(_ id: UUID, _ transform: (inout AccountProfile) -> Void) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        transform(&profiles[index])
        persist()
        // A `ProfileTokenProvider` reads the renewal policy at refresh time
        // from the profile it was given; hand it the edited value.
        (tokenProviders[id] as? ProfileTokenProvider)?.update(profile: profiles[index])
        onProfileUpdated?(profiles[index], tokenProviders[id])
    }

    private func activate(_ id: UUID) {
        activeProfileID = id
        for (storeID, store) in usageStores {
            store.isActiveProfile = (storeID == id)
        }
        republishLegacySnapshot(for: id)
    }

    /// Legacy widgets and `isConfigured` read the top-level `cachedUsage`,
    /// which only the active profile's repository writes. Copy the new active
    /// profile's last usage there now instead of waiting for its next fetch.
    private func republishLegacySnapshot(for id: UUID) {
        if let cached = sharedFileService.profileSnapshots.first(where: { $0.id == id })?.cachedUsage {
            sharedFileService.updateAfterSync(usage: cached, syncDate: cached.fetchDate)
        } else if let store = usageStores[id], let usage = store.lastUsage {
            let date = store.lastUpdate ?? Date()
            sharedFileService.updateAfterSync(usage: CachedUsage(usage: usage, fetchDate: date), syncDate: date)
        }
    }

    private func startIfBootstrapped(_ id: UUID) {
        guard didBootstrap, let profile = profile(for: id), profile.isEnabled,
              let store = usageStore(for: id) else { return }
        configurator?(store)
        store.reloadConfig(thresholds: thresholds)
        store.startAutoRefresh(thresholds: thresholds)
    }

    private func persist() {
        nameRegistry.update(profiles: profiles)
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

    private func syncCredentialStates() {
        var states = credentialStates
        for (id, store) in usageStores {
            states[id] = store.credentialState
        }
        if states != credentialStates {
            credentialStates = states
        }
    }

    private func syncCredentialState(for id: UUID) {
        guard let store = usageStores[id], credentialStates[id] != store.credentialState else { return }
        credentialStates[id] = store.credentialState
    }

    /// Mirrors what `/api/oauth/profile` said into the catalog. Fills the
    /// migrated default profile's identity (it never went through
    /// `fillIdentity`) and keeps email / plan current after an account swap.
    private func applyIdentity(_ identity: UsageStore.AccountIdentity, to id: UUID) {
        guard let current = profile(for: id) else { return }
        let email = identity.email ?? current.accountEmail
        let uuid = identity.uuid ?? current.accountUUID
        let plan = identity.planTypeRaw ?? current.planTypeRaw
        guard email != current.accountEmail || uuid != current.accountUUID || plan != current.planTypeRaw else { return }
        update(id) {
            $0.accountEmail = email
            $0.accountUUID = uuid
            $0.planTypeRaw = plan
        }
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
    /// duplicate account (cleaning the vault entry seeded for it). A
    /// transport failure keeps the profile (no identity).
    private func fillIdentity(_ profile: inout AccountProfile, accessToken: String) async throws {
        guard let response = try? await identityClient.fetchProfile(token: accessToken, proxyConfig: proxyProvider()) else {
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

    /// Production factory: one repository + token provider + notification
    /// service per profile, all sharing this store's `SharedFileService` so
    /// the JSON cache is written through a single instance. The migrated
    /// default profile keeps the legacy keys.
    private func makeDefaultUsageStore(for profile: AccountProfile) -> UsageStore {
        let provider = tokenProviderFactory?(profile) ?? makeDefaultTokenProvider(for: profile)
        tokenProviders[profile.id] = provider
        let notifications = notificationServiceFactory?(profile) ?? makeDefaultNotificationService(for: profile)
        notificationServices[profile.id] = notifications
        return UsageStore(
            repository: UsageRepository(sharedFileService: sharedFileService, profileID: profile.id),
            tokenProvider: provider,
            sharedFileService: sharedFileService,
            notificationService: notifications,
            profileID: profile.id,
            legacyKeys: profile.isDefaultClaudeCodeProfile
        )
    }

    /// The default `~/.claude` profile keeps the legacy `TokenProvider`
    /// (identical behaviour to the single-account app, including the
    /// interactive onboarding read). Every other profile gets a
    /// `ProfileTokenProvider` over this store's vault / live store / refresher.
    private func makeDefaultTokenProvider(for profile: AccountProfile) -> TokenProviderProtocol {
        if profile.isDefaultClaudeCodeProfile { return TokenProvider() }
        return ProfileTokenProvider(
            profile: profile,
            vault: vault,
            store: credentialStore,
            refresher: refresher,
            proxyProvider: proxyProvider,
            realHome: realHome
        )
    }

    /// Legacy (unsuffixed) scope for the default profile so existing users keep
    /// their de-dupe state; a per-profile scope for the others. The `[Name]`
    /// title prefix is resolved at fire time through the name registry and is
    /// empty while only one profile exists.
    private func makeDefaultNotificationService(for profile: AccountProfile) -> NotificationServiceProtocol {
        let id = profile.id
        let registry = nameRegistry
        let scope = NotificationScope(
            profileID: profile.isDefaultClaudeCodeProfile ? nil : id,
            displayName: { registry.displayName(for: id) }
        )
        return NotificationService(scope: scope)
    }
}

// MARK: - Name registry

/// Lock-guarded snapshot of the catalog's names, for `@Sendable` readers such
/// as the notification title prefix. Updated by `ProfileStore` whenever the
/// catalog is persisted.
final class ProfileNameRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [UUID: String] = [:]
    private var isMultiProfile = false

    func update(profiles: [AccountProfile]) {
        lock.withLock {
            names = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0.name) })
            isMultiProfile = profiles.count > 1
        }
    }

    /// The profile's name while several profiles exist; nil otherwise so a
    /// single-profile user never sees a prefix.
    func displayName(for id: UUID) -> String? {
        lock.withLock { isMultiProfile ? names[id] : nil }
    }
}
