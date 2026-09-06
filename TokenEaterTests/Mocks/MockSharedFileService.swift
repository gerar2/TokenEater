import Foundation

final class MockSharedFileService: SharedFileServiceProtocol, @unchecked Sendable {
    var fileURL: URL { URL(fileURLWithPath: "/tmp/mock-shared.json") }

    var _cachedUsage: CachedUsage?
    var _lastSyncDate: Date?
    var _theme: ThemeColors = .default
    var _thresholds: UsageThresholds = .default
    var _smartColorEnabled: Bool = true
    var _smartColorProfile: SmartColorProfile = .default
    var _pacingSchedule: PacingSchedule = .rolling
    var _lastWeekDailyTotals: [Int]?
    var _lastWeekTotalsRefreshedAt: Date?
    var updateAfterSyncCallCount = 0
    var updateThemeCallCount = 0
    var updateSmartColorCallCount = 0
    var updateSmartColorProfileCallCount = 0
    var updatePacingScheduleCallCount = 0
    var updateLastWeekDailyTotalsCallCount = 0
    var _profileSnapshots: [SharedProfileSnapshot] = []
    var _activeProfileID: UUID?
    var updateProfileCatalogCallCount = 0
    var updateProfileUsageCallCount = 0
    var removeProfileCallCount = 0

    var isConfigured: Bool { _cachedUsage != nil }

    var cachedUsage: CachedUsage? { _cachedUsage }
    var lastSyncDate: Date? { _lastSyncDate }
    var theme: ThemeColors { _theme }
    var thresholds: UsageThresholds { _thresholds }
    var smartColorEnabled: Bool { _smartColorEnabled }
    var smartColorProfile: SmartColorProfile { _smartColorProfile }
    var pacingSchedule: PacingSchedule { _pacingSchedule }
    var lastWeekDailyTotals: [Int]? { _lastWeekDailyTotals }
    var lastWeekTotalsRefreshedAt: Date? { _lastWeekTotalsRefreshedAt }

    func updateAfterSync(usage: CachedUsage, syncDate: Date) {
        updateAfterSyncCallCount += 1
        _cachedUsage = usage
        _lastSyncDate = syncDate
    }

    func updateTheme(_ theme: ThemeColors, thresholds: UsageThresholds) {
        updateThemeCallCount += 1
        _theme = theme
        _thresholds = thresholds
    }

    func updateSmartColorEnabled(_ enabled: Bool) {
        updateSmartColorCallCount += 1
        _smartColorEnabled = enabled
    }

    func updateSmartColorProfile(_ profile: SmartColorProfile) {
        updateSmartColorProfileCallCount += 1
        _smartColorProfile = profile
    }

    func updatePacingSchedule(_ schedule: PacingSchedule) {
        updatePacingScheduleCallCount += 1
        _pacingSchedule = schedule
    }

    func updateLastWeekDailyTotals(_ totals: [Int], refreshedAt: Date) {
        updateLastWeekDailyTotalsCallCount += 1
        _lastWeekDailyTotals = totals
        _lastWeekTotalsRefreshedAt = refreshedAt
    }

    var profileSnapshots: [SharedProfileSnapshot] { _profileSnapshots }
    var activeProfileID: UUID? { _activeProfileID }

    func updateProfileCatalog(_ profiles: [SharedProfileSnapshot], activeProfileID: UUID?) {
        updateProfileCatalogCallCount += 1
        let existing = _profileSnapshots
        _profileSnapshots = profiles.map { incoming in
            var entry = incoming
            if let old = existing.first(where: { $0.id == incoming.id }) {
                if entry.cachedUsage == nil { entry.cachedUsage = old.cachedUsage }
                if entry.lastSyncDate == nil { entry.lastSyncDate = old.lastSyncDate }
                if entry.credentialState == nil { entry.credentialState = old.credentialState }
            }
            return entry
        }
        _activeProfileID = activeProfileID
    }

    func updateProfileUsage(profileID: UUID, usage: CachedUsage, syncDate: Date, credentialState: String?) {
        updateProfileUsageCallCount += 1
        if let index = _profileSnapshots.firstIndex(where: { $0.id == profileID }) {
            _profileSnapshots[index].cachedUsage = usage
            _profileSnapshots[index].lastSyncDate = syncDate
            _profileSnapshots[index].credentialState = credentialState
        } else {
            _profileSnapshots.append(SharedProfileSnapshot(
                id: profileID, name: "", colorHex: "",
                cachedUsage: usage, lastSyncDate: syncDate, credentialState: credentialState
            ))
        }
    }

    func removeProfile(id: UUID) {
        removeProfileCallCount += 1
        _profileSnapshots.removeAll { $0.id == id }
        if _activeProfileID == id { _activeProfileID = nil }
    }

    func invalidateCache() {}

    func clear() {
        _cachedUsage = nil
        _lastSyncDate = nil
    }
}
