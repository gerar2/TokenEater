import Foundation

protocol UsageRepositoryProtocol {
    func refreshUsage(token: String, proxyConfig: ProxyConfig?) async throws -> UsageResponse
    /// Multi-profile variant: writes the per-profile snapshot and, only when
    /// `isActiveProfile`, the legacy top-level snapshot older widgets read.
    func refreshUsage(token: String, proxyConfig: ProxyConfig?, isActiveProfile: Bool, credentialState: String?) async throws -> UsageResponse
    func fetchProfile(token: String, proxyConfig: ProxyConfig?) async throws -> ProfileResponse
    func testConnection(token: String, proxyConfig: ProxyConfig?) async throws -> UsageResponse
}

extension UsageRepositoryProtocol {
    func refreshUsage(token: String, proxyConfig: ProxyConfig?, isActiveProfile: Bool, credentialState: String?) async throws -> UsageResponse {
        try await refreshUsage(token: token, proxyConfig: proxyConfig)
    }
}
