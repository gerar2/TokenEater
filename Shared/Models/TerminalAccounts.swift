import Foundation

// MARK: - Terminal accounts (Phase 4)
//
// Start Claude Code in a terminal with a chosen account (`cla <name>`), or in a
// Warp tab coloured for it (`claw <name>`), while every account shares the same
// `~/.claude`. Each profile may hold a long-lived token from `claude setup-token`
// in the Keychain; the generated shell functions pass it as
// `CLAUDE_CODE_OAUTH_TOKEN`. See `docs/terminal-accounts-plan.md`.

/// The colours a Warp tab can take (Tab Config `color`, tab context menu).
enum WarpTabColor: String, Codable, CaseIterable, Identifiable {
    case black, red, green, yellow, blue, magenta, cyan, white

    var id: String { rawValue }

    /// Swatch shown in TokenEater. Warp derives the real tint from the active
    /// terminal theme; these are close to its default dark theme.
    var previewHex: String {
        switch self {
        case .black: return "#3F3F46"
        case .red: return "#F87171"
        case .green: return "#32CE6A"
        case .yellow: return "#FACC15"
        case .blue: return "#60A5FA"
        case .magenta: return "#C084FC"
        case .cyan: return "#2DD4BF"
        case .white: return "#E5E5E5"
        }
    }

    /// Explicit mapping for the profile palette (`ProfilePalette.presets`).
    private static let presetMapping: [String: WarpTabColor] = [
        "#32CE6A": .green,
        "#60A5FA": .blue,
        "#A78BFA": .magenta,
        "#FFB347": .yellow,
        "#F87171": .red,
        "#2DD4BF": .cyan,
        "#F472B6": .magenta,
        "#FACC15": .yellow,
    ]

    /// Warp colour closest to a profile colour: the preset table first, then
    /// the nearest hue (greys map to black / white by brightness).
    static func `default`(forProfileHex hex: String) -> WarpTabColor {
        let key = hex.uppercased().hasPrefix("#") ? hex.uppercased() : "#" + hex.uppercased()
        if let mapped = presetMapping[key] { return mapped }
        guard let (h, s, v) = hsv(fromHex: key) else { return .white }
        if s < 0.15 { return v < 0.5 ? .black : .white }
        // Hue anchors (degrees) of the six chromatic Warp colours.
        let anchors: [(WarpTabColor, Double)] = [
            (.red, 0), (.yellow, 50), (.green, 130), (.cyan, 180), (.blue, 215), (.magenta, 290),
        ]
        func distance(_ a: Double, _ b: Double) -> Double {
            let d = abs(a - b).truncatingRemainder(dividingBy: 360)
            return min(d, 360 - d)
        }
        return anchors.min { distance(h, $0.1) < distance(h, $1.1) }?.0 ?? .white
    }

    /// Hue in degrees, saturation and value in 0...1.
    static func hsv(fromHex hex: String) -> (Double, Double, Double)? {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        let maxC = max(r, g, b), minC = min(r, g, b), delta = maxC - minC
        var hue: Double = 0
        if delta > 0 {
            if maxC == r { hue = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
            else if maxC == g { hue = 60 * ((b - r) / delta + 2) }
            else { hue = 60 * ((r - g) / delta + 4) }
        }
        if hue < 0 { hue += 360 }
        return (hue, maxC == 0 ? 0 : delta / maxC, maxC)
    }
}

/// The command-line name of an account (`cla <name>`): a lowercase slug.
enum TerminalName {
    static let maxLength = 31

    /// `^[a-z0-9][a-z0-9-]{0,30}$`
    static func isValid(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.count <= maxLength,
              isAlnum(first) else { return false }
        return name.unicodeScalars.allSatisfy { isAlnum($0) || $0 == "-" }
    }

    /// A valid slug derived from a profile name: diacritics folded, lowercase,
    /// every other run of characters collapsed to "-", trimmed, at most 31
    /// characters; "account" when nothing usable is left.
    static func suggested(from profileName: String) -> String {
        let folded = profileName
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        var result = ""
        var pendingDash = false
        for scalar in folded.unicodeScalars {
            if isAlnum(scalar) {
                if pendingDash && !result.isEmpty { result.append("-") }
                pendingDash = false
                result.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        if result.count > maxLength {
            result = String(result.prefix(maxLength))
            while result.hasSuffix("-") { result.removeLast() }
        }
        return result.isEmpty ? "account" : result
    }

    /// `candidate`, or `candidate-2`, `candidate-3`, … the first one not in
    /// `taken`, always within `maxLength`.
    static func uniqued(_ candidate: String, taken: Set<String>) -> String {
        guard taken.contains(candidate) else { return candidate }
        var index = 2
        while true {
            let suffix = "-\(index)"
            var base = String(candidate.prefix(maxLength - suffix.count))
            while base.hasSuffix("-") { base.removeLast() }
            let name = base + suffix
            if !taken.contains(name) { return name }
            index += 1
        }
    }

    private static func isAlnum(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
    }
}

/// Shape check for a `claude setup-token` token before it is stored.
enum TerminalTokenFormat {
    static let prefix = "sk-ant-oat01-"
    static let minimumLength = 40

    static func isPlausible(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix(prefix)
            && trimmed.count >= minimumLength
            && !trimmed.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) }
    }
}

/// Where a profile's terminal token lives in the login Keychain. Keyed by the
/// profile id so renaming the profile or its command keeps the token.
enum TerminalTokenKeychain {
    static let servicePrefix = "TokenEater terminal token: "

    static func service(for profileID: UUID) -> String {
        servicePrefix + profileID.uuidString
    }
}

/// One account as the generated shell script and Warp Tab Configs see it.
struct TerminalAccountEntry: Equatable {
    /// Command-line name (`cla <name>`), unique across entries.
    let name: String
    let profileID: UUID
    let profileName: String
    /// Lets `cla` fall back to the plain `~/.claude` session when that is the
    /// account signed in there and no terminal token is stored.
    let accountUUID: String?
    let warpColor: WarpTabColor
    let keychainService: String
}

extension AccountProfile {
    /// `terminalName`, or the slug suggested by the profile name.
    var effectiveTerminalName: String {
        terminalName ?? TerminalName.suggested(from: name)
    }

    /// `warpColor`, or the Warp colour closest to the profile colour.
    var effectiveWarpColor: WarpTabColor {
        warpColor ?? WarpTabColor.default(forProfileHex: colorHex)
    }

    /// `claude setup-token` tokens last one year.
    static let terminalTokenLifetime: TimeInterval = 365 * 24 * 3600

    var terminalTokenExpiresAt: Date? {
        terminalTokenSetAt.map { $0.addingTimeInterval(Self.terminalTokenLifetime) }
    }
}
