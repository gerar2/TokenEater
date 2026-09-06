import Foundation

final class UsageRepository: UsageRepositoryProtocol, @unchecked Sendable {
    private let apiClient: APIClientProtocol
    private let sharedFileService: SharedFileServiceProtocol
    /// Profile this repository writes for (nil = legacy single-account path).
    private let profileID: UUID?

    init(
        apiClient: APIClientProtocol = APIClient(),
        sharedFileService: SharedFileServiceProtocol = SharedFileService(),
        profileID: UUID? = nil
    ) {
        self.apiClient = apiClient
        self.sharedFileService = sharedFileService
        self.profileID = profileID
    }

    func refreshUsage(token: String, proxyConfig: ProxyConfig?) async throws -> UsageResponse {
        try await refreshUsage(token: token, proxyConfig: proxyConfig, isActiveProfile: true, credentialState: nil)
    }

    func refreshUsage(token: String, proxyConfig: ProxyConfig?, isActiveProfile: Bool, credentialState: String?) async throws -> UsageResponse {
        let usage = try await apiClient.fetchUsage(token: token, proxyConfig: proxyConfig)
        let now = Date()
        let cached = CachedUsage(usage: usage, fetchDate: now)
        if let profileID {
            sharedFileService.updateProfileUsage(
                profileID: profileID, usage: cached, syncDate: now, credentialState: credentialState
            )
        }
        if isActiveProfile {
            sharedFileService.updateAfterSync(usage: cached, syncDate: now)
        }
        return usage
    }

    func fetchProfile(token: String, proxyConfig: ProxyConfig?) async throws -> ProfileResponse {
        try await apiClient.fetchProfile(token: token, proxyConfig: proxyConfig)
    }

    func testConnection(token: String, proxyConfig: ProxyConfig?) async throws -> UsageResponse {
        try await apiClient.fetchUsage(token: token, proxyConfig: proxyConfig)
    }
}
