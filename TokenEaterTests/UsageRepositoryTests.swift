import Testing
import Foundation

@Suite("UsageRepository")
struct UsageRepositoryTests {

    // MARK: - Helpers

    private func makeSUT() -> (
        repo: UsageRepository,
        api: MockAPIClient,
        sharedFile: MockSharedFileService
    ) {
        let api = MockAPIClient()
        let sharedFile = MockSharedFileService()
        let repo = UsageRepository(
            apiClient: api,
            sharedFileService: sharedFile
        )
        return (repo, api, sharedFile)
    }

    // MARK: - refreshUsage

    @Test("refreshUsage calls API and writes to shared file on success")
    func refreshUsageCallsAPIAndWritesToSharedFile() async throws {
        let (repo, api, sharedFile) = makeSUT()
        api.stubbedUsage = .fixture(fiveHourUtil: 42)

        let response = try await repo.refreshUsage(token: "tok-123", proxyConfig: nil)

        #expect(api.fetchCallCount == 1)
        #expect(sharedFile.updateAfterSyncCallCount == 1)
        #expect(response.fiveHour?.utilization == 42)
    }

    @Test("refreshUsage throws API errors through")
    func refreshUsageThrowsAPIErrors() async {
        let (repo, api, _) = makeSUT()
        api.stubbedError = APIError.invalidResponse(endpoint: "/api/oauth/usage")

        do {
            _ = try await repo.refreshUsage(token: "tok", proxyConfig: nil)
            Issue.record("Expected APIError.invalidResponse")
        } catch let error as APIError {
            guard case .invalidResponse = error else {
                Issue.record("Expected .invalidResponse, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected APIError, got \(error)")
        }
    }

    @Test("refreshUsage does not write to shared file on failure")
    func refreshUsageDoesNotWriteOnFailure() async {
        let (repo, api, sharedFile) = makeSUT()
        api.stubbedError = APIError.tokenExpired(endpoint: "/api/oauth/usage", statusCode: 401)

        _ = try? await repo.refreshUsage(token: "tok", proxyConfig: nil)

        #expect(sharedFile.updateAfterSyncCallCount == 0)
    }

    // MARK: - fetchProfile

    @Test("fetchProfile calls API and returns result")
    func fetchProfileReturnsResult() async throws {
        let (repo, api, _) = makeSUT()
        api.stubbedProfile = .fixture(fullName: "Alice")

        let profile = try await repo.fetchProfile(token: "tok", proxyConfig: nil)

        #expect(profile.account.fullName == "Alice")
    }

    @Test("fetchProfile throws API errors through")
    func fetchProfileThrowsAPIErrors() async {
        let (repo, api, _) = makeSUT()
        api.stubbedError = APIError.tokenExpired(endpoint: "/api/oauth/profile", statusCode: 401)

        do {
            _ = try await repo.fetchProfile(token: "tok", proxyConfig: nil)
            Issue.record("Expected error")
        } catch {
            // Expected
        }
    }

    // MARK: - testConnection

    @Test("testConnection calls API without writing to shared file")
    func testConnectionDoesNotWriteToSharedFile() async throws {
        let (repo, api, sharedFile) = makeSUT()
        api.stubbedUsage = .fixture(fiveHourUtil: 10)

        let response = try await repo.testConnection(token: "tok", proxyConfig: nil)

        #expect(response.fiveHour?.utilization == 10)
        #expect(sharedFile.updateAfterSyncCallCount == 0)
    }

    @Test("testConnection throws API errors through")
    func testConnectionThrowsAPIErrors() async {
        let (repo, api, _) = makeSUT()
        api.stubbedError = APIError.noToken

        do {
            _ = try await repo.testConnection(token: "tok", proxyConfig: nil)
            Issue.record("Expected error")
        } catch {
            // Expected
        }
    }

    // MARK: - Multi-profile writes (docs/multi-profile-plan.md §3.6)

    private func makeProfileSUT(profileID: UUID) -> (
        repo: UsageRepository,
        api: MockAPIClient,
        sharedFile: MockSharedFileService
    ) {
        let api = MockAPIClient()
        let sharedFile = MockSharedFileService()
        let repo = UsageRepository(apiClient: api, sharedFileService: sharedFile, profileID: profileID)
        return (repo, api, sharedFile)
    }

    @Test("an active profile writes its own snapshot and the legacy one")
    func activeProfileWritesBothSnapshots() async throws {
        let id = UUID()
        let (repo, api, sharedFile) = makeProfileSUT(profileID: id)
        api.stubbedUsage = .fixture(fiveHourUtil: 42)

        _ = try await repo.refreshUsage(token: "tok", proxyConfig: nil, isActiveProfile: true, credentialState: "ok")

        #expect(sharedFile.updateProfileUsageCallCount == 1)
        let snapshot = sharedFile.profileSnapshots.first { $0.id == id }
        #expect(snapshot?.cachedUsage?.usage.fiveHour?.utilization == 42)
        #expect(snapshot?.credentialState == "ok")
        #expect(snapshot?.lastSyncDate != nil)
        #expect(sharedFile.updateAfterSyncCallCount == 1)
        #expect(sharedFile.cachedUsage?.usage.fiveHour?.utilization == 42)
    }

    @Test("an inactive profile writes its own snapshot only")
    func inactiveProfileSkipsLegacySnapshot() async throws {
        let id = UUID()
        let (repo, api, sharedFile) = makeProfileSUT(profileID: id)
        api.stubbedUsage = .fixture(fiveHourUtil: 42)

        _ = try await repo.refreshUsage(token: "tok", proxyConfig: nil, isActiveProfile: false, credentialState: "awaiting")

        #expect(sharedFile.updateProfileUsageCallCount == 1)
        #expect(sharedFile.profileSnapshots.first { $0.id == id }?.credentialState == "awaiting")
        #expect(sharedFile.updateAfterSyncCallCount == 0)
        #expect(sharedFile.cachedUsage == nil)
    }

    @Test("the legacy two-argument call on a profile repository behaves as active")
    func legacyCallOnProfileRepository() async throws {
        let id = UUID()
        let (repo, _, sharedFile) = makeProfileSUT(profileID: id)

        _ = try await repo.refreshUsage(token: "tok", proxyConfig: nil)

        #expect(sharedFile.updateProfileUsageCallCount == 1)
        #expect(sharedFile.profileSnapshots.first?.id == id)
        #expect(sharedFile.profileSnapshots.first?.credentialState == nil)
        #expect(sharedFile.updateAfterSyncCallCount == 1)
    }

    @Test("a repository without a profile id never writes a per-profile snapshot")
    func legacyRepositoryWritesLegacyOnly() async throws {
        let (repo, _, sharedFile) = makeSUT()

        _ = try await repo.refreshUsage(token: "tok", proxyConfig: nil, isActiveProfile: true, credentialState: "ok")

        #expect(sharedFile.updateProfileUsageCallCount == 0)
        #expect(sharedFile.profileSnapshots.isEmpty)
        #expect(sharedFile.updateAfterSyncCallCount == 1)
    }

    @Test("a failed fetch writes neither snapshot")
    func failedFetchWritesNothing() async {
        let (repo, api, sharedFile) = makeProfileSUT(profileID: UUID())
        api.stubbedError = APIError.tokenExpired(endpoint: "/api/oauth/usage", statusCode: 401)

        _ = try? await repo.refreshUsage(token: "tok", proxyConfig: nil, isActiveProfile: true, credentialState: "ok")

        #expect(sharedFile.updateProfileUsageCallCount == 0)
        #expect(sharedFile.updateAfterSyncCallCount == 0)
    }
}
