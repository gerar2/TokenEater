import Foundation

/// UserDefaults keys that predate profile scoping. `NotificationService`
/// derives its per-profile keys from these bases (`NotificationScope.key`);
/// the unsuffixed forms are what existing users already have on disk.
enum NotificationStateKeys {
    static let tokenExpiredFiredAt = "lastTokenExpiredFiredAt"
}

/// Transition state for the notification escalation/recovery state machine.
/// Isolated behind a protocol so the level/pacing/token-expired logic is
/// testable without touching real UserDefaults.
protocol NotificationStateStore: AnyObject {
    func lastLevel(forKey key: String) -> Int
    func setLastLevel(_ value: Int, forKey key: String)
    func lastPacing(forKey key: String) -> String?
    func setLastPacing(_ value: String, forKey key: String)
    /// Last-seen reset boundary per surface. Lets the recovery ("new cycle")
    /// alert fire only on a real window reset, not a mid-window Smart Color
    /// level dip (#244).
    func lastResetsAt(forKey key: String) -> Date?
    func setLastResetsAt(_ date: Date, forKey key: String)
    /// Timestamp of the last "token expired" alert, keyed per scope so the
    /// one-per-hour de-dupe is independent for every profile.
    func tokenExpiredFiredAt(forKey key: String) -> Date?
    func setTokenExpiredFiredAt(_ date: Date, forKey key: String)
}

extension NotificationStateStore {
    /// Legacy, unscoped accessors. Kept as forwarding defaults so callers that
    /// predate profile scoping keep reading the slot the legacy scope writes.
    func tokenExpiredFiredAt() -> Date? {
        tokenExpiredFiredAt(forKey: NotificationStateKeys.tokenExpiredFiredAt)
    }

    func setTokenExpiredFiredAt(_ date: Date) {
        setTokenExpiredFiredAt(date, forKey: NotificationStateKeys.tokenExpiredFiredAt)
    }
}

final class UserDefaultsNotificationStateStore: NotificationStateStore {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func lastLevel(forKey key: String) -> Int { defaults.integer(forKey: key) }
    func setLastLevel(_ value: Int, forKey key: String) { defaults.set(value, forKey: key) }
    func lastPacing(forKey key: String) -> String? { defaults.string(forKey: key) }
    func setLastPacing(_ value: String, forKey key: String) { defaults.set(value, forKey: key) }
    func lastResetsAt(forKey key: String) -> Date? { defaults.object(forKey: key) as? Date }
    func setLastResetsAt(_ date: Date, forKey key: String) { defaults.set(date, forKey: key) }
    func tokenExpiredFiredAt(forKey key: String) -> Date? { defaults.object(forKey: key) as? Date }
    func setTokenExpiredFiredAt(_ date: Date, forKey key: String) { defaults.set(date, forKey: key) }
}
