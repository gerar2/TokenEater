import SwiftUI

/// Accounts (profiles) settings. Phase 0 placeholder: the full editor lands
/// with the settings-UI lane (see docs/multi-profile-plan.md §5.2).
struct AccountsSectionView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle(
                String(localized: "sidebar.accounts"),
                subtitle: String(localized: "sidebar.accounts.subtitle")
            )
            Spacer()
        }
        .padding(24)
    }
}
