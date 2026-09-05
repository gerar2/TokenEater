import Testing
import Foundation
import Combine

/// Per-profile mocks captured by the injected store factory, so a test can
/// drive / inspect each profile's repository and token provider.
@MainActor
private final class ProfileMockBag {
    var repos: [UUID: MockUsageRepository] = [:]
    var providers: [UUID: MockTokenProvider] = [:]
    var notifs: [UUID: MockNotificationService] = [:]
    var factoryCalls: [UUID] = []

    func makeStore(for profile: AccountProfile, sharedFile: MockSharedFileService) -> UsageStore {
        let repo = MockUsageRepository()
        let provider = MockTokenProvider()
        provider.token = "token-" + profile.name
        let notif = MockNotificationService()
        repos[profile.id] = repo
        providers[profile.id] = provider
        notifs[profile.id] = notif
        factoryCalls.append(profile.id)
        return UsageStore(
            repository: repo,
            tokenProvider: provider,
            sharedFileService: sharedFile,
            notificationService: notif,
            profileID: profile.id,
            legacyKeys: profile.isDefaultClaudeCodeProfile
        )
    }
}

@MainActor
private final class ProfileHarness {
    static let home = "/Users/tester"
    static let workDir = "/Users/tester/.claude-work"

    let persistence: InMemoryProfilePersistence
    let vault = InMemoryProfileCredentialVault()
    let credentialStore = MockClaudeCodeCredentialStore()
    let refresher = MockOAuthTokenRefresher()
    let sharedFile: MockSharedFileService
    let identity = MockAPIClient()
    let bag: ProfileMockBag
    let center = NotificationCenter()
    let store: ProfileStore

    init(profiles: [AccountProfile] = [], activeID: UUID? = nil) {
        let persistence = InMemoryProfilePersistence(profiles: profiles, activeID: activeID)
        let sharedFile = MockSharedFileService()
        let bag = ProfileMockBag()
        self.persistence = persistence
        self.sharedFile = sharedFile
        self.bag = bag
        self.store = ProfileStore(
            persistence: persistence,
            vault: vault,
            credentialStore: credentialStore,
            refresher: refresher,
            sharedFileService: sharedFile,
            identityClient: identity,
            realHome: Self.home,
            usageStoreFactory: { profile in bag.makeStore(for: profile, sharedFile: sharedFile) }
        )
        store.directoryExists = { _ in true }
        store.notificationCenter = center
    }

    var defaultID: UUID { store.profiles[0].id }
}

private func makeProfile(
    name: String,
    dir: String? = nil,
    source: ProfileCredentialSource? = nil,
    uuid: String? = nil,
    enabled: Bool = true
) -> AccountProfile {
    AccountProfile(
        name: name,
        source: source ?? .claudeCode(configDir: dir),
        isEnabled: enabled,
        accountUUID: uuid
    )
}

/// Fixed expiry so two calls compare equal.
private let credsExpiry = Date(timeIntervalSince1970: 1_900_000_000)

private func creds(_ token: String = "at", refresh: String? = "rt") -> OAuthCredentials {
    OAuthCredentials(accessToken: token, refreshToken: refresh, expiresAt: credsExpiry)
}

private func identityResponse(uuid: String, email: String = "me@example.com", pro: Bool = true) -> ProfileResponse {
    ProfileResponse(
        account: AccountInfo(uuid: uuid, fullName: "Test", displayName: "Test", email: email, hasClaudeMax: false, hasClaudePro: pro),
        organization: nil
    )
}

private func expectError(_ expected: ProfileStoreError, _ body: () async throws -> Void) async {
    do {
        try await body()
        Issue.record("Expected \(expected) to be thrown")
    } catch let error as ProfileStoreError {
        #expect(error == expected)
    } catch {
        Issue.record("Expected ProfileStoreError, got \(error)")
    }
}

@Suite("ProfileStore")
@MainActor
struct ProfileStoreTests {

    // MARK: - Migration / loading

    @Test("first launch creates the default Claude Code profile, makes it active and persists it")
    func migrationCreatesDefaultProfile() {
        let h = ProfileHarness()

        #expect(h.store.profiles.count == 1)
        let profile = h.store.activeProfile
        #expect(profile.name == ProfileStore.defaultProfileName)
        #expect(profile.source == .claudeCode(configDir: nil))
        #expect(profile.renewalPolicy == .claudeCode)
        #expect(profile.colorHex == ProfilePalette.presets[0])
        #expect(profile.isEnabled)
        #expect(h.store.activeProfileID == profile.id)
        #expect(h.store.isMultiProfile == false)
        #expect(h.persistence.hasStoredProfiles)
        #expect(h.persistence.profiles.map(\.id) == [profile.id])
        #expect(h.persistence.activeID == profile.id)
        #expect(h.sharedFile.updateProfileCatalogCallCount == 1)
        #expect(h.sharedFile.activeProfileID == profile.id)
    }

    @Test("the migrated default profile keeps the legacy keys")
    func migratedProfileUsesLegacyKeys() {
        let h = ProfileHarness()
        let store = h.store.activeUsageStore
        #expect(store.usesLegacyKeys)
        #expect(store.sessionSamplesStorageKey == "sessionPacingSamples")
        #expect(store.profileID == h.defaultID)
        #expect(store.isActiveProfile)
    }

    @Test("a stored catalog and active id load as-is without a migration write")
    func loadsStoredCatalog() {
        let a = makeProfile(name: "A")
        let b = makeProfile(name: "B", dir: ProfileHarness.workDir)
        let h = ProfileHarness(profiles: [a, b], activeID: b.id)

        #expect(h.store.profiles == [a, b])
        #expect(h.store.activeProfileID == b.id)
        #expect(h.store.activeProfile == b)
        #expect(h.store.isMultiProfile)
        #expect(h.persistence.saveProfilesCallCount == 0)
    }

    @Test("a stale active id falls back to the first profile and is persisted")
    func staleActiveIDFallsBack() {
        let a = makeProfile(name: "A")
        let b = makeProfile(name: "B", dir: ProfileHarness.workDir)
        let h = ProfileHarness(profiles: [a, b], activeID: UUID())

        #expect(h.store.activeProfileID == a.id)
        #expect(h.persistence.activeID == a.id)
    }

    @Test("ensureDefaultProfileIfNeeded is a no-op once a catalog exists")
    func ensureDefaultNoOp() {
        let h = ProfileHarness()
        let before = h.store.profiles
        h.store.ensureDefaultProfileIfNeeded()
        #expect(h.store.profiles == before)
    }

    // MARK: - addLinkedProfile

    @Test("addLinkedProfile seeds the vault, fills the identity and inserts an enabled profile")
    func addLinkedProfileHappyPath() async throws {
        let h = ProfileHarness()
        h.credentialStore.stub(configDir: ProfileHarness.workDir, credentials: creds("at-work"))
        h.identity.stubbedProfile = identityResponse(uuid: "acc-work", email: "work@example.com")

        let profile = try await h.store.addLinkedProfile(name: "  Work ", configDir: "~/.claude-work/")

        #expect(profile.name == "Work")
        #expect(profile.source == .claudeCode(configDir: ProfileHarness.workDir))
        #expect(profile.renewalPolicy == .claudeCode)
        #expect(profile.isEnabled)
        #expect(profile.colorHex == ProfilePalette.presets[1])
        #expect(profile.accountUUID == "acc-work")
        #expect(profile.accountEmail == "work@example.com")
        #expect(profile.planTypeRaw == PlanType.pro.rawValue)
        #expect(h.vault.storage[profile.id] == creds("at-work"))
        #expect(h.store.profiles.count == 2)
        #expect(h.store.profiles.last == profile)
        #expect(h.store.activeProfileID == h.defaultID)
        #expect(h.persistence.profiles.count == 2)
        #expect(h.sharedFile.profileSnapshots.map(\.id).contains(profile.id))
        // The store exists right away (the Accounts UI observes it) but is
        // not refreshing: bootstrap has not run.
        #expect(h.bag.factoryCalls.contains(profile.id))
        #expect(h.store.usageStore(for: profile.id)?.isAutoRefreshRunning == false)
        #expect(h.store.usageStore(for: profile.id)?.usesLegacyKeys == false)
        #expect(h.store.lastError == nil)
    }

    @Test("addLinkedProfile rejects a directory already linked (default dir spelled any way)")
    func addLinkedProfileDuplicateDir() async {
        let h = ProfileHarness()
        h.credentialStore.stub(configDir: nil, credentials: creds())

        await expectError(.duplicateConfigDir) {
            try await h.store.addLinkedProfile(name: "Dup", configDir: nil)
        }
        await expectError(.duplicateConfigDir) {
            try await h.store.addLinkedProfile(name: "Dup", configDir: "~/.claude/")
        }
        #expect(h.store.lastError == .duplicateConfigDir)
        #expect(h.store.profiles.count == 1)
        #expect(h.credentialStore.readCallCount == 0)
        #expect(h.vault.saveCallCount == 0)
    }

    @Test("addLinkedProfile rejects an account already monitored and cleans the vault")
    func addLinkedProfileDuplicateAccount() async {
        let existing = makeProfile(name: "Claude Code", uuid: "acc-1")
        let h = ProfileHarness(profiles: [existing], activeID: existing.id)
        h.credentialStore.stub(configDir: ProfileHarness.workDir, credentials: creds("at-work"))
        h.identity.stubbedProfile = identityResponse(uuid: "acc-1")

        await expectError(.duplicateAccount(existingName: "Claude Code")) {
            try await h.store.addLinkedProfile(name: "Work", configDir: ProfileHarness.workDir)
        }
        #expect(h.vault.saveCallCount == 1)
        #expect(h.vault.deleteCallCount == 1)
        #expect(h.vault.storage.isEmpty)
        #expect(h.store.profiles.count == 1)
        #expect(h.store.lastError == .duplicateAccount(existingName: "Claude Code"))
    }

    @Test("addLinkedProfile fails without live credentials or without the directory")
    func addLinkedProfileNoCredentials() async {
        let h = ProfileHarness()

        await expectError(.noCredentials) {
            try await h.store.addLinkedProfile(name: "Work", configDir: ProfileHarness.workDir)
        }
        #expect(h.credentialStore.readCallCount == 1)

        h.credentialStore.stub(configDir: ProfileHarness.workDir, credentials: creds())
        h.store.directoryExists = { _ in false }
        await expectError(.noCredentials) {
            try await h.store.addLinkedProfile(name: "Work", configDir: ProfileHarness.workDir)
        }
        #expect(h.credentialStore.readCallCount == 1)
        #expect(h.store.profiles.count == 1)
    }

    @Test("addLinkedProfile keeps the profile when the identity fetch fails")
    func addLinkedProfileIdentityFailureIsSoft() async throws {
        let h = ProfileHarness()
        h.credentialStore.stub(configDir: ProfileHarness.workDir, credentials: creds())
        h.identity.stubbedError = APIError.invalidResponse(endpoint: "/api/oauth/profile")

        let profile = try await h.store.addLinkedProfile(name: "Work", configDir: ProfileHarness.workDir)

        #expect(profile.accountUUID == nil)
        #expect(h.store.profiles.count == 2)
    }

    // MARK: - captureCurrentLogin

    @Test("captureCurrentLogin copies the default store into a managed profile")
    func captureHappyPath() async throws {
        let h = ProfileHarness()
        h.credentialStore.stub(configDir: nil, credentials: creds("at-b", refresh: "rt-b"))
        h.identity.stubbedProfile = identityResponse(uuid: "acc-b", email: "b@example.com")
        let watchedBefore = h.store.watchedCredentialFiles.count

        let profile = try await h.store.captureCurrentLogin(name: "Personal")

        #expect(profile.source == .managed)
        #expect(profile.isLinked == false)
        #expect(profile.renewalPolicy == .tokenEater)
        #expect(profile.effectiveRenewalPolicy == .tokenEater)
        #expect(profile.accountUUID == "acc-b")
        #expect(h.vault.storage[profile.id] == creds("at-b", refresh: "rt-b"))
        #expect(h.store.profiles.count == 2)
        // A managed profile has no file to watch.
        #expect(h.store.watchedCredentialFiles.count == watchedBefore)
    }

    @Test("captureCurrentLogin refuses a login without a refresh token")
    func captureNoRefreshToken() async {
        let h = ProfileHarness()
        h.credentialStore.stub(configDir: nil, credentials: creds("at-desktop", refresh: nil), backing: .claudeDesktop)

        await expectError(.noRefreshToken) {
            try await h.store.captureCurrentLogin(name: "Personal")
        }
        #expect(h.vault.saveCallCount == 0)
        #expect(h.store.profiles.count == 1)
    }

    @Test("captureCurrentLogin fails when the default store is empty")
    func captureNoCredentials() async {
        let h = ProfileHarness()
        await expectError(.noCredentials) {
            try await h.store.captureCurrentLogin(name: "Personal")
        }
    }

    // MARK: - remove

    @Test("the last profile cannot be removed; an unknown id is notFound")
    func removeLastAndUnknown() {
        let h = ProfileHarness()
        #expect(throws: ProfileStoreError.cannotRemoveLast) {
            try h.store.remove(h.defaultID)
        }
        #expect(h.store.lastError == .cannotRemoveLast)
        #expect(throws: ProfileStoreError.notFound) {
            try h.store.remove(UUID())
        }
        #expect(h.store.profiles.count == 1)
    }

    @Test("removing the active profile re-targets the active id, deletes the vault entry and the snapshot")
    func removeActiveRetargets() throws {
        let a = makeProfile(name: "A")
        let b = makeProfile(name: "B", dir: ProfileHarness.workDir)
        let h = ProfileHarness(profiles: [a, b], activeID: a.id)
        h.vault.storage[a.id] = creds()
        let storeA = h.store.usageStore(for: a.id)!
        let storeB = h.store.usageStore(for: b.id)!
        storeA.startAutoRefresh()

        try h.store.remove(a.id)

        #expect(h.store.profiles == [b])
        #expect(h.store.activeProfileID == b.id)
        #expect(h.persistence.activeID == b.id)
        #expect(h.persistence.profiles == [b])
        #expect(h.vault.deleteCallCount == 1)
        #expect(h.vault.storage[a.id] == nil)
        #expect(h.sharedFile.removeProfileCallCount == 1)
        #expect(h.store.usageStore(for: a.id) == nil)
        #expect(storeA.isAutoRefreshRunning == false)
        #expect(storeB.isActiveProfile)
        #expect(h.store.activeUsageStore === storeB)
        #expect(h.store.credentialStates[a.id] == nil)
    }

    @Test("removing a non-active profile keeps the active id")
    func removeInactiveKeepsActive() throws {
        let a = makeProfile(name: "A")
        let b = makeProfile(name: "B", dir: ProfileHarness.workDir)
        let h = ProfileHarness(profiles: [a, b], activeID: a.id)

        try h.store.remove(b.id)

        #expect(h.store.activeProfileID == a.id)
        #expect(h.store.profiles == [a])
        #expect(h.persistence.profiles == [a])
    }

    // MARK: - setActive

    @Test("setActive flips isActiveProfile on the stores and republishes the legacy snapshot")
    func setActiveFlipsStoresAndLegacySnapshot() {
        let a = makeProfile(name: "A")
        let b = makeProfile(name: "B", dir: ProfileHarness.workDir)
        let h = ProfileHarness(profiles: [a, b], activeID: a.id)
        let storeA = h.store.usageStore(for: a.id)!
        let storeB = h.store.usageStore(for: b.id)!
        let fetchDate = Date().addingTimeInterval(-60)
        h.sharedFile.updateProfileUsage(
            profileID: b.id,
            usage: CachedUsage(usage: .fixture(fiveHourUtil: 77), fetchDate: fetchDate),
            syncDate: fetchDate,
            credentialState: "ok"
        )
        #expect(storeA.isActiveProfile && !storeB.isActiveProfile)

        h.store.setActive(b.id)

        #expect(h.store.activeProfileID == b.id)
        #expect(!storeA.isActiveProfile && storeB.isActiveProfile)
        #expect(h.store.activeUsageStore === storeB)
        #expect(h.persistence.activeID == b.id)
        #expect(h.sharedFile.activeProfileID == b.id)
        #expect(h.sharedFile.updateAfterSyncCallCount == 1)
        #expect(h.sharedFile.cachedUsage?.usage.fiveHour?.utilization == 77)
        #expect(h.sharedFile.lastSyncDate == fetchDate)
    }

    @Test("setActive falls back to the store's in-memory usage when no snapshot exists")
    func setActiveUsesStoreUsage() async {
        let a = makeProfile(name: "A")
        let b = makeProfile(name: "B", dir: ProfileHarness.workDir)
        let h = ProfileHarness(profiles: [a, b], activeID: a.id)
        let storeB = h.store.usageStore(for: b.id)!
        h.bag.repos[b.id]?.stubbedUsage = .fixture(fiveHourUtil: 55)
        await storeB.refresh()
        // B was inactive: its repository never wrote the legacy snapshot.
        #expect(h.bag.repos[b.id]?.lastIsActiveProfile == false)
        #expect(h.sharedFile.cachedUsage == nil)

        h.store.setActive(b.id)

        #expect(h.sharedFile.cachedUsage?.usage.fiveHour?.utilization == 55)
    }

    @Test("setActive ignores an unknown id")
    func setActiveUnknown() {
        let h = ProfileHarness()
        h.store.setActive(UUID())
        #expect(h.store.activeProfileID == h.defaultID)
    }

    // MARK: - setEnabled

    @Test("disabling the active profile hands the active role to the next enabled one")
    func disableActiveMovesActive() {
        let a = makeProfile(name: "A")
        let b = makeProfile(name: "B", dir: ProfileHarness.workDir)
        let h = ProfileHarness(profiles: [a, b], activeID: a.id)
        let storeA = h.store.usageStore(for: a.id)!
        storeA.startAutoRefresh()

        h.store.setEnabled(a.id, false)

        #expect(h.store.profile(for: a.id)?.isEnabled == false)
        #expect(h.store.enabledProfiles.map(\.id) == [b.id])
        #expect(h.store.activeProfileID == b.id)
        #expect(storeA.isAutoRefreshRunning == false)
        #expect(h.persistence.profiles.first?.isEnabled == false)
    }

    @Test("disabling the only enabled profile keeps it active")
    func disableOnlyEnabledKeepsActive() {
        let h = ProfileHarness()
        h.store.setEnabled(h.defaultID, false)
        #expect(h.store.activeProfileID == h.defaultID)
        #expect(h.store.enabledProfiles.isEmpty)
    }

    @Test("re-enabling after bootstrap configures and starts the store")
    func reenableStartsStore() {
        let a = makeProfile(name: "A")
        let b = makeProfile(name: "B", dir: ProfileHarness.workDir, enabled: false)
        let h = ProfileHarness(profiles: [a, b], activeID: a.id)
        var configured: [UUID] = []
        h.store.bootstrap(configure: { configured.append($0.profileID!) }, thresholds: .default)
        #expect(configured == [a.id])
        #expect(h.store.usageStore(for: b.id)?.isAutoRefreshRunning == false)

        h.store.setEnabled(b.id, true)

        #expect(configured == [a.id, b.id])
        #expect(h.store.usageStore(for: b.id)?.isAutoRefreshRunning == true)
        h.store.stopAll()
    }

    // MARK: - Other mutations

    @Test("rename trims, ignores empty names, persists and notifies the update hook")
    func renameAndHook() {
        let h = ProfileHarness()
        var updates: [AccountProfile] = []
        h.store.onProfileUpdated = { profile, _ in updates.append(profile) }

        h.store.rename(h.defaultID, to: "  Personal ")
        h.store.rename(h.defaultID, to: "   ")
        h.store.setColor(h.defaultID, hex: "#60A5FA")
        h.store.setRenewalPolicy(h.defaultID, .tokenEater)

        let profile = h.store.activeProfile
        #expect(profile.name == "Personal")
        #expect(profile.colorHex == "#60A5FA")
        #expect(profile.renewalPolicy == .tokenEater)
        #expect(updates.count == 3)
        #expect(h.persistence.profiles.first == profile)
        #expect(h.sharedFile.profileSnapshots.first?.name == "Personal")
        #expect(h.sharedFile.profileSnapshots.first?.colorHex == "#60A5FA")
    }

    @Test("move reorders and persists")
    func moveReorders() {
        let a = makeProfile(name: "A")
        let b = makeProfile(name: "B", dir: ProfileHarness.workDir)
        let h = ProfileHarness(profiles: [a, b], activeID: a.id)

        h.store.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)

        #expect(h.store.profiles == [b, a])
        #expect(h.persistence.profiles == [b, a])
        #expect(h.store.activeProfileID == a.id)
    }

    // MARK: - bootstrap / lifecycle

    @Test("bootstrap configures, reloads and starts every enabled store with a staggered delay")
    func bootstrapStaggers() async throws {
        let a = makeProfile(name: "A")
        let b = makeProfile(name: "B", dir: ProfileHarness.workDir)
        let c = makeProfile(name: "C", source: .managed, enabled: false)
        let h = ProfileHarness(profiles: [a, b, c], activeID: a.id)
        var configured: [UUID] = []

        h.store.bootstrap(configure: { configured.append($0.profileID!) }, thresholds: .default)

        #expect(configured == [a.id, b.id])
        let storeA = h.store.usageStore(for: a.id)!
        let storeB = h.store.usageStore(for: b.id)!
        let storeC = h.store.usageStore(for: c.id)!
        #expect(storeA.autoRefreshInitialDelay == 0)
        #expect(storeB.autoRefreshInitialDelay == ProfileStore.bootstrapStagger)
        #expect(storeA.isAutoRefreshRunning && storeB.isAutoRefreshRunning)
        #expect(storeC.isAutoRefreshRunning == false)
        #expect(Set(h.bag.factoryCalls) == Set([a.id, b.id, c.id]))

        // reloadConfig kicks the forced first refresh + permission request.
        try await Task.sleep(for: .milliseconds(150))
        #expect(h.bag.repos[a.id]?.refreshCallCount == 1)
        #expect(h.bag.repos[b.id]?.refreshCallCount == 1)
        #expect(h.bag.repos[c.id]?.refreshCallCount == 0)
        #expect(h.bag.notifs[a.id]?.permissionRequested == true)
        #expect(h.bag.repos[a.id]?.lastIsActiveProfile == true)
        #expect(h.bag.repos[b.id]?.lastIsActiveProfile == false)
        #expect(h.store.credentialStates[a.id] != nil)

        h.store.stopAll()
        #expect(storeA.isAutoRefreshRunning == false)
        #expect(storeB.isAutoRefreshRunning == false)
    }

    @Test("a profile added after bootstrap is configured and started")
    func addAfterBootstrapStarts() async throws {
        let h = ProfileHarness()
        var configured: [UUID] = []
        h.store.bootstrap(configure: { configured.append($0.profileID!) }, thresholds: .default)
        h.credentialStore.stub(configDir: ProfileHarness.workDir, credentials: creds())
        h.identity.stubbedProfile = identityResponse(uuid: "acc-work")

        let profile = try await h.store.addLinkedProfile(name: "Work", configDir: ProfileHarness.workDir)

        #expect(configured.last == profile.id)
        #expect(h.store.usageStore(for: profile.id)?.isAutoRefreshRunning == true)
        try await Task.sleep(for: .milliseconds(150))
        #expect(h.bag.repos[profile.id]?.refreshCallCount == 1)
        h.store.stopAll()
    }

    @Test("refreshAll refreshes every enabled store; handleTokenChange only touches linked ones")
    func refreshAllAndTokenChange() async throws {
        let a = makeProfile(name: "A")
        let b = makeProfile(name: "B", source: .managed)
        let c = makeProfile(name: "C", dir: ProfileHarness.workDir, enabled: false)
        let h = ProfileHarness(profiles: [a, b, c], activeID: a.id)
        for profile in [a, b, c] { _ = h.store.usageStore(for: profile.id) }

        await h.store.refreshAll(force: true)
        #expect(h.bag.repos[a.id]?.refreshCallCount == 1)
        #expect(h.bag.repos[b.id]?.refreshCallCount == 1)
        #expect(h.bag.repos[c.id]?.refreshCallCount == 0)

        h.store.handleTokenChange()
        #expect(h.bag.providers[a.id]?.invalidateCallCount == 1)
        #expect(h.bag.providers[b.id]?.invalidateCallCount == 0)
        #expect(h.bag.providers[c.id]?.invalidateCallCount == 0)
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.bag.repos[a.id]?.refreshCallCount == 2)
        #expect(h.bag.repos[b.id]?.refreshCallCount == 1)
    }

    @Test("refreshIfStaleAll only refreshes stale stores")
    func refreshIfStaleAll() async {
        let a = makeProfile(name: "A")
        let b = makeProfile(name: "B", dir: ProfileHarness.workDir)
        let h = ProfileHarness(profiles: [a, b], activeID: a.id)
        let storeA = h.store.usageStore(for: a.id)!
        _ = h.store.usageStore(for: b.id)
        await storeA.refresh()
        #expect(h.bag.repos[a.id]?.refreshCallCount == 1)

        await h.store.refreshIfStaleAll()

        #expect(h.bag.repos[a.id]?.refreshCallCount == 1)
        #expect(h.bag.repos[b.id]?.refreshCallCount == 1)
    }

    // MARK: - Relays

    @Test("a child store's changes are relayed as the profile store's objectWillChange")
    func childObjectWillChangeRelayed() {
        let h = ProfileHarness()
        var count = 0
        let subscription = h.store.objectWillChange.sink { _ in count += 1 }
        let store = h.store.activeUsageStore
        #expect(count == 0)

        store.fiveHourPct = 12

        #expect(count == 1)
        subscription.cancel()
    }

    @Test("credentialStates mirrors each store's state, including refreshes the store runs on its own")
    func credentialStatesMirrored() async {
        let a = makeProfile(name: "A")
        let b = makeProfile(name: "B", dir: ProfileHarness.workDir)
        let h = ProfileHarness(profiles: [a, b], activeID: a.id)
        let storeA = h.store.usageStore(for: a.id)!
        _ = h.store.usageStore(for: b.id)
        #expect(h.store.credentialStates[a.id] == nil)
        #expect(h.store.credentialState(for: a.id) == .unknown)

        // The auto-refresh loop calls refresh on the store directly.
        h.bag.providers[a.id]?.readiness = .awaitingClaudeCode
        h.bag.providers[a.id]?._credentialState = .awaitingClaudeCode
        await storeA.refresh(force: true)
        #expect(h.store.credentialStates[a.id] == .awaitingClaudeCode)
        #expect(h.store.credentialState(for: a.id) == .awaitingClaudeCode)

        h.bag.providers[a.id]?.readiness = .ready
        h.bag.providers[a.id]?._credentialState = .ok(expiresAt: nil)
        h.bag.providers[b.id]?._credentialState = .reauthRequired(reason: "invalid_grant")
        h.bag.providers[b.id]?.readiness = .reauthRequired
        await h.store.refreshAll(force: true)
        #expect(h.store.credentialStates[a.id] == .ok(expiresAt: nil))
        #expect(h.store.credentialStates[b.id] == .reauthRequired(reason: "invalid_grant"))
    }

    @Test("the identity fetched by a store fills the profile (default profile joins duplicate detection)")
    func identityRelayFillsProfile() async {
        let h = ProfileHarness()
        let store = h.store.activeUsageStore
        h.bag.repos[h.defaultID]?.stubbedProfile = identityResponse(uuid: "acc-default", email: "me@example.com")

        await store.refreshProfile()

        let profile = h.store.activeProfile
        #expect(profile.accountUUID == "acc-default")
        #expect(profile.accountEmail == "me@example.com")
        #expect(profile.planTypeRaw == PlanType.pro.rawValue)
        #expect(h.persistence.profiles.first?.accountUUID == "acc-default")
        #expect(h.sharedFile.profileSnapshots.first?.planType == PlanType.pro.rawValue)

        // Capturing the same account is now recognised as a duplicate.
        h.credentialStore.stub(configDir: nil, credentials: creds())
        h.identity.stubbedProfile = identityResponse(uuid: "acc-default")
        await expectError(.duplicateAccount(existingName: ProfileStore.defaultProfileName)) {
            try await h.store.captureCurrentLogin(name: "Same")
        }
    }

    @Test("profilesBecameMultiple is posted exactly once, when the second profile appears")
    func profilesBecameMultipleOnce() async throws {
        let h = ProfileHarness()
        var count = 0
        let subscription = h.center.publisher(for: .profilesBecameMultiple).sink { _ in count += 1 }
        h.credentialStore.stub(configDir: ProfileHarness.workDir, credentials: creds())
        h.credentialStore.stub(configDir: "/Users/tester/.claude-other", credentials: creds("at-o"))
        h.credentialStore.stub(configDir: nil, credentials: creds("at-m", refresh: "rt-m"))

        h.identity.stubbedProfile = identityResponse(uuid: "acc-work")
        try await h.store.addLinkedProfile(name: "Work", configDir: ProfileHarness.workDir)
        #expect(count == 1)
        h.identity.stubbedProfile = identityResponse(uuid: "acc-other")
        try await h.store.addLinkedProfile(name: "Other", configDir: "/Users/tester/.claude-other")
        h.identity.stubbedProfile = identityResponse(uuid: "acc-managed")
        try await h.store.captureCurrentLogin(name: "Managed")

        #expect(count == 1)
        #expect(h.store.profiles.count == 4)
        subscription.cancel()
    }

    // MARK: - watchedCredentialFiles

    @Test("watchedCredentialFiles lists the legacy pair plus every linked dir, de-duplicated")
    func watchedCredentialFiles() {
        let a = makeProfile(name: "A")
        let b = makeProfile(name: "B", dir: "~/.claude-work")
        let c = makeProfile(name: "C", source: .managed)
        let d = makeProfile(name: "D", dir: "/Users/tester/.claude/")
        let h = ProfileHarness(profiles: [a, b, c, d], activeID: a.id)

        let files = h.store.watchedCredentialFiles.map { $0.directory + "/" + $0.filename }

        #expect(files == [
            "/Users/tester/Library/Application Support/Claude/config.json",
            "/Users/tester/.claude/.credentials.json",
            "/Users/tester/.claude-work/.credentials.json",
        ])
    }

    // MARK: - Errors

    @Test("clearError drops the last error")
    func clearError() {
        let h = ProfileHarness()
        #expect(throws: ProfileStoreError.cannotRemoveLast) { try h.store.remove(h.defaultID) }
        #expect(h.store.lastError != nil)
        h.store.clearError()
        #expect(h.store.lastError == nil)
    }
}
