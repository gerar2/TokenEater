import Foundation

final class MockTerminalTokenStore: TerminalTokenStoreProtocol, @unchecked Sendable {
    /// Stored tokens by profile id (what the Keychain would hold).
    var tokens: [UUID: String] = [:]
    var saveError: Error?
    var saveCallCount = 0
    var deleteCallCount = 0
    var lastSavedProfileName: String?

    func save(token: String, profileID: UUID, profileName: String) throws {
        saveCallCount += 1
        guard TerminalTokenFormat.isPlausible(token) else { throw TerminalTokenStoreError.implausibleToken }
        if let saveError { throw saveError }
        tokens[profileID] = token.trimmingCharacters(in: .whitespacesAndNewlines)
        lastSavedProfileName = profileName
    }

    func exists(profileID: UUID) -> Bool { tokens[profileID] != nil }

    func delete(profileID: UUID) {
        deleteCallCount += 1
        tokens[profileID] = nil
    }
}
