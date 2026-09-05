import Foundation

final class InMemoryProfileCredentialVault: ProfileCredentialVaultProtocol, @unchecked Sendable {
    var storage: [UUID: OAuthCredentials] = [:]
    var saveCallCount = 0
    var deleteCallCount = 0
    var saveError: Error?

    func load(profileID: UUID) -> OAuthCredentials? {
        storage[profileID]
    }

    func save(_ credentials: OAuthCredentials, profileID: UUID) throws {
        saveCallCount += 1
        if let saveError { throw saveError }
        storage[profileID] = credentials
    }

    func delete(profileID: UUID) {
        deleteCallCount += 1
        storage[profileID] = nil
    }
}
