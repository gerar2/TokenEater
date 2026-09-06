import SwiftUI
import AppKit

/// Settings -> Accounts. One card per monitored profile plus an "add" card
/// with the two onboarding flows (link a Claude Code config directory,
/// capture the current login). See `docs/multi-profile-plan.md` §5.2.
///
/// Every mutation goes through `ProfileStore`; the cards never hold profile
/// state of their own beyond transient drafts (rename field, toggles mirrored
/// through `@State` + `.onChange` per the SwiftUI rules in AGENTS.md).
struct AccountsSectionView: View {
    @EnvironmentObject private var profileStore: ProfileStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle(
                String(localized: "sidebar.accounts"),
                subtitle: String(localized: "sidebar.accounts.subtitle")
            )

            ForEach(profileStore.profiles) { profile in
                // The store is created lazily on first access; a nil here
                // only happens for an id that was removed mid-render.
                if let usage = profileStore.usageStore(for: profile.id) {
                    ProfileCard(
                        profile: profile,
                        usage: usage,
                        isActive: profile.id == profileStore.activeProfileID,
                        isLast: profileStore.profiles.count == 1
                    )
                }
            }

            AddAccountCard()

            Spacer()
        }
        .padding(24)
    }
}

// MARK: - Shared helpers

/// Real home (`getpwuid`), abbreviated to `~` for display. Reads that go to
/// disk / the Keychain use the full path; only labels use this.
private func abbreviateHome(_ path: String, home: String) -> String {
    if path == home { return "~" }
    if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    return path
}

private enum AccountsStatusTone {
    case healthy, attention, broken, idle

    var color: Color {
        switch self {
        case .healthy:   return DS.Palette.semanticSuccess
        case .attention: return DS.Palette.semanticWarning
        case .broken:    return DS.Palette.semanticError
        case .idle:      return DS.Palette.textTertiary
        }
    }
}

// MARK: - Profile card

private struct ProfileCard: View {
    let profile: AccountProfile
    @ObservedObject var usage: UsageStore
    let isActive: Bool
    let isLast: Bool

    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isRenaming = false
    @State private var draftName = ""
    @FocusState private var nameFieldFocused: Bool
    /// Blur commits the rename, but only once the field really held focus:
    /// SwiftUI resets a focus request it could not honour to `false`, which
    /// would otherwise read as an immediate blur and close the editor.
    @State private var renameFieldHadFocus = false
    @State private var showRemoveAlert = false
    @State private var inlineError: String?
    @State private var isHovering = false
    /// Local mirrors of the profile flags for the toggles: `profile` is a
    /// value, so the switches bind here and `.onChange` forwards to the store.
    @State private var enabledDraft: Bool
    @State private var autoRenewDraft: Bool

    private let home = ClaudeKeychainServiceName.realHome

    init(profile: AccountProfile, usage: UsageStore, isActive: Bool, isLast: Bool) {
        self.profile = profile
        self.usage = usage
        self.isActive = isActive
        self.isLast = isLast
        _enabledDraft = State(initialValue: profile.isEnabled)
        _autoRenewDraft = State(initialValue: profile.effectiveRenewalPolicy == .tokenEater)
    }

    private var accent: Color { Color(hex: profile.colorHex) }

    var body: some View {
        glassCard {
            VStack(alignment: .leading, spacing: 12) {
                header
                metaLines
                statusRow

                Divider().opacity(0.12)

                colorRow
                darkToggle(String(localized: "accounts.card.enabled"), isOn: $enabledDraft)
                renewalBlock

                if let inlineError {
                    Text(inlineError)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider().opacity(0.12)

                actionsRow
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isActive ? accent.opacity(0.45)
                             : (isHovering ? DS.Palette.glassBorder : DS.Palette.glassBorderLo),
                    lineWidth: 1
                )
        )
        .onHover { hovering in
            withAnimation(DS.Motion.springSnap) { isHovering = hovering }
        }
        .onChange(of: enabledDraft) { _, enabled in
            if profile.isEnabled != enabled { profileStore.setEnabled(profile.id, enabled) }
        }
        .onChange(of: profile.isEnabled) { _, enabled in
            if enabledDraft != enabled { enabledDraft = enabled }
        }
        .onChange(of: autoRenewDraft) { _, renew in
            guard profile.isLinked else { return }
            let policy: TokenRenewalPolicy = renew ? .tokenEater : .claudeCode
            if profile.renewalPolicy != policy { profileStore.setRenewalPolicy(profile.id, policy) }
        }
        .onChange(of: profile.effectiveRenewalPolicy) { _, policy in
            let renew = policy == .tokenEater
            if autoRenewDraft != renew { autoRenewDraft = renew }
        }
        .onChange(of: nameFieldFocused) { _, focused in
            if focused {
                renameFieldHadFocus = true
            } else if isRenaming && renameFieldHadFocus {
                // Blur commits, same as Return.
                commitRename()
            }
        }
        .alert(String(localized: "accounts.remove.confirm"), isPresented: $showRemoveAlert) {
            Button(String(localized: "accounts.remove.cancel"), role: .cancel) { }
            Button(String(localized: "accounts.remove.action"), role: .destructive) {
                remove()
            }
        } message: {
            Text(String(format: String(localized: "accounts.remove.message"), profile.name))
        }
    }

    // MARK: Header (dot + name / rename)

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(accent)
                .frame(width: 10, height: 10)
                .shadow(color: accent.opacity(0.6), radius: 4)

            if isRenaming {
                TextField(String(localized: "accounts.card.rename.placeholder"), text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: 260)
                    .focused($nameFieldFocused)
                    // Requested here rather than in `beginRename()`: the field
                    // must exist before focus can move to it.
                    .onAppear { nameFieldFocused = true }
                    .onSubmit { commitRename() }
                    .onExitCommand { cancelRename() }
            } else {
                Text(profile.name)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)

                Button {
                    beginRename()
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(DS.Palette.glassFill))
                }
                .buttonStyle(.plain)
                .help(String(localized: "accounts.card.rename"))
            }

            if isActive {
                Text(String(localized: "accounts.card.active"))
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(accent.opacity(0.16)))
                    .overlay(Capsule().stroke(accent.opacity(0.4), lineWidth: 1))
            }

            Spacer(minLength: 0)

            Text(usageLine)
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    // MARK: Source + identity

    private var metaLines: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: profile.isLinked ? "folder" : "key.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
                Text(sourceLine)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if profile.accountEmail != nil || plan != nil {
                HStack(spacing: 6) {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                    if let email = profile.accountEmail {
                        Text(email)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let plan {
                        Text(plan.displayLabel)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(plan.badgeColor.opacity(0.3))
                            .clipShape(Capsule())
                    }
                }
            }
        }
    }

    /// Live plan from the store wins over the cached one on the profile.
    private var plan: PlanType? {
        if usage.planType != .unknown { return usage.planType }
        if let cached = profile.planType, cached != .unknown { return cached }
        return nil
    }

    private var sourceLine: String {
        switch profile.source {
        case .managed:
            return String(localized: "accounts.source.captured")
        case .claudeCode(let dir):
            let shown = dir.map { abbreviateHome($0, home: home) } ?? "~/.claude"
            return String(format: String(localized: "accounts.source.claudeCode"), shown)
        }
    }

    private var usageLine: String {
        String(format: String(localized: "accounts.card.usage"), usage.fiveHourPct, usage.sevenDayPct)
    }

    // MARK: Status chip + updated

    private var statusRow: some View {
        HStack(spacing: 8) {
            let status = statusDescriptor
            HStack(spacing: 5) {
                Circle()
                    .fill(status.tone.color)
                    .frame(width: 6, height: 6)
                Text(status.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(status.tone.color)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(status.tone.color.opacity(0.12)))

            if usage.isLoading {
                ProgressView().scaleEffect(0.45).frame(width: 14, height: 14)
            }

            Spacer(minLength: 0)

            Text(updatedLine)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    /// Transport errors first (they hide the credential state), then the
    /// provider's own view of the credentials, then the legacy fallback for a
    /// provider that does not report a credential state (`.unknown`).
    private var statusDescriptor: (label: String, tone: AccountsStatusTone) {
        if !profile.isEnabled {
            return (String(localized: "profile.state.disabled"), .idle)
        }
        switch usage.errorState {
        case .rateLimited:
            return (String(localized: "accounts.state.rateLimited"), .attention)
        case .reauthRequired:
            return (String(localized: "profile.state.reauth"), .broken)
        case .networkError:
            return (String(localized: "accounts.state.network"), .attention)
        case .none, .tokenUnavailable:
            break
        }
        switch usage.credentialState {
        case .ok(let expiresAt):
            if let expiresAt {
                let relative = expiresAt.formatted(.relative(presentation: .named))
                return (String(format: String(localized: "accounts.state.okExpires"), relative), .healthy)
            }
            return (String(localized: "profile.state.ok"), .healthy)
        case .expiringSoon(let expiresAt):
            let relative = expiresAt.formatted(.relative(presentation: .named))
            return (String(format: String(localized: "accounts.state.expiringAt"), relative), .attention)
        case .awaitingClaudeCode:
            return (String(localized: "profile.state.awaiting"), .attention)
        case .reauthRequired:
            return (String(localized: "profile.state.reauth"), .broken)
        case .missing:
            return (String(localized: "profile.state.missing"), .broken)
        case .unknown:
            if usage.errorState == .tokenUnavailable {
                return usage.isAwaitingRefresh
                    ? (String(localized: "profile.state.awaiting"), .attention)
                    : (String(localized: "profile.state.missing"), .broken)
            }
            if usage.hasConfig && usage.lastUpdate != nil {
                return (String(localized: "profile.state.ok"), .healthy)
            }
            return (String(localized: "profile.state.unknown"), .idle)
        }
    }

    private var updatedLine: String {
        guard let last = usage.lastUpdate else {
            return String(localized: "accounts.card.neverUpdated")
        }
        return String(format: String(localized: "accounts.card.updated"),
                      last.formatted(.relative(presentation: .named)))
    }

    // MARK: Color picker

    private var colorRow: some View {
        HStack(spacing: 10) {
            Text(String(localized: "accounts.card.color"))
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.7))
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                ForEach(ProfilePalette.presets, id: \.self) { hex in
                    ColorSwatch(
                        hex: hex,
                        isSelected: hex.uppercased() == profile.colorHex.uppercased()
                    ) {
                        profileStore.setColor(profile.id, hex: hex)
                    }
                }
            }
        }
    }

    // MARK: Renewal policy

    @ViewBuilder
    private var renewalBlock: some View {
        if profile.isLinked {
            darkToggle(String(localized: "accounts.renew.toggle"), isOn: $autoRenewDraft)
            Text(String(localized: "accounts.renew.hint"))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10, weight: .semibold))
                Text(String(localized: "accounts.renew.managed"))
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(DS.Palette.semanticSuccess.opacity(0.85))
            Text(String(localized: "accounts.renew.managed.hint"))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Actions

    private var actionsRow: some View {
        HStack(spacing: 8) {
            if !isActive {
                CardActionButton(
                    title: String(localized: "accounts.card.setActive"),
                    icon: "checkmark.circle",
                    tint: accent,
                    isEnabled: profile.isEnabled
                ) {
                    profileStore.setActive(profile.id)
                }
            }
            CardActionButton(
                title: String(localized: "accounts.card.refresh"),
                icon: "arrow.clockwise",
                tint: DS.Palette.accentSettings,
                isEnabled: !usage.isLoading
            ) {
                inlineError = nil
                Task { await usage.refresh(thresholds: themeStore.thresholds, force: true) }
            }
            Spacer(minLength: 0)
            CardActionButton(
                title: String(localized: "accounts.card.remove"),
                icon: "trash",
                tint: DS.Palette.semanticError,
                isEnabled: !isLast
            ) {
                showRemoveAlert = true
            }
            .help(isLast ? String(localized: "accounts.error.cannotRemoveLast") : "")
        }
    }

    // MARK: Behaviour

    private func beginRename() {
        draftName = profile.name
        renameFieldHadFocus = false
        isRenaming = true
    }

    private func commitRename() {
        guard isRenaming else { return }
        profileStore.rename(profile.id, to: draftName)
        isRenaming = false
    }

    private func cancelRename() {
        isRenaming = false
    }

    private func remove() {
        do {
            try profileStore.remove(profile.id)
        } catch {
            inlineError = error.localizedDescription
        }
    }
}

// MARK: - Color swatch

private struct ColorSwatch: View {
    let hex: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(hex: hex))
                .frame(width: 14, height: 14)
                // Ring kept in the tree at opacity 0 so selection never
                // changes the view structure (stable identity, no layout jump).
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.9), lineWidth: 1.5)
                        .frame(width: 20, height: 20)
                        .opacity(isSelected ? 1 : 0)
                )
                .scaleEffect(isHovering && !isSelected ? 1.15 : 1.0)
                .frame(width: 22, height: 22)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(DS.Motion.springSnap) { isHovering = hovering }
        }
    }
}

// MARK: - Card action button

/// Compact pill button used on the profile cards and the add card. Mirrors
/// the `AboutLinkRow` hover: glassFill at rest, tinted fill + border and a
/// -1pt lift on hover with `springSnap`.
private struct CardActionButton: View {
    let title: String
    let icon: String
    let tint: Color
    var isEnabled: Bool = true
    var isProminent: Bool = false
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(fill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(border, lineWidth: 1)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .offset(y: (isHovering && isEnabled && !reduceMotion) ? -1 : 0)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { hovering in
            withAnimation(DS.Motion.springSnap) { isHovering = hovering }
        }
    }

    private var foreground: Color {
        if isProminent { return .white.opacity(0.95) }
        return isHovering ? tint : .white.opacity(0.8)
    }

    private var fill: Color {
        if isProminent { return tint.opacity(isHovering ? 0.32 : 0.22) }
        return isHovering ? tint.opacity(0.14) : DS.Palette.glassFill
    }

    private var border: Color {
        if isProminent { return tint.opacity(0.5) }
        return isHovering ? tint.opacity(0.45) : DS.Palette.glassBorder
    }
}

// MARK: - Add account card

private struct AddAccountCard: View {
    enum Flow { case link, capture }

    @EnvironmentObject private var profileStore: ProfileStore

    @State private var flow: Flow?
    @State private var name = ""
    @State private var selectedDir: String?
    @State private var detected: [String] = []
    @State private var isBusy = false
    @State private var errorMessage: String?

    private let home = ClaudeKeychainServiceName.realHome

    var body: some View {
        glassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    cardLabel(String(localized: "accounts.add.title"))
                    Spacer()
                    if flow != nil {
                        Button(String(localized: "accounts.add.cancel")) {
                            withAnimation(DS.Motion.springSnap) { reset() }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                        .disabled(isBusy)
                    }
                }

                switch flow {
                case nil:
                    choiceRows
                case .link?:
                    linkForm
                case .capture?:
                    captureForm
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onChange(of: flow) { _, newFlow in
            if newFlow == .link { detected = ClaudeConfigDirDetector.candidates(home: home) }
        }
    }

    // MARK: Choice

    private var choiceRows: some View {
        VStack(spacing: 4) {
            FlowChoiceRow(
                icon: "folder.badge.plus",
                title: String(localized: "accounts.add.link.title"),
                subtitle: String(localized: "accounts.add.link.subtitle")
            ) {
                withAnimation(DS.Motion.springSnap) { start(.link) }
            }
            FlowChoiceRow(
                icon: "key.viewfinder",
                title: String(localized: "accounts.add.capture.title"),
                subtitle: String(localized: "accounts.add.capture.subtitle")
            ) {
                withAnimation(DS.Motion.springSnap) { start(.capture) }
            }
        }
    }

    // MARK: Link flow

    private var linkForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "accounts.link.detected"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))

            if detected.isEmpty {
                Text(String(localized: "accounts.link.none"))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 2) {
                    ForEach(detected, id: \.self) { dir in
                        DirectoryRow(
                            label: abbreviateHome(dir, home: home),
                            isSelected: selectedDir == dir,
                            isLinked: isAlreadyLinked(dir)
                        ) {
                            choose(dir)
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                CardActionButton(
                    title: String(localized: "accounts.link.browse"),
                    icon: "folder",
                    tint: DS.Palette.accentSettings,
                    isEnabled: !isBusy
                ) {
                    browse()
                }
                if let selectedDir, !detected.contains(selectedDir) {
                    Text(String(localized: "accounts.link.selected") + ": "
                         + abbreviateHome(selectedDir, home: home))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            nameField

            HStack {
                Spacer()
                submitButton(
                    title: String(localized: "accounts.link.action"),
                    icon: "link",
                    enabled: selectedDir != nil && !trimmedName.isEmpty
                ) {
                    submitLink()
                }
            }
        }
    }

    private func isAlreadyLinked(_ dir: String) -> Bool {
        let normalized = ClaudeKeychainServiceName.normalize(dir, realHome: home)
        return profileStore.profiles.contains {
            $0.isLinked && $0.resolvedConfigDir(realHome: home) == normalized
        }
    }

    private func choose(_ dir: String) {
        selectedDir = dir
        name = ClaudeConfigDirDetector.suggestedName(forConfigDir: dir)
        errorMessage = nil
    }

    /// Directories only, hidden folders visible (config dirs are dot-folders),
    /// starting at the real home. `runModal` keeps the flow synchronous; the
    /// panel is app-modal but this is a one-off pick.
    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: home, isDirectory: true)
        panel.prompt = String(localized: "accounts.link.panel.prompt")
        panel.message = String(localized: "accounts.link.panel.message")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        choose(url.path)
    }

    private func submitLink() {
        guard let dir = selectedDir else { return }
        let normalized = ClaudeKeychainServiceName.normalize(dir, realHome: home)
        // The store treats nil as the default directory; passing the explicit
        // path would work too but nil keeps the migrated profile shape.
        let configDir: String? = ClaudeKeychainServiceName.isDefaultDir(normalized, realHome: home) ? nil : normalized
        run { try await profileStore.addLinkedProfile(name: trimmedName, configDir: configDir) }
    }

    // MARK: Capture flow

    private var captureForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                captureStep(1, String(localized: "accounts.capture.step1"))
                captureStep(2, String(localized: "accounts.capture.step2"))
                captureStep(3, String(localized: "accounts.capture.step3"))
            }

            nameField

            HStack {
                Spacer()
                submitButton(
                    title: String(localized: "accounts.capture.action"),
                    icon: "key.fill",
                    enabled: !trimmedName.isEmpty
                ) {
                    run { try await profileStore.captureCurrentLogin(name: trimmedName) }
                }
            }
        }
    }

    private func captureStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(DS.Palette.accentSettings)
                .frame(width: 18, height: 18)
                .background(Circle().fill(DS.Palette.accentSettings.opacity(0.16)))
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Shared form pieces

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nameField: some View {
        HStack(spacing: 10) {
            Text(String(localized: "accounts.add.name"))
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.7))
            TextField(String(localized: "accounts.add.name.placeholder"), text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .frame(maxWidth: 260)
                .disabled(isBusy)
        }
    }

    private func submitButton(title: String, icon: String, enabled: Bool,
                              action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            if isBusy {
                ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
                Text(String(localized: "accounts.add.busy"))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }
            CardActionButton(
                title: title,
                icon: icon,
                tint: DS.Palette.accentSettings,
                isEnabled: enabled && !isBusy,
                isProminent: true,
                action: action
            )
        }
    }

    private func start(_ newFlow: Flow) {
        flow = newFlow
        name = ""
        selectedDir = nil
        errorMessage = nil
    }

    private func reset() {
        flow = nil
        name = ""
        selectedDir = nil
        errorMessage = nil
    }

    /// Runs one store mutation, surfaces its error inline, collapses the form
    /// on success. `Task` inherits the main actor from the view.
    private func run(_ operation: @escaping () async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        Task {
            do {
                try await operation()
                withAnimation(DS.Motion.springSnap) { reset() }
            } catch {
                errorMessage = error.localizedDescription
            }
            isBusy = false
        }
    }
}

// MARK: - Flow choice row

private struct FlowChoiceRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
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
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
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

// MARK: - Detected directory row

private struct DirectoryRow: View {
    let label: String
    let isSelected: Bool
    let isLinked: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? DS.Palette.accentSettings : .white.opacity(0.35))
                Text(label)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(isLinked ? 0.4 : 0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if isLinked {
                    Text(String(localized: "accounts.link.alreadyLinked"))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(DS.Palette.glassFillHi))
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected
                          ? DS.Palette.accentSettings.opacity(0.12)
                          : (isHovering ? DS.Palette.glassFill : Color.clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isLinked)
        .onHover { hovering in
            withAnimation(DS.Motion.springSnap) { isHovering = hovering }
        }
    }
}
