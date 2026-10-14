import Foundation

final class MockUsageRepository: UsageRepositoryProtocol {
    var stubbedUsage: UsageResponse?
    var stubbedProfile: ProfileResponse?
    var stubbedProfileError: Error?
    var stubbedError: Error?
    var stubbedTestError: Error?
    /// Thrown by the next `refreshUsage` only, then cleared. Simulates a 401
    /// that a retry with a renewed token recovers from.
    var failOnceError: Error?

    var refreshCallCount = 0
    var fetchProfileCallCount = 0
    var testConnectionCallCount = 0
    var lastToken: String?
    /// Multi-profile arguments of the last `refreshUsage` call.
    var lastIsActiveProfile: Bool?
    var lastCredentialState: String?
    var isActiveProfileHistory: [Bool] = []

    func refreshUsage(token: String, proxyConfig: ProxyConfig?) async throws -> UsageResponse {
        refreshCallCount += 1
        lastToken = token
        if let error = failOnceError {
            failOnceError = nil
            throw error
        }
        if let error = stubbedError { throw error }
        return stubbedUsage ?? UsageResponse()
    }

    func refreshUsage(token: String, proxyConfig: ProxyConfig?, isActiveProfile: Bool, credentialState: String?) async throws -> UsageResponse {
        lastIsActiveProfile = isActiveProfile
        lastCredentialState = credentialState
        isActiveProfileHistory.append(isActiveProfile)
        return try await refreshUsage(token: token, proxyConfig: proxyConfig)
    }

    func fetchProfile(token: String, proxyConfig: ProxyConfig?) async throws -> ProfileResponse {
        fetchProfileCallCount += 1
        lastToken = token
        if let error = stubbedProfileError { throw error }
        return stubbedProfile ?? .fixture()
    }

    func testConnection(token: String, proxyConfig: ProxyConfig?) async throws -> UsageResponse {
        testConnectionCallCount += 1
        lastToken = token
        if let error = stubbedTestError { throw error }
        return stubbedUsage ?? UsageResponse()
    }
}
