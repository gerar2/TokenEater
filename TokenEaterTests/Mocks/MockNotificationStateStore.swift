import Foundation

final class MockNotificationStateStore: NotificationStateStore {
    var levels: [String: Int] = [:]
    var pacings: [String: String] = [:]
    var resetsAts: [String: Date] = [:]
    /// Keyed like the real store: the legacy scope writes
    /// `NotificationStateKeys.tokenExpiredFiredAt`, profiles a suffixed key.
    var tokenExpiredAts: [String: Date] = [:]

    func lastLevel(forKey key: String) -> Int { levels[key] ?? 0 }
    func setLastLevel(_ value: Int, forKey key: String) { levels[key] = value }
    func lastPacing(forKey key: String) -> String? { pacings[key] }
    func setLastPacing(_ value: String, forKey key: String) { pacings[key] = value }
    func lastResetsAt(forKey key: String) -> Date? { resetsAts[key] }
    func setLastResetsAt(_ date: Date, forKey key: String) { resetsAts[key] = date }
    func tokenExpiredFiredAt(forKey key: String) -> Date? { tokenExpiredAts[key] }
    func setTokenExpiredFiredAt(_ date: Date, forKey key: String) { tokenExpiredAts[key] = date }
}
