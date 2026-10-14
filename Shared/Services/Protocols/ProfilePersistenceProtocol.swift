import Foundation

/// Persists the profile catalog and the active profile id. Isolated behind a
/// protocol so `ProfileStore` is testable without touching real UserDefaults.
protocol ProfilePersistenceProtocol: AnyObject {
    func loadProfiles() -> [AccountProfile]
    func saveProfiles(_ profiles: [AccountProfile])
    func loadActiveProfileID() -> UUID?
    func saveActiveProfileID(_ id: UUID?)
    /// True when a catalog has been written at least once (drives migration).
    var hasStoredProfiles: Bool { get }
}

final class UserDefaultsProfilePersistence: ProfilePersistenceProtocol {
    static let profilesKey = "accountProfiles.v1"
    static let activeIDKey = "activeProfileID"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var hasStoredProfiles: Bool {
        defaults.data(forKey: Self.profilesKey) != nil
    }

    func loadProfiles() -> [AccountProfile] {
        guard let data = defaults.data(forKey: Self.profilesKey) else { return [] }
        // Lossy: one profile written by a newer build with an unknown source
        // kind is dropped, every valid sibling survives.
        let wrapped = (try? JSONDecoder().decode([Lossy<AccountProfile>].self, from: data)) ?? []
        return wrapped.compactMap(\.value)
    }

    func saveProfiles(_ profiles: [AccountProfile]) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data, forKey: Self.profilesKey)
    }

    func loadActiveProfileID() -> UUID? {
        defaults.string(forKey: Self.activeIDKey).flatMap(UUID.init(uuidString:))
    }

    func saveActiveProfileID(_ id: UUID?) {
        if let id {
            defaults.set(id.uuidString, forKey: Self.activeIDKey)
        } else {
            defaults.removeObject(forKey: Self.activeIDKey)
        }
    }
}
