import SwiftUI

struct SettingsSectionView: View {
    /// The active profile's store (re-injected by `ActiveProfileHost`).
    @EnvironmentObject private var usageStore: UsageStore
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var updateStore: UpdateStore

    @State private var brewCopied = false
    /// Local mirror of the status poll interval for the slider (seconds).
    /// @State + .onChange instead of Binding(get:set:), per the SwiftUI rules.
    @State private var statusPollIntervalSeconds: Double

    init(initialStatusInterval: Int) {
        _statusPollIntervalSeconds = State(initialValue: Double(initialStatusInterval))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle(
                String(localized: "sidebar.settings"),
                subtitle: String(localized: "sidebar.settings.subtitle")
            )

            // Accounts summary. The old Connection card (status + Re-detect)
            // moved into Settings > Accounts, which owns per-profile state;
            // this card only orients the user and deep-links there.
            glassCard {
                VStack(alignment: .leading, spacing: 10) {
                    cardLabel(String(localized: "sidebar.accounts"))
                    HStack(spacing: 8) {
                        Circle()
                            .fill(activeStatusColor)
                            .frame(width: 8, height: 8)
                        Text(accountsSummary)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            NotificationCenter.default.post(
                                name: .navigateToSection,
                                object: nil,
                                userInfo: ["section": "settings.accounts"]
                            )
                        } label: {
                            HStack(spacing: 4) {
                                Text(String(localized: "settings.accounts.manage"))
                                    .font(.system(size: 12, weight: .medium))
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.blue)
                    }
                    if usageStore.errorState == .rateLimited {
                        VStack(alignment: .leading, spacing: 3) {
                            Label {
                                Text("error.banner.apiunavailable.settings")
                                    .font(.system(size: 11))
                            } icon: {
                                Image(systemName: "icloud.slash")
                                    .font(.system(size: 10))
                            }
                            .foregroundStyle(.orange.opacity(0.8))
                            if let last = usageStore.lastUpdate {
                                Text(String(format: String(localized: "error.banner.lastupdate"),
                                            last.formatted(.relative(presentation: .named))))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                        }
                    }
                }
            }

            // Terminal accounts: `cla` / `claw` (docs/terminal-accounts-plan.md §1.2).
            TerminalIntegrationCard(initialEnabled: profileStore.terminalIntegrationEnabled)

            // Update (placed right under Connection so the user spots a
            // pending version straight away).
            glassCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("TokenEater v\(updateStore.currentVersion)")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.5))
                        Spacer()
                        if case .checking = updateStore.updateState {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 16, height: 16)
                        } else if case .upToDate = updateStore.updateState {
                            Label(String(localized: "update.uptodate"), systemImage: "checkmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.green)
                        } else if let version = updateStore.updateState.availableVersion {
                            Button(String(localized: "update.available.badge \(version)")) {
                                updateStore.downloadUpdate()
                            }
                            .font(.system(size: 11, weight: .medium))
                            .buttonStyle(.plain)
                            .foregroundStyle(.orange)
                        } else {
                            Button(String(localized: "update.check")) {
                                updateStore.checkForUpdates()
                            }
                            .font(.system(size: 11))
                            .buttonStyle(.plain)
                            .foregroundStyle(.blue)
                        }
                    }

                    if updateStore.brewMigrationState == .detected {
                        brewMigrationBanner
                    }
                }
            }

            // General (Launch at login + replay onboarding)
            glassCard {
                VStack(alignment: .leading, spacing: 12) {
                    cardLabel(String(localized: "settings.general.title"))
                    darkToggle(String(localized: "settings.launchAtLogin"), isOn: $settingsStore.launchAtLoginEnabled)
                    Text(String(localized: "settings.launchAtLogin.hint"))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                        .fixedSize(horizontal: false, vertical: true)

                    darkToggle(String(localized: "settings.launchInBackground"), isOn: $settingsStore.display.launchInBackground)
                    Text(String(localized: "settings.launchInBackground.hint"))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                        .fixedSize(horizontal: false, vertical: true)

                    Divider().opacity(0.12)

                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(String(localized: "settings.general.replayOnboarding"))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white.opacity(0.85))
                            Text(String(localized: "settings.general.replayOnboarding.hint"))
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.4))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button {
                            settingsStore.hasCompletedOnboarding = false
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 11, weight: .semibold))
                                Text(String(localized: "settings.general.replayOnboarding.action"))
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.blue.opacity(0.18))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .stroke(Color.blue.opacity(0.4), lineWidth: 1)
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Proxy
            glassCard {
                VStack(alignment: .leading, spacing: 8) {
                    cardLabel(String(localized: "settings.tab.proxy"))
                    darkToggle(String(localized: "settings.proxy.toggle"), isOn: $settingsStore.proxyEnabled)
                    if settingsStore.proxyEnabled {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(String(localized: "settings.proxy.host"))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.white.opacity(0.4))
                                TextField("127.0.0.1", text: $settingsStore.proxyHost)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 12, design: .monospaced))
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(String(localized: "settings.proxy.port"))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.white.opacity(0.4))
                                TextField("1080", value: $settingsStore.proxyPort, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 12, design: .monospaced))
                                    .frame(width: 80)
                            }
                        }
                    }
                }
            }

            // Refresh interval
            glassCard {
                VStack(alignment: .leading, spacing: 8) {
                    cardLabel(String(localized: "settings.refresh.title"))
                    HStack {
                        Text(String(localized: "settings.refresh.interval"))
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.7))
                        Spacer()
                        Text(formatInterval(settingsStore.refreshInterval))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    TokenEaterSlider(
                        value: Binding(
                            get: { Double(settingsStore.refreshInterval) },
                            set: { settingsStore.refreshInterval = Int($0) }
                        ),
                        in: 180...900,
                        step: 60,
                        showsTicks: true
                    )
                    if settingsStore.refreshInterval < 300 {
                        Label {
                            Text(String(localized: "settings.refresh.warning"))
                                .font(.system(size: 10))
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9))
                        }
                        .foregroundStyle(.orange.opacity(0.8))
                    }
                }
            }

            // Service status (outage monitoring). Moved here from a dedicated
            // sidebar section: a full section for 3 controls was overkill, and
            // this matches the Proxy card pattern (toggle + conditional config).
            glassCard {
                VStack(alignment: .leading, spacing: 8) {
                    cardLabel(String(localized: "sidebar.serviceStatus"))
                    darkToggle(String(localized: "settings.status.master"), isOn: $settingsStore.outageMonitoringEnabled)
                    Text(String(localized: "sidebar.serviceStatus.subtitle"))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                        .fixedSize(horizontal: false, vertical: true)
                    if settingsStore.outageMonitoringEnabled {
                        HStack {
                            Text(String(localized: "settings.status.interval.label"))
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.7))
                            Spacer()
                            Text(formatInterval(Int(statusPollIntervalSeconds)))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.9))
                        }
                        TokenEaterSlider(
                            value: $statusPollIntervalSeconds,
                            in: 60...1800,
                            step: 60,
                            showsTicks: true
                        )
                        darkToggle(String(localized: "settings.status.badge"), isOn: $settingsStore.statusShowMenuBarBadge)
                    }
                }
            }

            // About
            glassCard {
                VStack(alignment: .leading, spacing: 12) {
                    cardLabel(String(localized: "settings.about.title"))
                    AboutLinkRow(
                        icon: "chevron.left.forwardslash.chevron.right",
                        title: String(localized: "settings.about.repository"),
                        subtitle: String(localized: "settings.about.repository.hint"),
                        url: URL(string: "https://github.com/AThevon/TokenEater")!
                    )
                    AboutLinkRow(
                        icon: "exclamationmark.bubble.fill",
                        title: String(localized: "settings.about.issues"),
                        subtitle: String(localized: "settings.about.issues.hint"),
                        url: URL(string: "https://github.com/AThevon/TokenEater/issues")!
                    )
                    AboutLinkRow(
                        icon: "tag.fill",
                        title: String(localized: "settings.about.releases"),
                        subtitle: String(localized: "settings.about.releases.hint"),
                        url: URL(string: "https://github.com/AThevon/TokenEater/releases")!
                    )
                }
            }

            Spacer()
        }
        .padding(24)
        .onAppear {
            Task { await settingsStore.refreshNotificationStatus() }
        }
        .onChange(of: statusPollIntervalSeconds) { _, secs in
            let v = Int(secs)
            if settingsStore.statusPollInterval != v { settingsStore.statusPollInterval = v }
        }
        .onChange(of: settingsStore.statusPollInterval) { _, v in
            if Int(statusPollIntervalSeconds) != v { statusPollIntervalSeconds = Double(v) }
        }
    }

    private var brewMigrationBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(String(localized: "update.brew.detected"), systemImage: "shippingbox.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.orange)
            Text(String(localized: "update.brew.hint"))
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.5))
            HStack(spacing: 8) {
                Text(updateStore.brewUninstallCommand)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(updateStore.brewUninstallCommand, forType: .string)
                    brewCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { brewCopied = false }
                } label: {
                    Image(systemName: brewCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(brewCopied ? .green : .white.opacity(0.4))
                }
                .buttonStyle(.plain)
                Spacer()
                Button(String(localized: "update.brew.dismiss")) {
                    updateStore.dismissBrewMigration()
                }
                .font(.system(size: 10))
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func formatInterval(_ seconds: Int) -> String {
        let minutes = seconds / 60
        return "\(minutes) min"
    }

    // MARK: - Accounts summary

    /// "N accounts · active: <name>" (singular form for the migrated
    /// single-profile setup so it does not read as a multi-account feature
    /// the user never enabled).
    private var accountsSummary: String {
        let count = profileStore.profiles.count
        let name = profileStore.activeProfile.name
        if count == 1 {
            return String(format: String(localized: "settings.accounts.summary.one"), name)
        }
        return String(format: String(localized: "settings.accounts.summary.many"), count, name)
    }

    /// Same tone mapping as the Accounts cards, collapsed to a dot: green when
    /// the active profile fetched fine, orange for transient conditions
    /// (backoff, waiting for Claude Code), red when there is nothing to read.
    private var activeStatusColor: Color {
        switch usageStore.errorState {
        case .none:
            return usageStore.hasConfig ? DS.Palette.semanticSuccess : DS.Palette.semanticError
        case .rateLimited, .networkError:
            return DS.Palette.semanticWarning
        case .tokenUnavailable:
            return usageStore.isAwaitingRefresh ? DS.Palette.semanticWarning : DS.Palette.semanticError
        case .reauthRequired:
            return DS.Palette.semanticError
        }
    }
}

// MARK: - Terminal integration card

/// Settings -> General -> "Terminal integration": the master switch for the
/// generated `cla` / `claw` commands and Warp Tab Configs, the `~/.zshrc`
/// hook that loads them, where the files live, and two usage examples. The
/// per-account command name, colour and token live on the Accounts cards.
private struct TerminalIntegrationCard: View {
    @EnvironmentObject private var profileStore: ProfileStore

    /// Local mirror of the flag for the switch (`@State` + `.onChange`, per
    /// the SwiftUI rules in AGENTS.md).
    @State private var enabledDraft: Bool
    /// Not observable on the service: re-read on appear and after each action.
    @State private var shellStatus: ShellIntegrationStatus = .notInstalled
    @State private var isWarpInstalled = false
    @State private var shellError: String?
    @State private var didRegenerate = false

    private let home = ClaudeKeychainServiceName.realHome

    init(initialEnabled: Bool) {
        _enabledDraft = State(initialValue: initialEnabled)
    }

    private var service: TerminalIntegrationServiceProtocol { profileStore.terminalIntegration }

    var body: some View {
        glassCard {
            VStack(alignment: .leading, spacing: 12) {
                cardLabel(String(localized: "settings.terminal.title"))
                darkToggle(String(localized: "settings.terminal.toggle"), isOn: $enabledDraft)
                inlineMarkdownText(String(localized: "settings.terminal.hint"))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)

                if profileStore.terminalIntegrationEnabled {
                    Divider().opacity(0.12)
                    shellRow
                    filesBlock
                    regenerateRow
                    errorLines
                    Divider().opacity(0.12)
                    examples
                } else if shellStatus == .installed {
                    // Off, but ~/.zshrc still sources the (now deleted) script:
                    // harmless thanks to the `-f` guard, offer the cleanup.
                    leftoverRow
                    errorLines
                }
            }
        }
        .onAppear { refreshEnvironment() }
        .onChange(of: enabledDraft) { _, enabled in
            if profileStore.terminalIntegrationEnabled != enabled {
                profileStore.setTerminalIntegrationEnabled(enabled)
            }
            refreshEnvironment()
        }
        .onChange(of: profileStore.terminalIntegrationEnabled) { _, enabled in
            if enabledDraft != enabled { enabledDraft = enabled }
        }
    }

    // MARK: Shell hook

    private var shellRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(shellTint)
                    .frame(width: 7, height: 7)
                Text(shellLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(shellTint)
                Spacer(minLength: 0)
                if shellStatus == .installed {
                    CardActionButton(
                        title: String(localized: "settings.terminal.shell.uninstall"),
                        icon: "minus.circle",
                        tint: DS.Palette.semanticError
                    ) {
                        uninstallShell()
                    }
                } else {
                    CardActionButton(
                        title: String(localized: "settings.terminal.shell.install"),
                        icon: "plus.circle",
                        tint: DS.Palette.accentSettings,
                        isProminent: true
                    ) {
                        installShell()
                    }
                }
            }
            inlineMarkdownText(String(localized: "settings.terminal.shell.newTerminal"))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var shellLabel: String {
        switch shellStatus {
        case .installed: return String(localized: "settings.terminal.shell.installed")
        case .notInstalled: return String(localized: "settings.terminal.shell.notInstalled")
        case .noZshrc: return String(localized: "settings.terminal.shell.noZshrc")
        }
    }

    private var shellTint: Color {
        shellStatus == .installed ? DS.Palette.semanticSuccess : DS.Palette.semanticWarning
    }

    private var leftoverRow: some View {
        HStack(spacing: 8) {
            Text(String(localized: "settings.terminal.shell.leftover"))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            CardActionButton(
                title: String(localized: "settings.terminal.shell.uninstall"),
                icon: "minus.circle",
                tint: DS.Palette.semanticError
            ) {
                uninstallShell()
            }
        }
    }

    // MARK: Generated files

    private var filesBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            pathRow(String(localized: "settings.terminal.files.script"), service.scriptPath, note: nil)
            pathRow(
                String(localized: "settings.terminal.files.tabConfigs"),
                service.tabConfigDirectory,
                note: isWarpInstalled ? nil : String(localized: "settings.terminal.files.noWarp")
            )
        }
    }

    private func pathRow(_ label: String, _ path: String, note: String?) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 120, alignment: .leading)
            Text(abbreviated(path))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if let note {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.35))
            }
            Spacer(minLength: 0)
        }
    }

    private var regenerateRow: some View {
        HStack {
            CardActionButton(
                title: didRegenerate
                    ? String(localized: "settings.terminal.regenerated")
                    : String(localized: "settings.terminal.regenerate"),
                icon: didRegenerate ? "checkmark" : "arrow.clockwise",
                tint: DS.Palette.accentSettings
            ) {
                regenerate()
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var errorLines: some View {
        if let error = profileStore.terminalIntegrationError {
            Text(String(format: String(localized: "settings.terminal.error"), error))
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let shellError {
            Text(shellError)
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Examples

    private var examples: some View {
        let name = profileStore.terminalEntries.first?.name ?? "work"
        return VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "settings.terminal.examples"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
            exampleRow("cla \(name) --resume", caption: String(localized: "settings.terminal.example.resume"))
            exampleRow("claw \(name) --model opus", caption: String(localized: "settings.terminal.example.warp"))
        }
    }

    private func exampleRow(_ command: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: command)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.black.opacity(0.35))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(.white.opacity(0.06), lineWidth: 1)
                        )
                )
            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Behaviour

    private func refreshEnvironment() {
        shellStatus = service.shellIntegrationStatus()
        isWarpInstalled = service.isWarpInstalled
    }

    private func installShell() {
        do {
            try service.installShellIntegration()
            shellError = nil
        } catch {
            shellError = String(format: String(localized: "settings.terminal.shell.error"), error.localizedDescription)
        }
        refreshEnvironment()
    }

    private func uninstallShell() {
        do {
            try service.uninstallShellIntegration()
            shellError = nil
        } catch {
            shellError = String(format: String(localized: "settings.terminal.shell.error"), error.localizedDescription)
        }
        refreshEnvironment()
    }

    private func regenerate() {
        profileStore.regenerateTerminalIntegration()
        refreshEnvironment()
        guard profileStore.terminalIntegrationError == nil else { return }
        didRegenerate = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { didRegenerate = false }
    }

    /// Real home abbreviated to `~` for display only.
    private func abbreviated(_ path: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

// MARK: - About link row

/// Single link inside the About card. Mirrors the hover pattern used by
/// `MonitoringView.refreshButton` and `MainAppView.powerButton`: glassFill +
/// accentSettings tint with springSnap, and a subtle -1pt lift.
private struct AboutLinkRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let url: URL

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(isHovering
                              ? DS.Palette.accentSettings.opacity(0.18)
                              : DS.Palette.glassFill)
                        .overlay(
                            Circle().stroke(
                                isHovering
                                    ? DS.Palette.accentSettings.opacity(0.55)
                                    : DS.Palette.glassBorderLo,
                                lineWidth: 1
                            )
                        )
                        .frame(width: 30, height: 30)
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isHovering
                                         ? DS.Palette.accentSettings
                                         : .white.opacity(0.65))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(isHovering ? 0.95 : 0.85))
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                }

                Spacer(minLength: 0)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isHovering
                                     ? DS.Palette.accentSettings
                                     : .white.opacity(0.35))
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovering ? DS.Palette.glassFill : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .offset(y: (isHovering && !reduceMotion) ? -1 : 0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(DS.Motion.springSnap) { isHovering = hovering }
        }
    }
}
