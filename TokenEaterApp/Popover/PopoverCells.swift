import SwiftUI

// MARK: - Element cell dispatch
//
// One small view per element style, all sharing the same card language
// (radius 12, white 3% fill, hairline border) and the same color pipeline
// (`PopoverColors` -> `GaugeColorResolver`). The dispatcher below is the only
// place that knows which style maps to which cell.

struct PopoverElementCellView: View {
    @EnvironmentObject private var usageStore: UsageStore

    let element: PopoverElement

    var body: some View {
        switch element.style {
        case .gaugeRing:
            if let snapshot = PopoverMetricResolver.usageSnapshot(for: element.kind, usage: usageStore) {
                GaugeRingCell(snapshot: snapshot, width: element.effectiveWidth, showReset: element.options.showReset)
            }
        case .chip:
            if let snapshot = PopoverMetricResolver.usageSnapshot(for: element.kind, usage: usageStore) {
                ChipCell(snapshot: snapshot, width: element.effectiveWidth, showReset: element.options.showReset)
            }
        case .arc:
            if let snapshot = PopoverMetricResolver.usageSnapshot(for: element.kind, usage: usageStore) {
                ArcCell(snapshot: snapshot, content: element.options.content)
            }
        case .bigText:
            if let snapshot = PopoverMetricResolver.usageSnapshot(for: element.kind, usage: usageStore) {
                BigTextCell(snapshot: snapshot, width: element.effectiveWidth, content: element.options.content)
            }
        case .paceBar:
            if let pacing = PopoverMetricResolver.pacing(for: element.kind, usage: usageStore) {
                PopoverPacingRow(
                    label: paceLabel,
                    pacing: pacing,
                    // The workweek schedule adjusts every weekly bucket (weekly +
                    // per-model Fable); only the intraday session is never adjusted.
                    showWorkweekBadge: element.kind != .sessionPacing
                )
            } else {
                // Idle: the bucket exists (the cell only renders for available
                // kinds) but has no active window yet -> muted "-" placeholder.
                PaceIdleRow(label: paceLabel)
            }
        case .paceTile:
            if let pacing = PopoverMetricResolver.pacing(for: element.kind, usage: usageStore) {
                PaceTileCell(label: paceShortLabel, pacing: pacing)
            } else {
                PaceIdleCardCell(label: paceShortLabel, verticalPadding: 10)
            }
        case .paceText:
            if let pacing = PopoverMetricResolver.pacing(for: element.kind, usage: usageStore) {
                PaceTextCell(label: paceShortLabel, pacing: pacing)
            } else {
                PaceIdleCardCell(label: paceShortLabel, verticalPadding: 8)
            }
        case .utilityRow:
            switch element.kind {
            case .watchers: PopoverWatchersToggle()
            case .timestamp: PopoverTimestamp()
            case .profileSwitcher: PopoverProfileSwitcherCell()
            default: EmptyView()
            }
        case .actionButton:
            switch element.kind {
            case .openButton: PopoverOpenButton()
            case .quitButton: PopoverQuitButtonCell(width: element.effectiveWidth)
            case .refreshButton: PopoverRefreshButtonCell()
            default: EmptyView()
            }
        case .badge:
            if element.kind == .planBadge {
                PlanBadgeCell()
            }
        }
    }

    private var paceLabel: String {
        switch element.kind {
        case .weeklyPacing: return String(localized: "pacing.weekly.label")
        case .fablePacing: return String(localized: "pacing.fable.label")
        default: return String(localized: "pacing.session.label")
        }
    }

    private var paceShortLabel: String {
        switch element.kind {
        case .weeklyPacing: return String(localized: "pacing.weekly.label.short")
        case .fablePacing: return String(localized: "pacing.fable.label.short")
        default: return String(localized: "pacing.session.label.short")
        }
    }
}

// MARK: - Gauge ring (full = hero 100px, half = 70px, third = satellite 46px)

private struct GaugeRingCell: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @EnvironmentObject private var settingsStore: SettingsStore

    let snapshot: PopoverMetricResolver.UsageSnapshot
    let width: PopoverElementWidth
    let showReset: Bool

    var body: some View {
        let color = PopoverColors.gauge(
            pct: snapshot.pct, resetDate: snapshot.resetDate,
            windowDuration: snapshot.windowDuration,
            theme: themeStore, settings: settingsStore
        )
        let gradient = PopoverColors.gaugeGradient(
            pct: snapshot.pct, resetDate: snapshot.resetDate,
            windowDuration: snapshot.windowDuration,
            theme: themeStore, settings: settingsStore
        )

        VStack(spacing: width == .third ? 4 : 8) {
            ZStack {
                RingGauge(
                    percentage: snapshot.pct,
                    gradient: gradient,
                    size: ringSize,
                    glowColor: color,
                    glowRadius: glowRadius
                )
                if width == .third {
                    GlowText(
                        "\(snapshot.pct)%",
                        font: .system(size: 11, weight: .black, design: .rounded),
                        color: color,
                        glowRadius: 2
                    )
                } else {
                    VStack(spacing: 2) {
                        GlowText(
                            "\(snapshot.pct)%",
                            font: .system(size: valueFontSize, weight: .black, design: .rounded),
                            color: color,
                            glowRadius: width == .full ? 4 : 3
                        )
                        Text(snapshot.label)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
            if width == .third {
                Text(snapshot.label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            if showReset && !snapshot.resetText.isEmpty {
                Text(String(format: String(localized: "metric.reset"), snapshot.resetText))
                    .font(.system(size: width == .third ? 8 : 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
                    .lineLimit(1)
            }
        }
        .padding(.vertical, width == .full ? 8 : 2)
        // Fill the grid cell so the ring sits centered in its column. Without
        // this the VStack is only as wide as the ring and the layout pins it
        // to the cell's leading edge (visibly off-centre for half / third).
        .frame(maxWidth: .infinity)
    }

    private var ringSize: CGFloat {
        switch width {
        case .full: return 100
        case .half: return 70
        case .third: return 46
        }
    }

    private var valueFontSize: CGFloat {
        width == .full ? 24 : 16
    }

    private var glowRadius: CGFloat {
        switch width {
        case .full: return 6
        case .half: return 4
        case .third: return 3
        }
    }
}

// MARK: - Chip (card + mini trimmed ring; full / half only)

private struct ChipCell: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @EnvironmentObject private var settingsStore: SettingsStore

    let snapshot: PopoverMetricResolver.UsageSnapshot
    let width: PopoverElementWidth
    let showReset: Bool

    var body: some View {
        let color = PopoverColors.gauge(
            pct: snapshot.pct, resetDate: snapshot.resetDate,
            windowDuration: snapshot.windowDuration,
            theme: themeStore, settings: settingsStore
        )

        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.06), lineWidth: 4)
                    .frame(width: 38, height: 38)
                Circle()
                    .trim(from: 0, to: CGFloat(min(max(snapshot.pct, 0), 100)) / 100.0)
                    .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 38, height: 38)
                    .rotationEffect(.degrees(-90))
                    .dsGlow(color, radius: 3, opacity: 0.4)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(snapshot.label.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .tracking(0.5)
                    .lineLimit(1)
                Text("\(snapshot.pct)%")
                    .font(.system(size: 18, weight: .black, design: .rounded))
                    .foregroundStyle(color)
                if showReset && !snapshot.resetText.isEmpty {
                    Text(String(format: String(localized: "metric.reset"), snapshot.resetText))
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .popoverCard()
    }
}

// MARK: - Arc (open half-arc hero, ex-Focus)

private struct ArcCell: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @EnvironmentObject private var settingsStore: SettingsStore

    let snapshot: PopoverMetricResolver.UsageSnapshot
    let content: PopoverMetricContent

    var body: some View {
        ZStack {
            arc
            VStack(spacing: 4) {
                Text(displayValue)
                    .font(.system(size: 38, weight: .black, design: .rounded))
                    .foregroundStyle(color)
                    .dsGlow(color, radius: 10, opacity: 0.35)
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .tracking(1)
            }
        }
        .frame(height: 150)
    }

    private var displayValue: String {
        switch content {
        case .percent: return "\(snapshot.pct)%"
        case .resetCountdown: return snapshot.resetText.isEmpty ? "-" : snapshot.resetText
        }
    }

    private var label: String {
        switch content {
        case .percent: return snapshot.label
        case .resetCountdown: return String(format: String(localized: "popover.cell.resetLabel"), snapshot.label)
        }
    }

    private var color: Color {
        switch content {
        case .resetCountdown:
            return PopoverCellPalette.countdown
        case .percent:
            return PopoverColors.gauge(
                pct: snapshot.pct, resetDate: snapshot.resetDate,
                windowDuration: snapshot.windowDuration,
                theme: themeStore, settings: settingsStore
            )
        }
    }

    private var progress: Double {
        switch content {
        case .percent:
            return Double(min(max(snapshot.pct, 0), 100)) / 100.0
        case .resetCountdown:
            guard let date = snapshot.resetDate, snapshot.windowDuration > 0 else { return 0 }
            let remaining = max(date.timeIntervalSinceNow, 0)
            let elapsed = max(snapshot.windowDuration - remaining, 0)
            return min(elapsed / snapshot.windowDuration, 1)
        }
    }

    /// Open arc drawn from bottom-left to bottom-right of the cell.
    private var arc: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let strokeW: CGFloat = 8
            let inset: CGFloat = strokeW / 2 + 4
            let rect = CGRect(x: inset, y: inset, width: w - inset * 2, height: (h - inset) * 2)
            let path = Path { p in
                p.addArc(
                    center: CGPoint(x: rect.midX, y: rect.midY),
                    radius: rect.width / 2,
                    startAngle: .degrees(180),
                    endAngle: .degrees(360),
                    clockwise: false
                )
            }
            ZStack {
                path
                    .stroke(Color.white.opacity(0.06), style: StrokeStyle(lineWidth: strokeW, lineCap: .round))
                path
                    .trim(from: 0, to: progress)
                    .stroke(color, style: StrokeStyle(lineWidth: strokeW, lineCap: .round))
                    .dsGlow(color, radius: 8, opacity: 0.5)
            }
        }
    }
}

// MARK: - Big text (value + label card, ex-Focus satellite)

private struct BigTextCell: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @EnvironmentObject private var settingsStore: SettingsStore

    let snapshot: PopoverMetricResolver.UsageSnapshot
    let width: PopoverElementWidth
    let content: PopoverMetricContent

    var body: some View {
        VStack(spacing: 4) {
            Text(displayValue)
                .font(.system(size: valueFontSize, weight: .black, design: .rounded))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .tracking(0.6)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .popoverCard()
    }

    private var valueFontSize: CGFloat {
        switch width {
        case .full: return 24
        case .half: return 20
        case .third: return 16
        }
    }

    private var displayValue: String {
        switch content {
        case .percent: return "\(snapshot.pct)%"
        case .resetCountdown: return snapshot.resetText.isEmpty ? "-" : snapshot.resetText
        }
    }

    private var label: String {
        switch content {
        case .percent: return snapshot.label
        case .resetCountdown: return String(format: String(localized: "popover.cell.resetLabel"), snapshot.label)
        }
    }

    private var color: Color {
        switch content {
        case .resetCountdown:
            return PopoverCellPalette.countdown
        case .percent:
            return PopoverColors.gauge(
                pct: snapshot.pct, resetDate: snapshot.resetDate,
                windowDuration: snapshot.windowDuration,
                theme: themeStore, settings: settingsStore
            )
        }
    }
}

// MARK: - Pace idle (bucket present, no active window yet -> muted "-")

/// Idle paceBar: the label with a muted dash where the bar + delta would be.
/// No card, matching the active paceBar row's chrome-free layout.
private struct PaceIdleRow: View {
    let label: String

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
            Spacer(minLength: 0)
            Text("-")
                .font(.system(size: 12, weight: .black, design: .rounded))
                .foregroundStyle(.white.opacity(0.3))
                .frame(width: 48, alignment: .trailing)
        }
    }
}

/// Idle paceTile / paceText: the carded label with a muted dash instead of the
/// bar / delta. Shared by both carded styles (they differ only in padding).
private struct PaceIdleCardCell: View {
    let label: String
    let verticalPadding: CGFloat

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
            Spacer()
            Text("-")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.35))
        }
        .padding(.vertical, verticalPadding)
        .padding(.horizontal, 10)
        .popoverCard()
    }
}

// MARK: - Pace tile (carded bar + delta, ex-Compact)

private struct PaceTileCell: View {
    @EnvironmentObject private var themeStore: ThemeStore

    let label: String
    let pacing: PacingResult

    var body: some View {
        let color = PopoverColors.zone(pacing.zone, theme: themeStore)
        let sign = pacing.delta >= 0 ? "+" : ""
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                Text("\(sign)\(Int(pacing.delta))%")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
            }
            PacingBar(
                actual: pacing.actualUsage,
                expected: pacing.expectedUsage,
                zone: pacing.zone,
                gradient: PopoverColors.zoneGradient(pacing.zone, theme: themeStore),
                compact: true
            )
        }
        .padding(10)
        .popoverCard()
    }
}

// MARK: - Pace text (delta only, ex-Focus mini row)

private struct PaceTextCell: View {
    @EnvironmentObject private var themeStore: ThemeStore

    let label: String
    let pacing: PacingResult

    var body: some View {
        let color = PopoverColors.zone(pacing.zone, theme: themeStore)
        let sign = pacing.delta >= 0 ? "+" : ""
        HStack {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
            Spacer()
            Text("\(sign)\(Int(pacing.delta))%")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(color)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .popoverCard()
    }
}

// MARK: - Quit button (plain text full width for legacy continuity, capsule
// when sharing a row so it visually matches its neighbor)

private struct PopoverQuitButtonCell: View {
    let width: PopoverElementWidth

    var body: some View {
        if width == .full {
            PopoverQuitButton()
                .frame(maxWidth: .infinity)
        } else {
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "power")
                        .font(.system(size: 8))
                    Text(String(localized: "menubar.quit"))
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.55))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(.white.opacity(0.05))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.1), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Plan badge (ex-header chrome, v2 composable element)
//
// Deliberately keeps the pre-5.9 header look: a small content-hugging pill,
// pinned to the leading edge of its cell so a badge+refresh row reproduces
// the old header (badge far left, refresh far right).

private struct PlanBadgeCell: View {
    @EnvironmentObject private var usageStore: UsageStore

    var body: some View {
        Text(usageStore.planType.displayLabel)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(usageStore.planType.badgeColor.opacity(0.3))
            .clipShape(Capsule())
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Refresh button (ex-header chrome, v2 composable element)
//
// The exact pre-5.9 22x22 circular icon button, pinned to the trailing edge
// of its cell.

private struct PopoverRefreshButtonCell: View {
    @EnvironmentObject private var usageStore: UsageStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var refreshHovering = false

    var body: some View {
        Button {
            Task { await usageStore.refresh(force: true) }
        } label: {
            Group {
                if usageStore.isLoading {
                    ProgressView()
                        .scaleEffect(0.5)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(refreshHovering ? Color.blue : .white.opacity(0.55))
                }
            }
            .frame(width: 22, height: 22)
            .background(
                Circle()
                    .fill(refreshHovering ? Color.blue.opacity(0.18) : .white.opacity(0.04))
                    .overlay(
                        Circle().stroke(
                            refreshHovering ? Color.blue.opacity(0.55) : .white.opacity(0.08),
                            lineWidth: 1
                        )
                    )
            )
            .scaleEffect(refreshHovering && !reduceMotion ? 1.05 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(usageStore.isLoading)
        .help(String(localized: "contextmenu.refresh"))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { refreshHovering = hovering }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

// MARK: - Profile switcher (multi-profile utility row)
//
// One capsule chip per enabled profile: colour dot + name + that profile's
// live 5h percentage; the active chip is filled with the profile colour and a
// tap makes another profile active. The popover root is keyed by the active
// id (`ActiveProfileHost`), so the rest of the popover re-mounts on the new
// store by itself - this cell never reads the environment `UsageStore`.

struct PopoverProfileSwitcherCell: View {
    @EnvironmentObject private var profileStore: ProfileStore

    /// Above this many chips an equal-width row crushes the names (268 px
    /// usable); the row then scrolls horizontally with content-hugging chips.
    private static let equalWidthLimit = 3

    var body: some View {
        let profiles = profileStore.enabledProfiles
        // Nothing to switch to -> no row at all. The presence gate already
        // hides the element on single-profile catalogs; this covers "several
        // profiles, all but one paused".
        if profiles.count >= 2 {
            Group {
                if profiles.count <= Self.equalWidthLimit {
                    HStack(spacing: 6) {
                        ForEach(profiles) { profile in
                            chip(profile, hugging: false)
                        }
                    }
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(profiles) { profile in
                                chip(profile, hugging: true)
                            }
                        }
                    }
                }
            }
            .padding(6)
            .popoverCard()
            .help(String(localized: "popover.profileSwitcher.hint"))
        }
    }

    @ViewBuilder
    private func chip(_ profile: AccountProfile, hugging: Bool) -> some View {
        // `usageStore(for:)` creates the store lazily; the enabled profiles
        // already have one after bootstrap, so this is a dictionary lookup.
        if let usage = profileStore.usageStore(for: profile.id) {
            ProfileSwitcherChip(
                profile: profile,
                usage: usage,
                isActive: profile.id == profileStore.activeProfileID,
                hugging: hugging
            ) {
                withAnimation(DS.Motion.springSnap) {
                    profileStore.setActive(profile.id)
                }
            }
        }
    }
}

/// One chip. Holds its own `@ObservedObject` on the profile's store so a
/// non-active profile's percentage updates live without the parent
/// re-evaluating for every store's changes.
private struct ProfileSwitcherChip: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    let profile: AccountProfile
    @ObservedObject var usage: UsageStore
    let isActive: Bool
    /// Content-hugging (scrolling row) vs. sharing the row width equally.
    let hugging: Bool
    let onSelect: () -> Void

    var body: some View {
        let tint = Color(hex: profile.colorHex)
        Button(action: onSelect) {
            HStack(spacing: 5) {
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
                    .dsGlow(tint, radius: 3, opacity: isActive ? 0.6 : 0)
                Text(profile.name)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(isActive ? 0.95 : 0.6))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(valueText)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isActive ? tint : .white.opacity(0.4))
                    // The value never truncates; a long name gives way first.
                    .layoutPriority(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .frame(maxWidth: hugging ? nil : .infinity)
            .background(
                Capsule().fill(isActive ? tint.opacity(0.22) : Color.white.opacity(hovering ? 0.07 : 0.04))
            )
            .overlay(
                Capsule().stroke(
                    isActive ? tint.opacity(0.7) : Color.white.opacity(hovering ? 0.12 : 0.06),
                    lineWidth: 1
                )
            )
            .scaleEffect(hovering && !reduceMotion ? 1.03 : 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            withAnimation(DS.Motion.springSnap) { hovering = isHovering }
        }
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    /// "-" until the profile has fetched once, so a freshly added or paused
    /// account never reads as a real 0%.
    private var valueText: String {
        usage.lastUsage == nil ? "-" : "\(usage.fiveHourPct)%"
    }

    private var accessibilityText: String {
        if usage.lastUsage == nil {
            return String(format: String(localized: "popover.profileSwitcher.chip.noData"), profile.name)
        }
        return String(format: String(localized: "popover.profileSwitcher.chip"), profile.name, usage.fiveHourPct)
    }
}

// MARK: - Shared card language

private struct PopoverCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.05), lineWidth: 0.5)
                )
        )
    }
}

private extension View {
    /// The unified cell card: radius 12, white 3% fill, hairline border.
    func popoverCard() -> some View {
        modifier(PopoverCardModifier())
    }
}

enum PopoverCellPalette {
    /// Warm yellow used for reset countdown values (same as the old Focus hero).
    static let countdown = Color(red: 0.99, green: 0.90, blue: 0.54)
}
