import Testing
import Foundation

@MainActor
@Suite("Diagnostic Reporter")
struct DiagnosticReporterTests {

    private func makeStores(
        errorState: AppErrorState = .none,
        hasConfig: Bool = true,
        lastUpdate: Date? = nil,
        proxyEnabled: Bool = false
    ) -> (UsageStore, SettingsStore) {
        let store = UsageStore(
            repository: MockUsageRepository(),
            tokenProvider: MockTokenProvider(),
            sharedFileService: MockSharedFileService(),
            notificationService: MockNotificationService()
        )
        store.errorState = errorState
        store.hasConfig = hasConfig
        store.lastUpdate = lastUpdate
        if proxyEnabled {
            store.proxyConfig = ProxyConfig(enabled: true, host: "10.0.0.5", port: 1080)
        }
        let settings = SettingsStore(notificationService: MockNotificationService(), tokenProvider: MockTokenProvider())
        return (store, settings)
    }

    private func makeStoresWithError(
        apiError: APIError,
        lastUpdate: Date? = nil
    ) async -> (UsageStore, SettingsStore) {
        let repo = MockUsageRepository()
        repo.stubbedError = apiError
        let tokenProvider = MockTokenProvider()
        tokenProvider.token = "fake-token"
        let store = UsageStore(
            repository: repo,
            tokenProvider: tokenProvider,
            sharedFileService: MockSharedFileService(),
            notificationService: MockNotificationService()
        )
        store.lastUpdate = lastUpdate
        await store.refresh(force: true)
        let settings = SettingsStore(notificationService: MockNotificationService(), tokenProvider: MockTokenProvider())
        return (store, settings)
    }

    @Test("includes app version, build, and architecture")
    func includesAppMetadata() {
        let (store, settings) = makeStores()
        let report = DiagnosticReporter.makeReport(usageStore: store, settingsStore: settings)
        #expect(report.contains("**App**"))
        #expect(report.contains("Version:"))
        #expect(report.contains("Bundle:"))
        #expect(report.contains("Architecture:"))
    }

    @Test("includes macOS version")
    func includesSystemSection() {
        let (store, settings) = makeStores()
        let report = DiagnosticReporter.makeReport(usageStore: store, settingsStore: settings)
        #expect(report.contains("**System**"))
        #expect(report.contains("macOS:"))
    }

    @Test("rate-limited error captures HTTP 429 and raw Retry-After header")
    func rateLimitedRendersAllFields() async {
        let (store, settings) = await makeStoresWithError(
            apiError: .rateLimited(retryAfter: 0, retryAfterRaw: "0", endpoint: "/api/oauth/usage")
        )
        let report = DiagnosticReporter.makeReport(usageStore: store, settingsStore: settings)
        #expect(report.contains("Error state: rateLimited"))
        #expect(report.contains("HTTP status: 429"))
        #expect(report.contains("Retry-After header (raw): \"0\""))
        #expect(report.contains("Endpoint: /api/oauth/usage"))
    }

    @Test("token-expired error renders status code in API error block")
    func tokenExpiredRendersStatus() async {
        let (store, settings) = await makeStoresWithError(
            apiError: .tokenExpired(endpoint: "/api/oauth/usage", statusCode: 401)
        )
        let report = DiagnosticReporter.makeReport(usageStore: store, settingsStore: settings)
        #expect(report.contains("HTTP status: 401"))
        #expect(report.contains("Endpoint: /api/oauth/usage"))
    }

    @Test("network error renders underlying message")
    func networkErrorRendersUnderlying() async {
        let (store, settings) = await makeStoresWithError(
            apiError: .networkError(endpoint: "/api/oauth/usage", underlying: "The Internet connection appears to be offline.")
        )
        let report = DiagnosticReporter.makeReport(usageStore: store, settingsStore: settings)
        #expect(report.contains("Underlying error: The Internet connection appears to be offline."))
    }

    @Test("missing last API error renders 'None captured'")
    func noLastAPIErrorRendersGracefully() {
        let (store, settings) = makeStores()
        let report = DiagnosticReporter.makeReport(usageStore: store, settingsStore: settings)
        #expect(report.contains("None captured"))
    }

    @Test("nil optional fields render as a dash, not 'Optional(nil)'")
    func nilFieldsRenderAsDash() {
        let (store, settings) = makeStores()
        let report = DiagnosticReporter.makeReport(usageStore: store, settingsStore: settings)
        #expect(!report.contains("Optional("))
        #expect(report.contains("Last successful update: never"))
        #expect(report.contains("Rate limit tier: -"))
    }

    @Test("report never contains the OAuth bearer token")
    func neverLeaksToken() async {
        let (store, settings) = await makeStoresWithError(
            apiError: .rateLimited(retryAfter: 0, retryAfterRaw: "0", endpoint: "/api/oauth/usage")
        )
        let report = DiagnosticReporter.makeReport(usageStore: store, settingsStore: settings)
        #expect(!report.contains("fake-token"))
        #expect(!report.contains("Bearer "))
    }

    @Test("report never contains proxy host or port")
    func neverLeaksProxyCreds() {
        let (store, settings) = makeStores(proxyEnabled: true)
        let report = DiagnosticReporter.makeReport(usageStore: store, settingsStore: settings)
        #expect(!report.contains("10.0.0.5"))
        #expect(!report.contains("1080"))
        #expect(report.contains("Proxy configured: yes"))
    }

    // MARK: - Profiles section

    private static let fakeToken = "sk-ant-oat01-fake-token-ZZZ"

    /// A `ProfileStore` over in-memory persistence and mocks. Every store the
    /// factory hands out carries a token-like string and the given credential
    /// state so the tests can assert on redaction and on the state line.
    private func makeProfileStore(
        profiles: [AccountProfile],
        activeID: UUID,
        credentialState: ProfileCredentialState = .unknown
    ) -> (ProfileStore, SettingsStore) {
        let store = ProfileStore(
            persistence: InMemoryProfilePersistence(profiles: profiles, activeID: activeID),
            sharedFileService: MockSharedFileService(),
            identityClient: MockAPIClient(),
            realHome: "/Users/tester",
            usageStoreFactory: { profile in
                let tokenProvider = MockTokenProvider()
                tokenProvider.token = Self.fakeToken
                tokenProvider._credentialState = credentialState
                return UsageStore(
                    repository: MockUsageRepository(),
                    tokenProvider: tokenProvider,
                    sharedFileService: MockSharedFileService(),
                    notificationService: MockNotificationService(),
                    profileID: profile.id
                )
            }
        )
        let settings = SettingsStore(notificationService: MockNotificationService(), tokenProvider: MockTokenProvider())
        return (store, settings)
    }

    @Test("profile-store report keeps the legacy sections and adds Profiles")
    func profileReportKeepsLegacySections() {
        let personal = AccountProfile(name: "Personal", source: .claudeCode(configDir: nil))
        let (profileStore, settings) = makeProfileStore(profiles: [personal], activeID: personal.id)
        let report = DiagnosticReporter.makeReport(profileStore: profileStore, settingsStore: settings)
        #expect(report.contains("**App**"))
        #expect(report.contains("**System**"))
        #expect(report.contains("**State**"))
        #expect(report.contains("**Last API error**"))
        #expect(report.contains("**Profiles**"))
        #expect(report.contains("- Count: 1 (enabled: 1)"))
    }

    @Test("Profiles section lists every profile with source, policy and active flag")
    func profilesSectionListsEveryProfile() {
        let personal = AccountProfile(
            name: "Personal",
            source: .claudeCode(configDir: nil),
            renewalPolicy: .claudeCode
        )
        let work = AccountProfile(
            name: "Workplace",
            source: .claudeCode(configDir: "/Users/tester/.claude-work"),
            renewalPolicy: .tokenEater,
            accountEmail: "work@example.com"
        )
        let captured = AccountProfile(
            name: "Captured",
            source: .managed,
            accountEmail: "captured@example.com",
            accountUUID: "acc-uuid-1234"
        )
        let (profileStore, settings) = makeProfileStore(
            profiles: [personal, work, captured],
            activeID: work.id
        )
        // Materialise the stores the way bootstrap would, without starting loops.
        for profile in profileStore.profiles { _ = profileStore.usageStore(for: profile.id) }

        let report = DiagnosticReporter.makeReport(profileStore: profileStore, settingsStore: settings)

        #expect(report.contains("- Count: 3 (enabled: 3)"))
        #expect(report.contains("- Profile 1: P… (8 chars)"))
        #expect(report.contains("- Profile 2: W… (9 chars)"))
        #expect(report.contains("- Profile 3: C… (8 chars)"))
        #expect(report.contains("Source: claudeCode (dir: .claude)"))
        #expect(report.contains("Source: claudeCode (dir: .claude-work)"))
        #expect(report.contains("Source: managed (dir: -)"))
        #expect(report.contains("Renewal policy: claudeCode"))
        #expect(report.contains("Renewal policy: tokenEater"))
        #expect(report.contains("Credential state: unknown"))
        #expect(report.contains("Effective interval: 300s"))
        #expect(report.contains("Last successful update: never"))

        // Exactly one profile is flagged active (the second one).
        let activeLines = report.components(separatedBy: "\n").filter { $0.contains("Active: yes") }
        #expect(activeLines.count == 1)
        let profile2Range = report.range(of: "- Profile 2:")!
        let profile3Range = report.range(of: "- Profile 3:")!
        let profile2Block = report[profile2Range.lowerBound..<profile3Range.lowerBound]
        #expect(profile2Block.contains("Active: yes"))
    }

    @Test("Profiles section never leaks names, emails, account ids, paths or tokens")
    func profilesSectionRedactsSecrets() {
        let personal = AccountProfile(name: "Personal", source: .claudeCode(configDir: nil))
        let work = AccountProfile(
            name: "Workplace",
            source: .claudeCode(configDir: "/Users/tester/.claude-work"),
            accountEmail: "work@example.com",
            accountUUID: "acc-uuid-1234"
        )
        let (profileStore, settings) = makeProfileStore(profiles: [personal, work], activeID: personal.id)
        for profile in profileStore.profiles { _ = profileStore.usageStore(for: profile.id) }

        let report = DiagnosticReporter.makeReport(profileStore: profileStore, settingsStore: settings)

        #expect(!report.contains("Personal"))
        #expect(!report.contains("Workplace"))
        #expect(!report.contains("example.com"))
        #expect(!report.contains("acc-uuid-1234"))
        #expect(!report.contains("/Users/tester"))
        #expect(!report.contains(Self.fakeToken))
        #expect(!report.contains("fake-token"))
        #expect(!report.contains("Bearer "))
        #expect(!report.contains(personal.id.uuidString))
        #expect(!report.contains(work.id.uuidString))
    }

    @Test("Profiles section shows the expiry and the store's error state")
    func profilesSectionShowsExpiryAndErrorState() {
        let personal = AccountProfile(name: "Personal", source: .managed)
        let (profileStore, settings) = makeProfileStore(
            profiles: [personal],
            activeID: personal.id,
            credentialState: .ok(expiresAt: Date().addingTimeInterval(2 * 3600))
        )
        profileStore.activeUsageStore.errorState = .reauthRequired

        let report = DiagnosticReporter.makeReport(profileStore: profileStore, settingsStore: settings)

        #expect(report.contains("Credential state: ok (expires in"))
        #expect(report.contains("Renewal policy: tokenEater"))
        #expect(report.contains("Error state: reauthRequired"))
        #expect(!report.contains("Optional("))
    }

    @Test("a profile whose store never started is reported, not created")
    func profilesSectionReportsUnstartedStores() {
        let personal = AccountProfile(name: "Personal", source: .claudeCode(configDir: nil))
        let paused = AccountProfile(name: "Paused", source: .managed, isEnabled: false)
        let (profileStore, settings) = makeProfileStore(profiles: [personal, paused], activeID: personal.id)

        let report = DiagnosticReporter.makeReport(profileStore: profileStore, settingsStore: settings)

        #expect(report.contains("- Count: 2 (enabled: 1)"))
        #expect(report.contains("Enabled: no"))
        #expect(report.contains("Store: not started"))
        #expect(profileStore.usageStores[paused.id] == nil)
    }

    @Test("name redaction keeps only the initial and the length")
    func redactNameShape() {
        #expect(DiagnosticReporter.redactName("Personal") == "P… (8 chars)")
        #expect(DiagnosticReporter.redactName("  Élodie ") == "É… (6 chars)")
        #expect(DiagnosticReporter.redactName("") == "- (0 chars)")
        #expect(DiagnosticReporter.redactName("   ") == "- (0 chars)")
    }
}
