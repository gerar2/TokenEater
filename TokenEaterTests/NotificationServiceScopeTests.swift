import Testing
import Foundation
import UserNotifications

// MARK: - NotificationScope (pure value rules)

@Suite("NotificationScope")
struct NotificationScopeTests {

    @Test("legacy scope leaves keys, ids and titles untouched")
    func legacyIsIdentity() {
        let scope = NotificationScope.legacy
        #expect(scope.profileID == nil)
        #expect(scope.key("lastLevel_fiveHour") == "lastLevel_fiveHour")
        #expect(scope.requestID("escalation_fiveHour") == "escalation_fiveHour")
        #expect(scope.prefixedTitle("Session almost capped") == "Session almost capped")
        #expect(scope.reminderRequestIDs == ["reminder_session", "reminder_weekly"])
    }

    @Test("profile scope suffixes keys and ids with _<UUID>")
    func profileSuffix() {
        let id = UUID()
        let scope = NotificationScope(profileID: id)
        #expect(scope.key("lastLevel_fiveHour") == "lastLevel_fiveHour_\(id.uuidString)")
        #expect(scope.requestID("reminder_session") == "reminder_session_\(id.uuidString)")
        #expect(scope.reminderRequestIDs == [
            "reminder_session_\(id.uuidString)",
            "reminder_weekly_\(id.uuidString)"
        ])
    }

    @Test("title prefix only for a non-blank display name")
    func titlePrefix() {
        let id = UUID()
        #expect(NotificationScope(profileID: id, displayName: { "Work" }).prefixedTitle("T") == "[Work] T")
        #expect(NotificationScope(profileID: id, displayName: { "  Work  " }).prefixedTitle("T") == "[Work] T")
        #expect(NotificationScope(profileID: id, displayName: { nil }).prefixedTitle("T") == "T")
        #expect(NotificationScope(profileID: id, displayName: { "" }).prefixedTitle("T") == "T")
        #expect(NotificationScope(profileID: id, displayName: { "   " }).prefixedTitle("T") == "T")
    }
}

// MARK: - NotificationService with a scope

@Suite("NotificationService scope")
struct NotificationServiceScopeTests {

    /// Mutable name the `@Sendable` display-name closure reads, mimicking
    /// `ProfileStore` answering nil while there is one profile and the
    /// profile's (renamable) name once there are several.
    private final class NameBox: @unchecked Sendable {
        var name: String?
        init(_ name: String?) { self.name = name }
    }

    /// One center + one state store shared by every service built from it, so
    /// two profiles' services see exactly the storage they would share in the app.
    private struct Harness {
        let center = MockNotificationCenter()
        let state = MockNotificationStateStore()

        func service(_ scope: NotificationScope = .legacy) -> NotificationService {
            NotificationService(center: center, stateStore: state, scope: scope)
        }

        /// Every state key written so far, across the four state families.
        var stateKeys: Set<String> {
            Set(state.levels.keys)
                .union(state.pacings.keys)
                .union(state.resetsAts.keys)
                .union(state.tokenExpiredAts.keys)
        }
    }

    /// Only the 5h surface is tracked so the state-key set stays small and
    /// exact; everything scoped (pacing, extra, token, reminders) is on.
    private func toggles(master: Bool = true) -> NotificationToggles {
        NotificationToggles(
            masterEnabled: master,
            trackFiveHour: true, trackWeekly: false, trackSonnet: false, trackFable: false,
            sendRecovery: true, pacingHot: true, pacingWarning: true,
            resetReminderSession: true, resetReminderWeekly: true,
            resetReminderSessionOffsetMinutes: 15, resetReminderWeeklyOffsetMinutes: 60,
            extraCredits: true, tokenExpired: true,
            smartColorEnabled: false, smartColorProfile: .default,
            pacingMargin: 10, thresholds: .default,
            vendorDegraded: true, vendorRestored: true
        )
    }

    private func snap(_ pct: Int) -> MetricSnapshot {
        MetricSnapshot(pct: pct, resetsAt: Date().addingTimeInterval(3600), windowDuration: 5 * 3600)
    }

    private func extra(_ pct: Double) -> ExtraUsage {
        ExtraUsage(isEnabled: true, monthlyLimit: 100, usedCredits: pct, utilization: pct,
                   currency: "USD", disabledReason: nil)
    }

    private func evaluate(_ service: NotificationService, fiveHour pct: Int, pacing: PacingZone? = nil,
                          extraPct: Double? = nil, master: Bool = true) {
        service.evaluate(
            fiveHour: snap(pct), sevenDay: snap(0), sonnet: snap(0), fable: snap(0),
            sessionPacing: pacing, weeklyPacing: nil,
            extraUsage: extraPct.map(extra), toggles: toggles(master: master)
        )
    }

    private func scheduleReminders(_ service: NotificationService) {
        service.scheduleResetReminders(
            sessionResetsAt: Date().addingTimeInterval(2 * 3600),
            weeklyResetsAt: Date().addingTimeInterval(3 * 86_400),
            toggles: toggles()
        )
    }

    /// Drives every scoped path once: 5h escalation to red, hot pacing, extra
    /// credits leaving green, token expired, both reset reminders.
    private func fireEverything(_ service: NotificationService) {
        evaluate(service, fiveHour: 96, pacing: .hot, extraPct: 80)
        service.notifyTokenExpired(toggle: true)
        scheduleReminders(service)
    }

    /// Request identifiers `fireEverything` produces, in delivery order, and
    /// the state keys it writes, both in their legacy (unsuffixed) form.
    private static let baseIDs = [
        "escalation_fiveHour", "pacing_hot", "escalation_extra",
        "token_expired", "reminder_session", "reminder_weekly"
    ]
    private static let baseKeys: Set<String> = [
        "lastLevel_fiveHour", "lastResetsAt_fiveHour", "lastPacing_fiveHour",
        "lastLevel_extra", "lastTokenExpiredFiredAt"
    ]

    private func suffixed(_ base: String, _ id: UUID) -> String { base + "_" + id.uuidString }

    // MARK: Legacy scope

    @Test("default scope is legacy: unsuffixed keys, unsuffixed ids, no title prefix")
    func legacyScopeIsUnchanged() {
        let h = Harness()
        // No `scope:` argument on purpose: this is the constructor every
        // existing call site uses and it must keep today's behaviour.
        let service = NotificationService(center: h.center, stateStore: h.state)
        fireEverything(service)

        #expect(h.center.addedIDs == Self.baseIDs)
        #expect(h.stateKeys == Self.baseKeys)
        #expect(h.center.removedIDs == ["reminder_session", "reminder_weekly"])
        #expect(h.state.tokenExpiredAts[NotificationStateKeys.tokenExpiredFiredAt] != nil)
        #expect(h.center.addedRequests.allSatisfy { !$0.content.title.hasPrefix("[") })
    }

    @Test("legacy token-expired accessors and the keyed ones share one slot")
    func legacyTokenAccessorsForward() {
        let state = MockNotificationStateStore()
        let stamp = Date(timeIntervalSince1970: 1_000)
        state.setTokenExpiredFiredAt(stamp)
        #expect(state.tokenExpiredFiredAt(forKey: NotificationStateKeys.tokenExpiredFiredAt) == stamp)
        #expect(state.tokenExpiredFiredAt() == stamp)

        let suite = "NotificationServiceScopeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsNotificationStateStore(defaults: defaults)
        store.setTokenExpiredFiredAt(stamp)
        #expect(store.tokenExpiredFiredAt(forKey: "lastTokenExpiredFiredAt") == stamp)
        #expect(store.tokenExpiredFiredAt() == stamp)
    }

    // MARK: Profile scope

    @Test("profile scope suffixes every state key and request id with the profile id")
    func scopedServiceSuffixesKeysAndIDs() {
        let id = UUID()
        let h = Harness()
        fireEverything(h.service(NotificationScope(profileID: id)))

        #expect(h.center.addedIDs == Self.baseIDs.map { suffixed($0, id) })
        #expect(h.stateKeys == Set(Self.baseKeys.map { suffixed($0, id) }))
        #expect(h.center.removedIDs == ["reminder_session", "reminder_weekly"].map { suffixed($0, id) })
        // Nothing leaks into the legacy slots.
        #expect(h.stateKeys.isDisjoint(with: Self.baseKeys))
        #expect(!h.center.addedIDs.contains(where: { Self.baseIDs.contains($0) }))
    }

    @Test("titles are prefixed with [name] only when the scope provides a name")
    func titlesPrefixedOnlyWithName() {
        let id = UUID()
        let legacy = Harness(), unnamed = Harness(), named = Harness()
        fireEverything(legacy.service())
        fireEverything(unnamed.service(NotificationScope(profileID: id, displayName: { nil })))
        fireEverything(named.service(NotificationScope(profileID: id, displayName: { "Work" })))

        for base in Self.baseIDs {
            let reference = legacy.center.title(for: base)
            #expect(reference != nil, "no legacy title for \(base)")
            #expect(unnamed.center.title(for: suffixed(base, id)) == reference, "\(base) prefixed without a name")
            #expect(named.center.title(for: suffixed(base, id)) == reference.map { "[Work] " + $0 }, "\(base) not prefixed")
        }
        // Bodies are never touched by the scope.
        #expect(named.center.addedRequests.map(\.content.body) == legacy.center.addedRequests.map(\.content.body))
    }

    @Test("display name is read at fire time, so a rename or a second profile is picked up")
    func displayNameReadLazily() {
        let id = UUID()
        let box = NameBox(nil)
        let h = Harness()
        let service = h.service(NotificationScope(profileID: id, displayName: { box.name }))

        service.notifyTokenExpired(toggle: true)
        #expect(h.center.title(for: suffixed("token_expired", id))?.hasPrefix("[") == false)

        box.name = "Work"
        scheduleReminders(service)
        #expect(h.center.title(for: suffixed("reminder_session", id))?.hasPrefix("[Work] ") == true)
    }

    // MARK: Independence between two profiles

    @Test("two profiles keep independent escalation state")
    func escalationStateIsPerProfile() {
        let a = UUID(), b = UUID()
        let h = Harness()
        let serviceA = h.service(NotificationScope(profileID: a))
        let serviceB = h.service(NotificationScope(profileID: b))

        evaluate(serviceA, fiveHour: 96)
        #expect(h.center.addedIDs == [suffixed("escalation_fiveHour", a)])

        // B crossing the same threshold is a fresh transition for B, not a
        // duplicate of A's.
        evaluate(serviceB, fiveHour: 96)
        #expect(h.center.addedIDs.contains(suffixed("escalation_fiveHour", b)))

        // A is still de-duped by its own state.
        evaluate(serviceA, fiveHour: 97)
        #expect(h.center.addedIDs.filter { $0 == suffixed("escalation_fiveHour", a) }.count == 1)

        #expect(h.state.levels[suffixed("lastLevel_fiveHour", a)] == UsageLevel.red.rawValue)
        #expect(h.state.levels[suffixed("lastLevel_fiveHour", b)] == UsageLevel.red.rawValue)
        #expect(h.state.levels["lastLevel_fiveHour"] == nil)
    }

    @Test("profile A's reset reminders survive profile B rescheduling or muting")
    func remindersAreNotCancelledByAnotherProfile() {
        let a = UUID(), b = UUID()
        let h = Harness()
        let serviceA = h.service(NotificationScope(profileID: a))
        let serviceB = h.service(NotificationScope(profileID: b))
        let remindersA = [suffixed("reminder_session", a), suffixed("reminder_weekly", a)]
        let remindersB = [suffixed("reminder_session", b), suffixed("reminder_weekly", b)]

        scheduleReminders(serviceA)
        #expect(h.center.addedIDs == remindersA)
        #expect(h.center.removedIDs == remindersA)

        scheduleReminders(serviceB)
        #expect(h.center.removedIDs == remindersA + remindersB)

        // Master switch off on B drops only B's pending reminders.
        evaluate(serviceB, fiveHour: 0, master: false)
        #expect(h.center.removedIDs == remindersA + remindersB + remindersB)
        #expect(h.center.removedIDs.filter { remindersA.contains($0) }.count == remindersA.count)
    }

    @Test("token-expired de-dupe is per profile")
    func tokenExpiredDedupeIsPerProfile() {
        let a = UUID(), b = UUID()
        let h = Harness()
        let serviceA = h.service(NotificationScope(profileID: a))
        let serviceB = h.service(NotificationScope(profileID: b))

        serviceA.notifyTokenExpired(toggle: true)
        serviceA.notifyTokenExpired(toggle: true)
        serviceB.notifyTokenExpired(toggle: true)
        serviceA.notifyTokenExpired(toggle: true)

        #expect(h.center.addedIDs == [suffixed("token_expired", a), suffixed("token_expired", b)])
        #expect(h.state.tokenExpiredAts[suffixed("lastTokenExpiredFiredAt", a)] != nil)
        #expect(h.state.tokenExpiredAts[suffixed("lastTokenExpiredFiredAt", b)] != nil)
        #expect(h.state.tokenExpiredAts[NotificationStateKeys.tokenExpiredFiredAt] == nil)
    }

    @Test("cancelPendingReminders removes only this scope's reminder ids")
    func cancelPendingRemindersIsScoped() {
        let a = UUID()
        let h = Harness()
        h.service(NotificationScope(profileID: a)).cancelPendingReminders()
        #expect(h.center.removedIDs == [suffixed("reminder_session", a), suffixed("reminder_weekly", a)])

        h.service().cancelPendingReminders()
        #expect(h.center.removedIDs.suffix(2) == ["reminder_session", "reminder_weekly"])
        #expect(h.center.addedIDs.isEmpty)
    }

    // MARK: Vendor health stays global

    /// `checkVendorHealth` persists straight to `UserDefaults.standard`, like
    /// `VendorOutageNotificationTests`. Both run synchronously on the main
    /// actor so they can never interleave on that key.
    @Test("vendor-health notifications ignore the scope: unsuffixed id, unprefixed title")
    @MainActor
    func vendorHealthIsGlobal() {
        let key = "lastVendorHealth_claude"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let id = UUID()
        let h = Harness()
        let service = h.service(NotificationScope(profileID: id, displayName: { "Work" }))
        let outage = VendorStatus(
            vendor: .claude, health: .down, affectedComponents: [],
            activeIncidents: [], lastChecked: Date(), isStale: false,
            isMaintenanceOnly: false
        )
        service.checkVendorHealth(outage, toggles: toggles())

        #expect(h.center.addedIDs == ["vendor_outage_claude"])
        #expect(h.center.title(for: "vendor_outage_claude")?.hasPrefix("[") == false)
        #expect(!h.center.addedIDs.contains(where: { $0.contains(id.uuidString) }))
    }
}
