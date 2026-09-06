import Foundation

/// Applies the settings-derived configuration to a `UsageStore`, exactly as
/// `StatusBarController.bootstrapRefresh` did for the single store before
/// multi-profile support. Extracted so `ProfileStore.bootstrap(configure:)`
/// can apply it to every profile's store, and re-apply it when a profile is
/// added after launch or a setting changes.
@MainActor
enum UsageStoreConfigurator {
    /// - Parameters:
    ///   - settings: proxy, pacing margin / schedule, refresh interval.
    ///   - theme: accepted for call-site parity with `bootstrapRefresh`;
    ///     thresholds flow through `ProfileStore.bootstrap(configure:thresholds:)`
    ///     (see `makeConfigurator`), not through the store's stored properties.
    ///   - vendor: the vendor-status store shares the toggles provider and the
    ///     healthy poll interval; idempotent, so re-applying per store is safe.
    ///   - notifToggles: the notification-toggle bundle builder
    ///     (`StatusBarController.makeNotificationToggles`).
    static func apply(
        settings: SettingsStore,
        theme: ThemeStore,
        vendor: VendorStatusStore?,
        notifToggles: @escaping () -> NotificationToggles?,
        to store: UsageStore
    ) {
        store.proxyConfig = settings.proxyConfig
        store.pacingMargin = settings.pacingMargin
        store.pacingSchedule = settings.pacingSchedule
        store.refreshIntervalSeconds = TimeInterval(settings.refreshInterval)
        store.notifTogglesProvider = notifToggles
        if let vendor {
            vendor.notifTogglesProvider = notifToggles
            vendor.healthyPollInterval = TimeInterval(settings.statusPollInterval)
        }
    }

    /// The closure `ProfileStore.bootstrap(configure:thresholds:)` expects.
    /// Captures the stores weakly: the configurator outlives nothing.
    static func makeConfigurator(
        settings: SettingsStore,
        theme: ThemeStore,
        vendor: VendorStatusStore?,
        notifToggles: @escaping () -> NotificationToggles?
    ) -> (UsageStore) -> Void {
        { [weak settings, weak theme, weak vendor] store in
            guard let settings, let theme else { return }
            apply(settings: settings, theme: theme, vendor: vendor, notifToggles: notifToggles, to: store)
        }
    }
}
