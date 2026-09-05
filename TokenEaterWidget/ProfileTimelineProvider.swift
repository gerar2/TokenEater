import WidgetKit
import AppIntents
import Foundation
import os.log

private let logger = Logger(subsystem: "com.tokeneater.app.widget", category: "ProfileProvider")

/// Timeline provider for the widgets that can be pinned to one account
/// (`SelectProfileIntent`). Mirrors `StaticProvider.fetchEntry`, with one
/// extra resolution step:
///
/// - a resolvable `profile` parameter reads that profile's own snapshot in
///   `shared.json` (its usage, sync date, name and colour);
/// - a nil or unresolvable parameter (widget placed before this feature,
///   or its profile removed since) reads the legacy top-level `cachedUsage`,
///   which the app keeps mirroring from the active profile. That is what
///   keeps pre-existing widgets following the active account without being
///   re-added, and what an older widget build keeps reading.
struct ProfileTimelineProvider: AppIntentTimelineProvider {
    typealias Intent = SelectProfileIntent
    typealias Entry = UsageEntry

    private let sharedFile = SharedFileService()

    func placeholder(in context: Context) -> UsageEntry {
        .placeholder
    }

    func snapshot(for configuration: SelectProfileIntent, in context: Context) async -> UsageEntry {
        context.isPreview ? .placeholder : fetchEntry(for: configuration)
    }

    func timeline(for configuration: SelectProfileIntent, in context: Context) async -> Timeline<UsageEntry> {
        let entry = fetchEntry(for: configuration)
        // Same cadence as StaticProvider: WidgetKit calls back after 5 minutes.
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 5, to: Date()) ?? Date()
        return Timeline(entries: [entry], policy: .after(nextUpdate))
    }

    private func fetchEntry(for configuration: SelectProfileIntent) -> UsageEntry {
        sharedFile.invalidateCache()
        // The views read theme + pacing schedule via WidgetTheme's own shared
        // instance; invalidate it too so workweek / theme changes propagate.
        WidgetTheme.invalidate()

        let snapshots = sharedFile.profileSnapshots
        let pinnedID = configuration.profile.flatMap { UUID(uuidString: $0.id) }
        logger.info("fetchEntry: pinned=\(pinnedID?.uuidString ?? "none", privacy: .public), profiles=\(snapshots.count), isConfigured=\(self.sharedFile.isConfigured)")

        if let pinnedID, let snapshot = snapshots.first(where: { $0.id == pinnedID }) {
            return pinnedEntry(snapshot)
        }
        return activeEntry(snapshots: snapshots)
    }

    /// Pinned profile: its snapshot is the source of truth. "Not configured"
    /// only when neither the snapshot nor the legacy file carry any usage; a
    /// freshly added profile that has not refreshed yet gets the "no data"
    /// message tagged with its name rather than the onboarding hint.
    private func pinnedEntry(_ snapshot: SharedProfileSnapshot) -> UsageEntry {
        guard snapshot.cachedUsage != nil || sharedFile.isConfigured else {
            logger.error("Widget: not configured (pinned profile without usage)")
            return .unconfigured
        }
        return UsageEntry(snapshot: snapshot)
    }

    /// Legacy / active path, identical to `StaticProvider.fetchEntry`, plus
    /// the active profile's tag once the user monitors more than one account
    /// (a single profile keeps the pre-feature look).
    private func activeEntry(snapshots: [SharedProfileSnapshot]) -> UsageEntry {
        guard sharedFile.isConfigured else {
            logger.error("Widget: not configured")
            return .unconfigured
        }
        guard let cached = sharedFile.cachedUsage else {
            return UsageEntry(date: Date(), usage: nil, error: String(localized: "error.nodata"))
        }

        let lastSync = sharedFile.lastSyncDate
        let active = snapshots.count > 1
            ? snapshots.first { $0.id == sharedFile.activeProfileID }
            : nil
        return UsageEntry(
            date: Date(),
            usage: cached.usage,
            isStale: UsageEntry.isStale(lastSync: lastSync),
            lastSync: lastSync,
            lastWeekDailyTotals: sharedFile.lastWeekDailyTotals,
            profileName: active?.name,
            profileColorHex: active?.colorHex
        )
    }
}
