import Foundation

/// What a profile's token provider knows about its credentials. Surfaced in
/// the Accounts settings, the dashboard overview strip and the widgets.
enum ProfileCredentialState: Equatable {
    case unknown
    /// No live store and no vault entry.
    case missing
    case ok(expiresAt: Date?)
    /// Less than 30 minutes of validity left.
    case expiringSoon(expiresAt: Date)
    /// Expired and the renewal policy is `.claudeCode`: waiting for Claude
    /// Code to refresh the token on its next run.
    case awaitingClaudeCode
    /// The refresh grant was rejected, or a managed profile has no refresh
    /// token: the user must log in again with this account.
    case reauthRequired(reason: String)

    /// Stable string for `shared.json` and diagnostics.
    var rawKind: String {
        switch self {
        case .unknown: return "unknown"
        case .missing: return "missing"
        case .ok: return "ok"
        case .expiringSoon: return "expiring"
        case .awaitingClaudeCode: return "awaiting"
        case .reauthRequired: return "reauth"
        }
    }

    var isHealthy: Bool {
        switch self {
        case .ok, .expiringSoon: return true
        default: return false
        }
    }

    /// Classifies a credential set by its expiry alone.
    static func from(_ credentials: OAuthCredentials, now: Date = Date()) -> ProfileCredentialState {
        guard let expiresAt = credentials.expiresAt else { return .ok(expiresAt: nil) }
        let remaining = expiresAt.timeIntervalSince(now)
        if remaining <= 0 { return .awaitingClaudeCode }
        if remaining < 30 * 60 { return .expiringSoon(expiresAt: expiresAt) }
        return .ok(expiresAt: expiresAt)
    }
}

/// Result of `TokenProviderProtocol.ensureFreshToken(force:)`.
enum TokenReadiness: Equatable {
    /// A usable access token is available.
    case ready
    /// Expired; policy leaves the renewal to Claude Code.
    case awaitingClaudeCode
    /// The credential chain is dead; the user must re-authenticate.
    case reauthRequired
    /// No credentials at all.
    case missing
}
