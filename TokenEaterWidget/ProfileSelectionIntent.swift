import AppIntents
import Foundation
import WidgetKit

// =====================================================================
// MARK: - Profile selection (widget configuration)
//
// Lets a placed widget be pinned to one monitored account. The entity id
// is the profile's UUID string, so a widget survives renames / recolours:
// `ProfileEntityQuery.entities(for:)` re-resolves the current name and
// colour on every timeline request, and a removed profile resolves to
// nothing, which WidgetKit hands to the provider as a nil parameter
// (= follow the active profile, see `ProfileTimelineProvider`).
// =====================================================================

struct ProfileEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "widget.profile.param")
    static let defaultQuery = ProfileEntityQuery()

    let id: String
    let name: String
    let colorHex: String
    /// Disabled profiles stay selectable (their last snapshot still renders)
    /// but are listed after the enabled ones and flagged in the picker.
    let isEnabled: Bool

    init(id: String, name: String, colorHex: String, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.isEnabled = isEnabled
    }

    init(snapshot: SharedProfileSnapshot) {
        self.init(
            id: snapshot.id.uuidString,
            name: snapshot.name,
            colorHex: snapshot.colorHex,
            isEnabled: snapshot.isEnabled
        )
    }

    var displayRepresentation: DisplayRepresentation {
        // Interpolating keeps the name a runtime value; a plain literal would
        // be looked up as a localization key.
        DisplayRepresentation(
            title: "\(name)",
            subtitle: isEnabled ? nil : LocalizedStringResource("profile.state.disabled")
        )
    }
}

struct ProfileEntityQuery: EntityQuery {
    func entities(for identifiers: [ProfileEntity.ID]) async throws -> [ProfileEntity] {
        let all = Self.allEntities()
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    func suggestedEntities() async throws -> [ProfileEntity] {
        Self.allEntities()
    }

    /// Catalog from `shared.json`, enabled profiles first, each group in the
    /// user's own order. A fresh `SharedFileService` per call so the picker
    /// never shows a stale catalog from an earlier render of this process.
    static func allEntities() -> [ProfileEntity] {
        let snapshots = SharedFileService().profileSnapshots
        let enabled = snapshots.filter(\.isEnabled)
        let disabled = snapshots.filter { !$0.isEnabled }
        return (enabled + disabled).map(ProfileEntity.init(snapshot:))
    }
}

/// Configuration intent of the profile-pinnable widgets. `profile == nil`
/// (the default, and the state of every widget placed before this feature)
/// means "follow the active account".
struct SelectProfileIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "widget.profile.title"
    static var description = IntentDescription("widget.profile.description")

    @Parameter(title: "widget.profile.param", description: "widget.profile.follow")
    var profile: ProfileEntity?
}
