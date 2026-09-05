import SwiftUI

/// Re-injects the active profile's `UsageStore` into the environment, keyed
/// by the active profile id.
///
/// Every existing view reads `@EnvironmentObject var usageStore: UsageStore`
/// (dozens of call sites across the popover and the dashboard). Rather than
/// threading a profile through all of them, the hosting roots wrap their
/// content in this view: `ProfileStore` stays the single source of truth for
/// which store is active, and `.id(activeProfileID)` tears the subtree down
/// on a switch so per-view `@State` (flip faces, hover, countdown text) never
/// leaks from one profile to the next. The swap goes through view identity,
/// never through a binding, which keeps it clear of the AttributeGraph loop
/// traps listed in `AGENTS.md`.
struct ActiveProfileHost<Content: View>: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .environmentObject(profileStore.activeUsageStore)
            .id(profileStore.activeProfileID)
    }
}
