import Foundation
import CryptoKit

/// Names the macOS Keychain item Claude Code uses for a config directory.
///
/// Verified against Claude Code 2.1.261: the default `~/.claude` store is the
/// generic password with service `Claude Code-credentials`; any other
/// `CLAUDE_CONFIG_DIR` gets `Claude Code-credentials-<hash8>` where `hash8` is
/// the first 8 hex characters of SHA-256 over the absolute directory path
/// (no trailing slash). The account attribute is the macOS user name.
enum ClaudeKeychainServiceName {
    static let base = "Claude Code-credentials"

    /// The real home directory (`getpwuid`), not a sandbox container.
    static var realHome: String {
        guard let pw = getpwuid(getuid()) else { return NSHomeDirectory() }
        return String(cString: pw.pointee.pw_dir)
    }

    static func service(forConfigDir dir: String?, realHome: String = ClaudeKeychainServiceName.realHome) -> String {
        guard let dir, !isDefaultDir(dir, realHome: realHome) else { return base }
        return base + "-" + hash8(normalize(dir, realHome: realHome))
    }

    static func isDefaultDir(_ dir: String?, realHome: String = ClaudeKeychainServiceName.realHome) -> Bool {
        guard let dir else { return true }
        return normalize(dir, realHome: realHome) == normalize(realHome + "/.claude", realHome: realHome)
    }

    /// Pure path normalisation (no filesystem access, no symlink resolution -
    /// Claude Code hashes the path string as given): expands a leading `~`,
    /// collapses `.` / `..` / duplicate slashes, strips trailing slashes.
    static func normalize(_ path: String, realHome: String = ClaudeKeychainServiceName.realHome) -> String {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if p == "~" {
            p = realHome
        } else if p.hasPrefix("~/") {
            p = realHome + String(p.dropFirst(1))
        }
        var parts: [String] = []
        for component in p.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(String(component))
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// First 8 hex characters of SHA-256 over the UTF-8 bytes of `input`.
    static func hash8(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}
