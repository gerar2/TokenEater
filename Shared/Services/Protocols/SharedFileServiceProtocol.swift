import Foundation

protocol SharedFileServiceProtocol: Sendable {
    var fileURL: URL { get }
    var isConfigured: Bool { get }
    var cachedUsage: CachedUsage? { get }
    var lastSyncDate: Date? { get }
    var theme: ThemeColors { get }
    var thresholds: UsageThresholds { get }
    var smartColorEnabled: Bool { get }
    var smartColorProfile: SmartColorProfile { get }
    var pacingSchedule: PacingSchedule { get }
    var lastWeekDailyTotals: [Int]? { get }
    var lastWeekTotalsRefreshedAt: Date? { get }
    /// Multi-profile catalog + per-profile usage (widget side). The legacy
    /// top-level `cachedUsage` keeps mirroring the ACTIVE profile.
    var profileSnapshots: [SharedProfileSnapshot] { get }
    var activeProfileID: UUID? { get }

    func invalidateCache()
    func updateAfterSync(usage: CachedUsage, syncDate: Date)
    func updateTheme(_ theme: ThemeColors, thresholds: UsageThresholds)
    func updateSmartColorEnabled(_ enabled: Bool)
    func updateSmartColorProfile(_ profile: SmartColorProfile)
    func updatePacingSchedule(_ schedule: PacingSchedule)
    func updateLastWeekDailyTotals(_ totals: [Int], refreshedAt: Date)
    /// Replaces catalog fields (name / colour / enabled / plan) for every
    /// profile, keeping each entry's cached usage. Drops entries not listed.
    func updateProfileCatalog(_ profiles: [SharedProfileSnapshot], activeProfileID: UUID?)
    func updateProfileUsage(profileID: UUID, usage: CachedUsage, syncDate: Date, credentialState: String?)
    func removeProfile(id: UUID)
    func clear()
}
