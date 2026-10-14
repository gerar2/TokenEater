import Foundation

final class InMemoryProfilePersistence: ProfilePersistenceProtocol {
    var profiles: [AccountProfile] = []
    var activeID: UUID?
    var saveProfilesCallCount = 0
    private var didStore = false

    init(profiles: [AccountProfile] = [], activeID: UUID? = nil) {
        self.profiles = profiles
        self.activeID = activeID
        self.didStore = !profiles.isEmpty
    }

    var hasStoredProfiles: Bool { didStore }

    func loadProfiles() -> [AccountProfile] { profiles }

    func saveProfiles(_ profiles: [AccountProfile]) {
        saveProfilesCallCount += 1
        self.profiles = profiles
        didStore = true
    }

    func loadActiveProfileID() -> UUID? { activeID }

    func saveActiveProfileID(_ id: UUID?) { activeID = id }
}
