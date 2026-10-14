import Testing
import Foundation

@Suite("UsageEntry")
struct UsageEntryTests {

    private func makeUsage(fiveHour: Double, fetchDate: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> CachedUsage {
        CachedUsage(
            usage: UsageResponse(fiveHour: UsageBucket(utilization: fiveHour, resetsAt: nil)),
            fetchDate: fetchDate
        )
    }

    @Test("profile fields default to nil so legacy entries render unchanged")
    func profileFieldsDefaultNil() {
        let entry = UsageEntry(date: Date(), usage: nil)
        #expect(entry.profileName == nil)
        #expect(entry.profileColorHex == nil)
        #expect(entry.isStale == false)
        #expect(entry.error == nil)
        #expect(UsageEntry.placeholder.profileName == nil)
        #expect(UsageEntry.placeholder.profileColorHex == nil)
        #expect(UsageEntry.unconfigured.profileName == nil)
        #expect(UsageEntry.unconfigured.usage == nil)
        #expect(UsageEntry.unconfigured.error != nil)
    }

    @Test("explicit profile fields are stored")
    func profileFieldsStored() {
        let entry = UsageEntry(date: Date(), usage: nil, profileName: "Work", profileColorHex: "#60A5FA")
        #expect(entry.profileName == "Work")
        #expect(entry.profileColorHex == "#60A5FA")
    }

    @Test("snapshot initializer copies usage, sync date and the profile tag")
    func fromSnapshot() {
        let now = Date(timeIntervalSince1970: 1_700_001_000)
        let sync = now.addingTimeInterval(-120)
        let snapshot = SharedProfileSnapshot(
            id: UUID(), name: "Personal", colorHex: "#32CE6A",
            cachedUsage: makeUsage(fiveHour: 37), lastSyncDate: sync, credentialState: "ok"
        )

        let entry = UsageEntry(snapshot: snapshot, date: now)
        #expect(entry.date == now)
        #expect(entry.usage?.fiveHour?.utilization == 37)
        #expect(entry.error == nil)
        #expect(entry.isStale == false)
        #expect(entry.lastSync == sync)
        #expect(entry.profileName == "Personal")
        #expect(entry.profileColorHex == "#32CE6A")
        #expect(entry.lastWeekDailyTotals == nil)
    }

    @Test("snapshot without usage yields the no-data error, still tagged with the profile")
    func fromSnapshotWithoutUsage() {
        let snapshot = SharedProfileSnapshot(id: UUID(), name: "Fresh", colorHex: "#A78BFA")
        let entry = UsageEntry(snapshot: snapshot)
        #expect(entry.usage == nil)
        #expect(entry.error != nil)
        #expect(entry.isStale)
        #expect(entry.lastSync == nil)
        #expect(entry.profileName == "Fresh")
        #expect(entry.profileColorHex == "#A78BFA")
    }

    @Test("snapshot initializer flags a sync older than the threshold as stale")
    func fromSnapshotStale() {
        let now = Date(timeIntervalSince1970: 1_700_002_000)
        let snapshot = SharedProfileSnapshot(
            id: UUID(), name: "Old", colorHex: "#F87171",
            cachedUsage: makeUsage(fiveHour: 5), lastSyncDate: now.addingTimeInterval(-(UsageEntry.staleThreshold + 1))
        )
        #expect(UsageEntry(snapshot: snapshot, date: now).isStale)
    }

    @Test("isStale: nil sync is stale, older than 15 min is stale, fresher is not")
    func staleComputation() {
        let now = Date(timeIntervalSince1970: 1_700_003_000)
        #expect(UsageEntry.staleThreshold == 900)
        #expect(UsageEntry.isStale(lastSync: nil, now: now))
        #expect(UsageEntry.isStale(lastSync: now.addingTimeInterval(-901), now: now))
        #expect(UsageEntry.isStale(lastSync: now.addingTimeInterval(-900), now: now) == false)
        #expect(UsageEntry.isStale(lastSync: now.addingTimeInterval(-10), now: now) == false)
        #expect(UsageEntry.isStale(lastSync: now, now: now) == false)
        // Custom threshold
        #expect(UsageEntry.isStale(lastSync: now.addingTimeInterval(-61), now: now, threshold: 60))
        #expect(UsageEntry.isStale(lastSync: now.addingTimeInterval(-59), now: now, threshold: 60) == false)
    }
}
