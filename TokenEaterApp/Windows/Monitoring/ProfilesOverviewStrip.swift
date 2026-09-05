import SwiftUI

/// Side-by-side overview of every enabled profile, rendered by
/// `MonitoringView` under its header once a second profile exists.
///
/// The hero and tiles below it only ever show the *active* profile; this strip
/// is what makes the other accounts visible at the same time (§1.3 of the
/// multi-profile plan). Tapping a card makes that profile active, which swaps
/// the store `ActiveProfileHost` injects and re-renders the whole space.
struct ProfilesOverviewStrip: View {
    @EnvironmentObject private var profileStore: ProfileStore

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: "person.2.crop.square.stack.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DS.Palette.textTertiary)
                Text(String(localized: "dashboard.profiles.overview").uppercased())
                    .font(DS.Typography.micro)
                    .tracking(1.2)
                    .foregroundStyle(DS.Palette.textTertiary)
            }
            .padding(.horizontal, DS.Spacing.xs)

            HStack(spacing: DS.Spacing.sm) {
                ForEach(profileStore.enabledProfiles) { profile in
                    // Stores are created lazily by the profile store; after
                    // bootstrap every enabled profile already has one, so this
                    // is a dictionary lookup in practice.
                    if let usage = profileStore.usageStore(for: profile.id) {
                        ProfileOverviewCard(
                            profile: profile,
                            usage: usage,
                            isActive: profile.id == profileStore.activeProfileID,
                            onSelect: { profileStore.setActive(profile.id) }
                        )
                    }
                }
            }
        }
    }
}

/// One compact glass card per profile: colour dot + name, a 44 pt ring with
/// the 5h percentage, the 7d value and a state glyph. Observes its own
/// `UsageStore` so each card refreshes on its profile's schedule without
/// re-rendering the others.
struct ProfileOverviewCard: View {
    let profile: AccountProfile
    @ObservedObject var usage: UsageStore
    let isActive: Bool
    let onSelect: () -> Void

    @EnvironmentObject private var themeStore: ThemeStore
    @EnvironmentObject private var settingsStore: SettingsStore
    @State private var isHovered = false

    private static let sessionWindow: TimeInterval = 5 * 3600

    var body: some View {
        let accent = Color(hex: profile.colorHex)
        let pct = usage.fiveHourPct
        let resetDate = usage.lastUsage?.fiveHour?.resetsAtDate
        // Same resolver + Smart Color settings as `MetricTile`, so the ring
        // agrees with the hero for whichever profile is active.
        let mode = GaugeColorResolver.mode(
            smartColorEnabled: settingsStore.smartColorEnabled,
            windowDuration: Self.sessionWindow
        )
        let gaugeColor = GaugeColorResolver.color(
            mode: mode,
            utilization: pct,
            resetDate: resetDate,
            windowDuration: Self.sessionWindow,
            theme: themeStore.current,
            thresholds: themeStore.thresholds,
            pacingMargin: Double(settingsStore.pacingMargin),
            profile: settingsStore.smartColorProfile
        )
        let gaugeGradient = GaugeColorResolver.gradient(
            mode: mode,
            utilization: pct,
            resetDate: resetDate,
            windowDuration: Self.sessionWindow,
            theme: themeStore.current,
            thresholds: themeStore.thresholds,
            pacingMargin: Double(settingsStore.pacingMargin),
            profile: settingsStore.smartColorProfile,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        let glyph = stateGlyph

        return Button(action: onSelect) {
            HStack(spacing: DS.Spacing.sm) {
                ZStack {
                    RingGauge(
                        percentage: pct,
                        gradient: gaugeGradient,
                        size: 44,
                        glowColor: gaugeColor,
                        glowRadius: 4
                    )
                    Text("\(pct)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(gaugeColor)
                        .contentTransition(.numericText(value: Double(pct)))
                        .animation(DS.Motion.springLiquid, value: pct)
                }

                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    HStack(spacing: DS.Spacing.xs) {
                        Circle()
                            .fill(accent)
                            .frame(width: 6, height: 6)
                            .dsGlow(accent, radius: 3, opacity: 0.6)
                        Text(profile.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DS.Palette.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if isActive {
                            Text(String(localized: "dashboard.profiles.active").uppercased())
                                .font(.system(size: 8, weight: .bold))
                                .tracking(0.8)
                                .foregroundStyle(accent)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(accent.opacity(0.14))
                                )
                        }
                    }

                    HStack(spacing: DS.Spacing.xs) {
                        Text(String(format: String(localized: "dashboard.profiles.weekly"), usage.sevenDayPct))
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(DS.Palette.textSecondary)
                        if usage.isLoading {
                            ProgressView()
                                .controlSize(.mini)
                        } else if let glyph {
                            Image(systemName: glyph.symbol)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(glyph.tint)
                                .help(glyph.help)
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(DS.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dsGlass(radius: DS.Radius.cardLg)
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.cardLg)
                    .stroke(
                        isActive
                            ? accent.opacity(isHovered ? 0.85 : 0.65)
                            : (isHovered ? DS.Palette.glassBorderHi : .clear),
                        lineWidth: 1
                    )
            )
            .dsShadow(isHovered ? DS.Shadow.lift : DS.Shadow.subtle)
        }
        .buttonStyle(CardPressStyle(isHovered: isHovered, accent: accent, cornerRadius: DS.Radius.cardLg))
        .onHover { hovering in
            withAnimation(DS.Motion.springSnap) { isHovered = hovering }
        }
        .help(String(format: String(localized: "dashboard.profiles.select"), profile.name))
        .accessibilityLabel(profile.name)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private struct StateGlyph {
        let symbol: String
        let tint: Color
        let help: String
    }

    /// Priority order mirrors `PopoverErrorBanner`: a dead credential chain
    /// beats a rate limit, which beats the routine "waiting for Claude Code"
    /// state. No glyph when the profile is healthy.
    private var stateGlyph: StateGlyph? {
        if usage.errorState == .reauthRequired || isReauthRequired(usage.credentialState) {
            return StateGlyph(
                symbol: "exclamationmark.triangle.fill",
                tint: DS.Palette.semanticError,
                help: String(localized: "profile.state.reauth")
            )
        }
        if usage.errorState == .rateLimited {
            return StateGlyph(
                symbol: "icloud.slash",
                tint: DS.Palette.semanticWarning,
                help: String(localized: "dashboard.profiles.state.rateLimited")
            )
        }
        if usage.isAwaitingRefresh || usage.credentialState == .awaitingClaudeCode {
            return StateGlyph(
                symbol: "clock.arrow.circlepath",
                tint: DS.Palette.textTertiary,
                help: String(localized: "profile.state.awaiting")
            )
        }
        return nil
    }

    private func isReauthRequired(_ state: ProfileCredentialState) -> Bool {
        if case .reauthRequired = state { return true }
        return false
    }
}
