import Foundation

/// Builds a Markdown diagnostic report from the current TokenEater state.
/// Used by the "Copy diagnostic" button in `PopoverErrorBanner`. The output
/// is meant to be pasted into a GitHub issue, so it is English-only and
/// never contains the OAuth bearer token, proxy credentials, organization
/// name, profile names, account emails, full paths, or any other PII.
enum DiagnosticReporter {

    /// Public entry point. The active profile's store fills the legacy
    /// `State` / `Last API error` sections; every profile in the catalog gets
    /// its own redacted bullet group under `Profiles`.
    @MainActor
    static func makeReport(profileStore: ProfileStore, settingsStore: SettingsStore) -> String {
        makeReport(
            usageStore: profileStore.activeUsageStore,
            settingsStore: settingsStore,
            profilesSection: profilesSection(profileStore)
        )
    }

    /// Single-store report without the `Profiles` section. Kept for callers
    /// and tests that predate `ProfileStore`.
    @MainActor
    static func makeReport(usageStore: UsageStore, settingsStore: SettingsStore) -> String {
        makeReport(usageStore: usageStore, settingsStore: settingsStore, profilesSection: nil)
    }

    @MainActor
    private static func makeReport(
        usageStore: UsageStore,
        settingsStore: SettingsStore,
        profilesSection: String?
    ) -> String {
        var sections = [
            appSection(),
            systemSection(),
            stateSection(usageStore: usageStore, settingsStore: settingsStore),
            apiErrorSection(usageStore.lastAPIError),
        ]
        if let profilesSection {
            sections.append(profilesSection)
        }
        return "## TokenEater diagnostic\n\n" + sections.joined(separator: "\n\n")
    }

    // MARK: - Sections

    private static func appSection() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "-"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        let bundleID = Bundle.main.bundleIdentifier ?? "-"
        let arch: String = {
            #if arch(arm64)
            return "arm64"
            #elseif arch(x86_64)
            return "x86_64"
            #else
            return "unknown"
            #endif
        }()
        return """
        **App**
        - Version: \(version) (build \(build))
        - Bundle: \(bundleID)
        - Architecture: \(arch)
        """
    }

    private static func systemSection() -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        return """
        **System**
        - macOS: \(os)
        """
    }

    @MainActor
    private static func stateSection(usageStore: UsageStore, settingsStore: SettingsStore) -> String {
        let errorState = errorStateName(usageStore.errorState)
        let speed = speedName(usageStore.currentSpeed)
        let interval = Int(usageStore.effectiveInterval)
        let lastUpdate = formatDate(usageStore.lastUpdate, relative: true) ?? "never"
        let retryAfter = formatDate(usageStore.retryAfterDate, relative: true) ?? "-"
        let plan = String(describing: usageStore.planType)
        let tier = usageStore.rateLimitTier ?? "-"
        let tokenPresent = usageStore.hasConfig ? "yes" : "no"
        let proxyConfigured: String
        if let proxy = usageStore.proxyConfig, proxy.isValidForUse {
            proxyConfigured = "yes"
        } else {
            proxyConfigured = "no"
        }

        return """
        **State**
        - Error state: \(errorState)
        - Refresh speed: \(speed)
        - Effective interval: \(interval)s
        - Last successful update: \(lastUpdate)
        - Retry-after deadline: \(retryAfter)
        - Plan: \(plan)
        - Rate limit tier: \(tier)
        - Token present: \(tokenPresent)
        - Proxy configured: \(proxyConfigured)
        """
    }

    /// One bullet group per profile. Only shape-level facts are printed:
    /// the name is reduced to its initial + length (names are user-chosen and
    /// may be an email or an employer), the config dir to its last path
    /// component, and the credential state to its `rawKind` (the re-auth
    /// reason can echo a server response body). Stores that were never
    /// started (disabled profiles) are reported as such instead of being
    /// created as a side effect of writing a report.
    @MainActor
    private static func profilesSection(_ profileStore: ProfileStore) -> String {
        var lines = [
            "**Profiles**",
            "- Count: \(profileStore.profiles.count) (enabled: \(profileStore.enabledProfiles.count))",
        ]
        for (index, profile) in profileStore.profiles.enumerated() {
            let store = profileStore.usageStores[profile.id]
            let credential = store?.credentialState
                ?? profileStore.credentialStates[profile.id]
                ?? .unknown
            lines.append("- Profile \(index + 1): \(redactName(profile.name))")
            lines.append("  - Active: \(profile.id == profileStore.activeProfileID ? "yes" : "no")")
            lines.append("  - Enabled: \(profile.isEnabled ? "yes" : "no")")
            lines.append("  - Source: \(sourceKindName(profile.source)) (dir: \(configDirLabel(profile.source)))")
            lines.append("  - Renewal policy: \(profile.effectiveRenewalPolicy.rawValue)")
            lines.append("  - Credential state: \(credentialStateLabel(credential))")
            if let store {
                let retryAfter = formatDate(store.retryAfterDate, relative: true) ?? "-"
                let lastUpdate = formatDate(store.lastUpdate, relative: true) ?? "never"
                lines.append("  - Error state: \(errorStateName(store.errorState))")
                lines.append("  - Refresh speed: \(speedName(store.currentSpeed))")
                lines.append("  - Effective interval: \(Int(store.effectiveInterval))s")
                lines.append("  - Retry-after deadline: \(retryAfter)")
                lines.append("  - Last successful update: \(lastUpdate)")
            } else {
                lines.append("  - Store: not started")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func apiErrorSection(_ error: LastAPIError?) -> String {
        guard let error else {
            return """
            **Last API error**
            - None captured
            """
        }
        let status = error.httpStatusCode.map(String.init) ?? "-"
        let retryHeader = error.retryAfterHeader.map { "\"\($0)\"" } ?? "-"
        let timestamp = formatDate(error.timestamp, relative: false) ?? "-"
        let underlying = error.underlyingError ?? "-"
        return """
        **Last API error**
        - Endpoint: \(error.endpoint)
        - HTTP status: \(status)
        - Retry-After header (raw): \(retryHeader)
        - Timestamp: \(timestamp)
        - Underlying error: \(underlying)
        """
    }

    // MARK: - Helpers

    /// "Personal" -> "P… (8 chars)". Enough to tell profiles apart in an
    /// issue thread without disclosing what the user called them.
    static func redactName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "- (0 chars)" }
        return "\(first)… (\(trimmed.count) chars)"
    }

    private static func sourceKindName(_ source: ProfileCredentialSource) -> String {
        switch source {
        case .claudeCode: return "claudeCode"
        case .managed: return "managed"
        }
    }

    /// Last path component only: `~/.claude-work` -> `.claude-work`. The
    /// default dir is spelled out so "nil" never reads as "unknown".
    private static func configDirLabel(_ source: ProfileCredentialSource) -> String {
        switch source {
        case .managed:
            return "-"
        case .claudeCode(let dir):
            guard let dir else { return ".claude" }
            let last = URL(fileURLWithPath: dir).lastPathComponent
            return last.isEmpty ? "-" : last
        }
    }

    private static func credentialStateLabel(_ state: ProfileCredentialState) -> String {
        switch state {
        case .ok(let expiresAt?), .expiringSoon(let expiresAt):
            let relative = relativeFormatter.localizedString(for: expiresAt, relativeTo: Date())
            return "\(state.rawKind) (expires \(relative))"
        default:
            return state.rawKind
        }
    }

    private static func errorStateName(_ state: AppErrorState) -> String {
        switch state {
        case .none: return "none"
        case .tokenUnavailable: return "tokenUnavailable"
        case .rateLimited: return "rateLimited"
        case .networkError: return "networkError"
        case .reauthRequired: return "reauthRequired"
        }
    }

    private static func speedName(_ speed: RefreshSpeed) -> String {
        switch speed {
        case .fast: return "fast"
        case .normal: return "normal"
        case .slow: return "slow"
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        f.locale = Locale(identifier: "en_US")
        return f
    }()

    private static func formatDate(_ date: Date?, relative: Bool) -> String? {
        guard let date else { return nil }
        let iso = isoFormatter.string(from: date)
        if relative {
            let rel = relativeFormatter.localizedString(for: date, relativeTo: Date())
            return "\(iso) (\(rel))"
        }
        return iso
    }
}
