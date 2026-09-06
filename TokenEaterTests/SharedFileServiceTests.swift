import Testing
import Foundation

@Suite("SharedFileService")
struct SharedFileServiceTests {

    // MARK: - Fixtures

    /// Fresh temp root per test so instances never see each other's files.
    /// `SharedFileService` creates the directory on first save, so the root
    /// deliberately does not exist yet when the test starts.
    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("te-shared-\(UUID().uuidString)")
    }

    private func makeUsage(fiveHour: Double, sevenDay: Double = 10, fetchDate: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> CachedUsage {
        CachedUsage(
            usage: UsageResponse(
                fiveHour: UsageBucket(utilization: fiveHour, resetsAt: nil),
                sevenDay: UsageBucket(utilization: sevenDay, resetsAt: nil)
            ),
            fetchDate: fetchDate
        )
    }

    private func sameInstant(_ a: Date?, _ b: Date?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return abs(a.timeIntervalSince(b)) < 0.001
    }

    /// Raw top-level keys of the JSON on disk, to assert what a write touched
    /// independently of the service's own decoding.
    private func rawJSON(at root: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent("shared.json"))
        let object = try JSONSerialization.jsonObject(with: data)
        return (object as? [String: Any]) ?? [:]
    }

    // MARK: - Root / legacy

    @Test("custom root places shared.json inside it and creates it lazily")
    func customRoot() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SharedFileService(rootDirectory: root)

        #expect(service.fileURL == root.appendingPathComponent("shared.json"))
        #expect(FileManager.default.fileExists(atPath: root.path) == false)
        #expect(service.isConfigured == false)
        #expect(service.cachedUsage == nil)

        service.updateAfterSync(usage: makeUsage(fiveHour: 5), syncDate: Date())
        #expect(FileManager.default.fileExists(atPath: service.fileURL.path))
    }

    @Test("legacy updateAfterSync / cachedUsage round-trip")
    func legacyRoundTrip() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SharedFileService(rootDirectory: root)
        let sync = Date(timeIntervalSince1970: 1_700_000_100)

        service.updateAfterSync(usage: makeUsage(fiveHour: 42, sevenDay: 61), syncDate: sync)

        let reread = SharedFileService(rootDirectory: root)
        #expect(reread.isConfigured)
        #expect(reread.cachedUsage?.usage.fiveHour?.utilization == 42)
        #expect(reread.cachedUsage?.usage.sevenDay?.utilization == 61)
        #expect(sameInstant(reread.lastSyncDate, sync))
        #expect(reread.profileSnapshots.isEmpty)
        #expect(reread.activeProfileID == nil)
    }

    // MARK: - Catalog

    @Test("updateProfileCatalog replaces catalog fields, keeps per-entry usage, drops unlisted, stores the active id")
    func catalogMerge() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SharedFileService(rootDirectory: root)
        let a = UUID(), b = UUID(), c = UUID()
        let sync = Date(timeIntervalSince1970: 1_700_000_200)

        service.updateProfileCatalog([
            SharedProfileSnapshot(id: a, name: "Personal", colorHex: "#32CE6A", planType: "pro"),
            SharedProfileSnapshot(id: b, name: "Work", colorHex: "#60A5FA"),
            SharedProfileSnapshot(id: c, name: "Old", colorHex: "#F87171"),
        ], activeProfileID: a)
        service.updateProfileUsage(profileID: a, usage: makeUsage(fiveHour: 33), syncDate: sync, credentialState: "ok")
        service.updateProfileUsage(profileID: b, usage: makeUsage(fiveHour: 77), syncDate: sync, credentialState: "awaiting")

        // Rename / recolour / disable / re-plan A and B, drop C, switch active to B.
        service.updateProfileCatalog([
            SharedProfileSnapshot(id: a, name: "Home", colorHex: "#A78BFA", isEnabled: false, planType: "max"),
            SharedProfileSnapshot(id: b, name: "Office", colorHex: "#FFB347"),
        ], activeProfileID: b)

        let reread = SharedFileService(rootDirectory: root)
        let snapshots = reread.profileSnapshots
        #expect(snapshots.map(\.id) == [a, b])
        #expect(reread.activeProfileID == b)

        let first = snapshots[0]
        #expect(first.name == "Home")
        #expect(first.colorHex == "#A78BFA")
        #expect(first.isEnabled == false)
        #expect(first.planType == "max")
        #expect(first.cachedUsage?.usage.fiveHour?.utilization == 33)
        #expect(sameInstant(first.lastSyncDate, sync))
        #expect(first.credentialState == "ok")

        let second = snapshots[1]
        #expect(second.name == "Office")
        #expect(second.colorHex == "#FFB347")
        #expect(second.isEnabled == true)
        #expect(second.planType == nil)
        #expect(second.cachedUsage?.usage.fiveHour?.utilization == 77)
        #expect(second.credentialState == "awaiting")
    }

    @Test("updateProfileCatalog with a nil active id clears the stored one")
    func catalogClearsActive() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SharedFileService(rootDirectory: root)
        let a = UUID()

        service.updateProfileCatalog([SharedProfileSnapshot(id: a, name: "A", colorHex: "#32CE6A")], activeProfileID: a)
        #expect(service.activeProfileID == a)
        service.updateProfileCatalog([SharedProfileSnapshot(id: a, name: "A", colorHex: "#32CE6A")], activeProfileID: nil)
        #expect(SharedFileService(rootDirectory: root).activeProfileID == nil)
    }

    // MARK: - Usage

    @Test("updateProfileUsage updates a known profile in place")
    func usageKnownProfile() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SharedFileService(rootDirectory: root)
        let a = UUID()
        let first = Date(timeIntervalSince1970: 1_700_000_300)
        let second = Date(timeIntervalSince1970: 1_700_000_400)

        service.updateProfileCatalog([SharedProfileSnapshot(id: a, name: "A", colorHex: "#32CE6A")], activeProfileID: a)
        service.updateProfileUsage(profileID: a, usage: makeUsage(fiveHour: 10), syncDate: first, credentialState: "ok")
        service.updateProfileUsage(profileID: a, usage: makeUsage(fiveHour: 20), syncDate: second, credentialState: "expiring")

        let snapshots = SharedFileService(rootDirectory: root).profileSnapshots
        #expect(snapshots.count == 1)
        #expect(snapshots[0].name == "A")
        #expect(snapshots[0].cachedUsage?.usage.fiveHour?.utilization == 20)
        #expect(sameInstant(snapshots[0].lastSyncDate, second))
        #expect(snapshots[0].credentialState == "expiring")
    }

    @Test("updateProfileUsage for an unknown id appends a bare entry the next catalog write fills in")
    func usageUnknownProfile() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SharedFileService(rootDirectory: root)
        let a = UUID()
        let sync = Date(timeIntervalSince1970: 1_700_000_500)

        service.updateProfileUsage(profileID: a, usage: makeUsage(fiveHour: 55), syncDate: sync, credentialState: nil)

        var snapshots = SharedFileService(rootDirectory: root).profileSnapshots
        #expect(snapshots.count == 1)
        #expect(snapshots[0].id == a)
        #expect(snapshots[0].name == "")
        #expect(snapshots[0].colorHex == "")
        #expect(snapshots[0].cachedUsage?.usage.fiveHour?.utilization == 55)
        #expect(snapshots[0].credentialState == nil)

        // The catalog write that follows (ProfileStore.syncCatalogToSharedFile)
        // supplies the name / colour and keeps the usage written first.
        service.updateProfileCatalog([SharedProfileSnapshot(id: a, name: "Late", colorHex: "#2DD4BF")], activeProfileID: a)
        snapshots = SharedFileService(rootDirectory: root).profileSnapshots
        #expect(snapshots[0].name == "Late")
        #expect(snapshots[0].cachedUsage?.usage.fiveHour?.utilization == 55)
        #expect(sameInstant(snapshots[0].lastSyncDate, sync))
    }

    // MARK: - Remove

    @Test("removeProfile drops the entry and clears a matching active id only")
    func removeProfile() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SharedFileService(rootDirectory: root)
        let a = UUID(), b = UUID()
        service.updateProfileCatalog([
            SharedProfileSnapshot(id: a, name: "A", colorHex: "#32CE6A"),
            SharedProfileSnapshot(id: b, name: "B", colorHex: "#60A5FA"),
        ], activeProfileID: a)

        service.removeProfile(id: b)
        var reread = SharedFileService(rootDirectory: root)
        #expect(reread.profileSnapshots.map(\.id) == [a])
        #expect(reread.activeProfileID == a)

        service.removeProfile(id: a)
        reread = SharedFileService(rootDirectory: root)
        #expect(reread.profileSnapshots.isEmpty)
        #expect(reread.activeProfileID == nil)
    }

    @Test("removeProfile on an unknown id or an empty catalog is a no-op")
    func removeUnknownProfile() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SharedFileService(rootDirectory: root)
        let a = UUID()

        service.removeProfile(id: UUID())
        #expect(service.profileSnapshots.isEmpty)

        service.updateProfileCatalog([SharedProfileSnapshot(id: a, name: "A", colorHex: "#32CE6A")], activeProfileID: a)
        service.removeProfile(id: UUID())
        let reread = SharedFileService(rootDirectory: root)
        #expect(reread.profileSnapshots.map(\.id) == [a])
        #expect(reread.activeProfileID == a)
    }

    // MARK: - Legacy isolation

    @Test("profile writes never touch the legacy top-level cachedUsage")
    func profileWritesLeaveLegacyAlone() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SharedFileService(rootDirectory: root)
        let a = UUID(), b = UUID()
        let legacySync = Date(timeIntervalSince1970: 1_700_000_600)

        service.updateAfterSync(usage: makeUsage(fiveHour: 11, sevenDay: 22), syncDate: legacySync)
        let legacyBefore = try rawJSON(at: root)["cachedUsage"] as? [String: Any]

        service.updateProfileCatalog([
            SharedProfileSnapshot(id: a, name: "A", colorHex: "#32CE6A"),
            SharedProfileSnapshot(id: b, name: "B", colorHex: "#60A5FA"),
        ], activeProfileID: b)
        service.updateProfileUsage(profileID: b, usage: makeUsage(fiveHour: 99, sevenDay: 98), syncDate: Date(), credentialState: "ok")
        service.removeProfile(id: a)

        let reread = SharedFileService(rootDirectory: root)
        #expect(reread.cachedUsage?.usage.fiveHour?.utilization == 11)
        #expect(reread.cachedUsage?.usage.sevenDay?.utilization == 22)
        #expect(sameInstant(reread.lastSyncDate, legacySync))
        #expect(reread.profileSnapshots.first?.cachedUsage?.usage.fiveHour?.utilization == 99)

        let legacyAfter = try rawJSON(at: root)["cachedUsage"] as? [String: Any]
        #expect(legacyBefore != nil)
        #expect(NSDictionary(dictionary: legacyBefore ?? [:]).isEqual(to: legacyAfter ?? [:]))
    }

    @Test("legacy updateAfterSync leaves the profile catalog untouched")
    func legacyWriteLeavesProfilesAlone() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SharedFileService(rootDirectory: root)
        let a = UUID()
        let profileSync = Date(timeIntervalSince1970: 1_700_000_700)

        service.updateProfileCatalog([SharedProfileSnapshot(id: a, name: "A", colorHex: "#32CE6A")], activeProfileID: a)
        service.updateProfileUsage(profileID: a, usage: makeUsage(fiveHour: 40), syncDate: profileSync, credentialState: "ok")
        service.updateAfterSync(usage: makeUsage(fiveHour: 41), syncDate: Date())

        let reread = SharedFileService(rootDirectory: root)
        #expect(reread.cachedUsage?.usage.fiveHour?.utilization == 41)
        #expect(reread.activeProfileID == a)
        #expect(reread.profileSnapshots.count == 1)
        #expect(reread.profileSnapshots[0].cachedUsage?.usage.fiveHour?.utilization == 40)
        #expect(sameInstant(reread.profileSnapshots[0].lastSyncDate, profileSync))
    }

    // MARK: - Schema compatibility

    @Test("a shared.json written by an older build (no profile keys) still decodes")
    func olderSchemaDecodes() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Dates are encoded as seconds since the reference date by JSONEncoder's
        // default strategy, which is what every shipped build wrote.
        let json = """
        {"cachedUsage":{"usage":{"five_hour":{"utilization":42.5},"seven_day":{"utilization":13}},"fetchDate":700000000},
         "lastSyncDate":700000100,"smartColorEnabled":false,"pacingWorkweekEnabled":true,"pacingActiveDays":[2,3,4]}
        """
        try Data(json.utf8).write(to: root.appendingPathComponent("shared.json"))

        let service = SharedFileService(rootDirectory: root)
        #expect(service.isConfigured)
        #expect(service.cachedUsage?.usage.fiveHour?.utilization == 42.5)
        #expect(service.cachedUsage?.usage.sevenDay?.utilization == 13)
        #expect(sameInstant(service.lastSyncDate, Date(timeIntervalSinceReferenceDate: 700_000_100)))
        #expect(service.smartColorEnabled == false)
        #expect(service.pacingSchedule.enabled == true)
        #expect(service.pacingSchedule.activeDays == [2, 3, 4])
        #expect(service.profileSnapshots.isEmpty)
        #expect(service.activeProfileID == nil)

        // Adding profiles to that file keeps every legacy field intact.
        let a = UUID()
        service.updateProfileCatalog([SharedProfileSnapshot(id: a, name: "A", colorHex: "#32CE6A")], activeProfileID: a)
        let reread = SharedFileService(rootDirectory: root)
        #expect(reread.cachedUsage?.usage.fiveHour?.utilization == 42.5)
        #expect(reread.smartColorEnabled == false)
        #expect(reread.pacingSchedule.activeDays == [2, 3, 4])
        #expect(reread.profileSnapshots.map(\.id) == [a])
    }

    @Test("a corrupt shared.json reads as empty and is overwritten by the next write")
    func corruptFileReadsEmpty() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: root.appendingPathComponent("shared.json"))

        let service = SharedFileService(rootDirectory: root)
        #expect(service.isConfigured == false)
        #expect(service.profileSnapshots.isEmpty)

        let a = UUID()
        service.updateProfileCatalog([SharedProfileSnapshot(id: a, name: "A", colorHex: "#32CE6A")], activeProfileID: a)
        #expect(SharedFileService(rootDirectory: root).profileSnapshots.map(\.id) == [a])
    }

    // MARK: - Cache / cross-instance

    @Test("invalidateCache makes another instance's writes visible on the same root")
    func crossInstanceVisibility() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = SharedFileService(rootDirectory: root)
        let reader = SharedFileService(rootDirectory: root)
        let a = UUID()

        // Prime the reader's in-memory cache on the empty file.
        #expect(reader.profileSnapshots.isEmpty)
        #expect(reader.cachedUsage == nil)

        writer.updateProfileCatalog([SharedProfileSnapshot(id: a, name: "A", colorHex: "#32CE6A")], activeProfileID: a)
        writer.updateAfterSync(usage: makeUsage(fiveHour: 64), syncDate: Date())

        // Cached read: still the primed (empty) view.
        #expect(reader.profileSnapshots.isEmpty)
        #expect(reader.cachedUsage == nil)

        reader.invalidateCache()
        #expect(reader.profileSnapshots.map(\.id) == [a])
        #expect(reader.activeProfileID == a)
        #expect(reader.cachedUsage?.usage.fiveHour?.utilization == 64)
    }

    @Test("update paths merge over the freshest on-disk state instead of a stale cache")
    func updatesMergeFresh() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let usageWriter = SharedFileService(rootDirectory: root)
        let catalogWriter = SharedFileService(rootDirectory: root)
        let a = UUID()

        // Both instances prime their caches on the empty file.
        #expect(usageWriter.cachedUsage == nil)
        #expect(catalogWriter.profileSnapshots.isEmpty)

        catalogWriter.updateProfileCatalog([SharedProfileSnapshot(id: a, name: "A", colorHex: "#32CE6A")], activeProfileID: a)
        usageWriter.updateAfterSync(usage: makeUsage(fiveHour: 12), syncDate: Date())
        catalogWriter.updateProfileUsage(profileID: a, usage: makeUsage(fiveHour: 13), syncDate: Date(), credentialState: "ok")

        let reread = SharedFileService(rootDirectory: root)
        #expect(reread.cachedUsage?.usage.fiveHour?.utilization == 12)
        #expect(reread.profileSnapshots.map(\.id) == [a])
        #expect(reread.profileSnapshots[0].cachedUsage?.usage.fiveHour?.utilization == 13)
    }

    @Test("clear wipes legacy and profile data alike")
    func clearWipesEverything() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SharedFileService(rootDirectory: root)
        let a = UUID()
        service.updateAfterSync(usage: makeUsage(fiveHour: 1), syncDate: Date())
        service.updateProfileCatalog([SharedProfileSnapshot(id: a, name: "A", colorHex: "#32CE6A")], activeProfileID: a)

        service.clear()

        let reread = SharedFileService(rootDirectory: root)
        #expect(reread.isConfigured == false)
        #expect(reread.profileSnapshots.isEmpty)
        #expect(reread.activeProfileID == nil)
    }
}
