import Foundation

/// The OAuth credential set Claude Code stores under `claudeAiOauth`, as
/// TokenEater keeps it in its vault. `expiresAt` is optional: some sources
/// (Claude Desktop config.json) only expose the access token.
struct OAuthCredentials: Codable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var scopes: [String]
    var subscriptionType: String?

    static let defaultScopes = ["user:inference", "user:profile"]

    init(
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: Date? = nil,
        scopes: [String] = OAuthCredentials.defaultScopes,
        subscriptionType: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes.isEmpty ? OAuthCredentials.defaultScopes : scopes
        self.subscriptionType = subscriptionType
    }

    /// True when the access token is past (or within `leeway` of) its expiry.
    /// An unknown expiry is treated as valid: the 401 path handles it.
    func isExpired(now: Date = Date(), leeway: TimeInterval = 120) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) <= leeway
    }

    /// Seconds until expiry; nil when unknown.
    func timeToExpiry(now: Date = Date()) -> TimeInterval? {
        expiresAt.map { $0.timeIntervalSince(now) }
    }

    /// Same refresh-token chain: the same refresh token (both known), or the
    /// same access token. Two holders of one chain must not both refresh it.
    func isSameChain(as other: OAuthCredentials) -> Bool {
        if let a = refreshToken, let b = other.refreshToken, !a.isEmpty, a == b { return true }
        return accessToken == other.accessToken
    }

    /// Strictly later expiry than `other`. Unknown expiries are never newer.
    func isNewer(than other: OAuthCredentials) -> Bool {
        guard let mine = expiresAt else { return false }
        guard let theirs = other.expiresAt else { return true }
        return mine > theirs
    }
}

/// Claude Code's on-disk / Keychain JSON shape:
/// `{"claudeAiOauth": {"accessToken", "refreshToken", "expiresAt" (epoch ms), "scopes", "subscriptionType", ...}}`.
/// Parses it into `OAuthCredentials` and merges credentials back **without
/// dropping unknown keys**, so a write-back never loses fields Claude Code
/// added after this build shipped.
enum ClaudeCredentialsPayload {
    static let rootKey = "claudeAiOauth"

    static func parse(_ data: Data) -> (credentials: OAuthCredentials, raw: [String: Any])? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parse(object: obj)
    }

    static func parse(string: String) -> (credentials: OAuthCredentials, raw: [String: Any])? {
        guard let data = string.data(using: .utf8) else { return nil }
        return parse(data)
    }

    static func parse(object raw: [String: Any]) -> (credentials: OAuthCredentials, raw: [String: Any])? {
        guard let oauth = raw[rootKey] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        let refresh = (oauth["refreshToken"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let expiresAt: Date? = {
            if let ms = oauth["expiresAt"] as? Double { return Date(timeIntervalSince1970: ms / 1000) }
            if let ms = oauth["expiresAt"] as? Int { return Date(timeIntervalSince1970: Double(ms) / 1000) }
            if let ms = oauth["expiresAt"] as? Int64 { return Date(timeIntervalSince1970: Double(ms) / 1000) }
            return nil
        }()
        let scopes = (oauth["scopes"] as? [String]) ?? OAuthCredentials.defaultScopes
        let subscription = oauth["subscriptionType"] as? String
        let creds = OAuthCredentials(
            accessToken: token,
            refreshToken: refresh,
            expiresAt: expiresAt,
            scopes: scopes,
            subscriptionType: subscription
        )
        return (creds, raw)
    }

    /// Returns `raw` with the credential fields replaced inside `claudeAiOauth`.
    /// Every other key (at the root and inside the oauth object) is preserved.
    static func merge(_ credentials: OAuthCredentials, into raw: [String: Any]) -> [String: Any] {
        var root = raw
        var oauth = (root[rootKey] as? [String: Any]) ?? [:]
        oauth["accessToken"] = credentials.accessToken
        if let refresh = credentials.refreshToken {
            oauth["refreshToken"] = refresh
        }
        if let expiresAt = credentials.expiresAt {
            oauth["expiresAt"] = Int(expiresAt.timeIntervalSince1970 * 1000)
        }
        oauth["scopes"] = credentials.scopes
        if let subscription = credentials.subscriptionType {
            oauth["subscriptionType"] = subscription
        }
        root[rootKey] = oauth
        return root
    }

    /// Serialized form of `merge(_:into:)`, ready to write to the credentials
    /// file or the Keychain item.
    static func mergedData(_ credentials: OAuthCredentials, into raw: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: merge(credentials, into: raw), options: [.sortedKeys])
    }
}
