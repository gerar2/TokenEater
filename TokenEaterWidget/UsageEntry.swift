import WidgetKit
import Foundation

struct UsageEntry: TimelineEntry {
    let date: Date
    let usage: UsageResponse?
    let error: String?
    let isStale: Bool
    let lastSync: Date?
    /// 7 daily token totals (oldest first). Only populated for the
    /// History Sparkline widget. Refreshed by the main app once a day.
    let lastWeekDailyTotals: [Int]?
    /// Profile the entry belongs to, for the header tag. nil for entries
    /// built by `StaticProvider` and for single-profile users, so a widget
    /// that never touched the profile feature renders exactly as before.
    let profileName: String?
    let profileColorHex: String?

    /// How old the last sync may be before the entry is flagged stale.
    /// 15 min: three missed 5-min timeline refreshes, not one hiccup.
    static let staleThreshold: TimeInterval = 900

    init(
        date: Date,
        usage: UsageResponse?,
        error: String? = nil,
        isStale: Bool = false,
        lastSync: Date? = nil,
        lastWeekDailyTotals: [Int]? = nil,
        profileName: String? = nil,
        profileColorHex: String? = nil
    ) {
        self.date = date
        self.usage = usage
        self.error = error
        self.isStale = isStale
        self.lastSync = lastSync
        self.lastWeekDailyTotals = lastWeekDailyTotals
        self.profileName = profileName
        self.profileColorHex = profileColorHex
    }

    /// Entry for a widget pinned to one profile: usage, sync date and header
    /// tag all come from that profile's `shared.json` snapshot. A snapshot
    /// with no usage yet (profile added but never refreshed) yields the same
    /// "no data" error the legacy path uses, still tagged with the profile.
    init(snapshot: SharedProfileSnapshot, date: Date = Date(), lastWeekDailyTotals: [Int]? = nil) {
        let usage = snapshot.cachedUsage?.usage
        self.init(
            date: date,
            usage: usage,
            error: usage == nil ? String(localized: "error.nodata") : nil,
            isStale: Self.isStale(lastSync: snapshot.lastSyncDate, now: date),
            lastSync: snapshot.lastSyncDate,
            lastWeekDailyTotals: lastWeekDailyTotals,
            profileName: snapshot.name,
            profileColorHex: snapshot.colorHex
        )
    }

    /// Single definition of "stale" for every provider: no sync date at all,
    /// or a sync older than `staleThreshold`.
    static func isStale(lastSync: Date?, now: Date = Date(), threshold: TimeInterval = staleThreshold) -> Bool {
        guard let lastSync else { return true }
        return now.timeIntervalSince(lastSync) > threshold
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func iso8601String(from date: Date) -> String {
        iso8601Formatter.string(from: date)
    }

    static var placeholder: UsageEntry {
        UsageEntry(
            date: Date(),
            usage: UsageResponse(
                fiveHour: UsageBucket(utilization: 35, resetsAt: iso8601String(from: Date().addingTimeInterval(3600))),
                sevenDay: UsageBucket(utilization: 52, resetsAt: iso8601String(from: Date().addingTimeInterval(86400 * 3))),
                sevenDaySonnet: UsageBucket(utilization: 12, resetsAt: iso8601String(from: Date().addingTimeInterval(86400 * 3)))
            ),
            lastWeekDailyTotals: [120_000, 180_000, 95_000, 240_000, 310_000, 150_000, 220_000]
        )
    }

    static var unconfigured: UsageEntry {
        UsageEntry(date: Date(), usage: nil, error: String(localized: "error.notoken"))
    }
}
