import Foundation

/// Per-profile entry in `shared.json`, read by the sandboxed widget. Carries
/// the catalog fields (name / colour / enabled / plan) plus the profile's own
/// cached usage so a widget pinned to a profile renders without the app.
struct SharedProfileSnapshot: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var colorHex: String
    var isEnabled: Bool
    var planType: String?
    var cachedUsage: CachedUsage?
    var lastSyncDate: Date?
    /// `ProfileCredentialState.rawKind`, for a stale / expired badge.
    var credentialState: String?

    init(
        id: UUID,
        name: String,
        colorHex: String,
        isEnabled: Bool = true,
        planType: String? = nil,
        cachedUsage: CachedUsage? = nil,
        lastSyncDate: Date? = nil,
        credentialState: String? = nil
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.isEnabled = isEnabled
        self.planType = planType
        self.cachedUsage = cachedUsage
        self.lastSyncDate = lastSyncDate
        self.credentialState = credentialState
    }

    init(profile: AccountProfile) {
        self.init(
            id: profile.id,
            name: profile.name,
            colorHex: profile.colorHex,
            isEnabled: profile.isEnabled,
            planType: profile.planTypeRaw
        )
    }
}

extension CachedUsage: Equatable {
    static func == (lhs: CachedUsage, rhs: CachedUsage) -> Bool {
        lhs.fetchDate == rhs.fetchDate
            && lhs.usage.fiveHour?.utilization == rhs.usage.fiveHour?.utilization
            && lhs.usage.sevenDay?.utilization == rhs.usage.sevenDay?.utilization
            && lhs.usage.fiveHour?.resetsAt == rhs.usage.fiveHour?.resetsAt
            && lhs.usage.sevenDay?.resetsAt == rhs.usage.sevenDay?.resetsAt
    }
}
