import Foundation

/// Namespaces everything `NotificationService` persists or hands to the
/// notification center, so several account profiles can run their own
/// escalation state machines side by side (multi-profile plan, section 3.7).
///
/// - `profileID == nil` is the *legacy* scope: state keys and request
///   identifiers are exactly the pre-profile ones, so the migrated default
///   profile keeps every existing user's de-dupe state and pending reminders.
/// - With a profile id, every UserDefaults key and every request identifier
///   gets a `_<uuid>` suffix. One profile crossing a threshold therefore never
///   suppresses another's alert, and re-scheduling profile A's reset reminders
///   never cancels profile B's.
/// - `displayName` is read at fire time, not at construction: `ProfileStore`
///   returns the profile's name only while more than one profile exists, so a
///   single-profile user never sees a `[Name]` prefix, and a rename is picked
///   up without rebuilding the service.
///
/// Vendor-health notifications are deliberately outside this scope: an outage
/// is global, so `NotificationService.checkVendorHealth` ignores it.
struct NotificationScope: Sendable {
    /// Profile the notifications belong to. `nil` = legacy, unsuffixed keys and ids.
    let profileID: UUID?
    /// Name shown as a `[Name]` title prefix. `nil` or empty = no prefix.
    let displayName: @Sendable () -> String?

    /// Pre-profile behaviour: unsuffixed keys and ids, no title prefix.
    static let legacy = NotificationScope(profileID: nil, displayName: { nil })

    init(profileID: UUID?, displayName: @escaping @Sendable () -> String? = { nil }) {
        self.profileID = profileID
        self.displayName = displayName
    }

    /// `_<UUID>` in the same uppercase, hyphenated form `UsageStore` uses for
    /// its per-profile pacing-samples key, or empty for the legacy scope.
    private var suffix: String {
        profileID.map { "_" + $0.uuidString } ?? ""
    }

    /// UserDefaults key for a piece of de-dupe state (`lastLevel_fiveHour`, ...).
    func key(_ base: String) -> String {
        base + suffix
    }

    /// `UNNotificationRequest` identifier (`escalation_fiveHour`, `reminder_session`, ...).
    func requestID(_ base: String) -> String {
        base + suffix
    }

    /// `"[<name>] " + title` when a non-blank display name is available,
    /// otherwise the title unchanged.
    func prefixedTitle(_ title: String) -> String {
        guard let name = displayName()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return title }
        return "[\(name)] " + title
    }

    /// The only requests that can still be pending (calendar-triggered), so
    /// this is the set to cancel when rescheduling or removing a profile.
    var reminderRequestIDs: [String] {
        [requestID("reminder_session"), requestID("reminder_weekly")]
    }
}
