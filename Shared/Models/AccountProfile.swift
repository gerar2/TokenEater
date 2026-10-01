import Foundation

// MARK: - Credential source

/// Where a profile's live Claude Code credentials live.
///
/// - `claudeCode(configDir:)`: Claude Code's own store for a config directory
///   (`CLAUDE_CONFIG_DIR`). `nil` is the default `~/.claude`. TokenEater reads
///   the Keychain item named by `ClaudeKeychainServiceName`, then
///   `<dir>/.credentials.json`, then (default dir only) the Claude Desktop
///   `config.json` decryption path.
/// - `managed`: TokenEater captured the credentials into its own Keychain item
///   (`ProfileCredentialVault`) and is their only holder, so it renews them.
enum ProfileCredentialSource: Equatable, Hashable {
    case claudeCode(configDir: String?)
    case managed

    var isLinked: Bool {
        if case .claudeCode = self { return true }
        return false
    }

    var configDir: String? {
        if case .claudeCode(let dir) = self { return dir }
        return nil
    }
}

extension ProfileCredentialSource: Codable {
    private enum CodingKeys: String, CodingKey { case kind, configDir }
    private enum Kind: String, Codable { case claudeCode, managed }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .claudeCode:
            self = .claudeCode(configDir: try c.decodeIfPresent(String.self, forKey: .configDir))
        case .managed:
            self = .managed
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .claudeCode(let dir):
            try c.encode(Kind.claudeCode, forKey: .kind)
            try c.encodeIfPresent(dir, forKey: .configDir)
        case .managed:
            try c.encode(Kind.managed, forKey: .kind)
        }
    }
}

// MARK: - Renewal policy

/// Who renews the OAuth access token when it expires.
///
/// - `claudeCode`: TokenEater never calls the refresh grant; it re-reads the
///   live store and waits for Claude Code to refresh (today's behaviour).
/// - `tokenEater`: TokenEater refreshes with the stored refresh token. For a
///   linked profile the rotated credentials are written back to the same store
///   they were read from so Claude Code keeps working.
enum TokenRenewalPolicy: String, Codable, CaseIterable {
    case claudeCode
    case tokenEater
}

// MARK: - Profile

/// A Claude account TokenEater monitors. See `docs/multi-profile-plan.md`.
struct AccountProfile: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var name: String
    /// "#RRGGBB" accent used for the profile's dot / chips / widget header.
    var colorHex: String
    var source: ProfileCredentialSource
    var renewalPolicy: TokenRenewalPolicy
    var isEnabled: Bool
    var createdAt: Date
    /// Cached identity from `/api/oauth/profile` (display only).
    var accountEmail: String?
    var accountUUID: String?
    /// `PlanType.rawValue`, cached for surfaces that render before the first fetch.
    var planTypeRaw: String?

    init(
        id: UUID = UUID(),
        name: String,
        colorHex: String = ProfilePalette.presets[0],
        source: ProfileCredentialSource,
        renewalPolicy: TokenRenewalPolicy = .claudeCode,
        isEnabled: Bool = true,
        createdAt: Date = Date(),
        accountEmail: String? = nil,
        accountUUID: String? = nil,
        planTypeRaw: String? = nil
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.source = source
        self.renewalPolicy = renewalPolicy
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.accountEmail = accountEmail
        self.accountUUID = accountUUID
        self.planTypeRaw = planTypeRaw
    }

    /// A managed profile has no other holder, so TokenEater always renews it.
    var effectiveRenewalPolicy: TokenRenewalPolicy {
        source == .managed ? .tokenEater : renewalPolicy
    }

    var isLinked: Bool { source.isLinked }

    /// Associated config dir for linked profiles (nil = default `~/.claude`,
    /// and nil for managed profiles).
    var configDir: String? { source.configDir }

    /// Whether this is the migrated default profile (linked to `~/.claude`).
    var isDefaultClaudeCodeProfile: Bool {
        source == .claudeCode(configDir: nil)
    }

    /// The directory Claude Code actually uses for this profile. `realHome`
    /// must be the real home (`getpwuid`), not the sandbox container.
    func resolvedConfigDir(realHome: String) -> String {
        guard let dir = configDir else { return realHome + "/.claude" }
        return ClaudeKeychainServiceName.normalize(dir, realHome: realHome)
    }

    var planType: PlanType? { planTypeRaw.flatMap(PlanType.init(rawValue:)) }

    /// Tolerant decoding: a missing or unknown optional field falls back to its
    /// default so a blob written by a newer build still decodes.
    private enum CodingKeys: String, CodingKey {
        case id, name, colorHex, source, renewalPolicy, isEnabled, createdAt
        case accountEmail, accountUUID, planTypeRaw
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        source = try c.decode(ProfileCredentialSource.self, forKey: .source)
        colorHex = (try? c.decodeIfPresent(String.self, forKey: .colorHex)) ?? ProfilePalette.presets[0]
        renewalPolicy = (try? c.decodeIfPresent(TokenRenewalPolicy.self, forKey: .renewalPolicy)) ?? .claudeCode
        isEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? true
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date()
        accountEmail = try? c.decodeIfPresent(String.self, forKey: .accountEmail)
        accountUUID = try? c.decodeIfPresent(String.self, forKey: .accountUUID)
        planTypeRaw = try? c.decodeIfPresent(String.self, forKey: .planTypeRaw)
    }
}

// MARK: - Palette

/// Accent presets offered by the Accounts settings. Kept in sync with the
/// `DS.Palette` hues so profile colours read as part of the app.
enum ProfilePalette {
    static let presets: [String] = [
        "#32CE6A", // brand green
        "#60A5FA", // info blue
        "#A78BFA", // violet
        "#FFB347", // warm orange
        "#F87171", // red
        "#2DD4BF", // teal
        "#F472B6", // pink
        "#FACC15", // yellow
    ]

    /// First preset not yet in use; cycles by count once every preset is taken.
    static func next(after used: [String]) -> String {
        let usedSet = Set(used.map { $0.uppercased() })
        if let free = presets.first(where: { !usedSet.contains($0.uppercased()) }) {
            return free
        }
        return presets[used.count % presets.count]
    }
}
