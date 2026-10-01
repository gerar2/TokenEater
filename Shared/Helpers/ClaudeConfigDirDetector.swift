import Foundation

/// Finds directories on disk that look like Claude Code config directories
/// (`CLAUDE_CONFIG_DIR`), so the Accounts settings can offer them as one-click
/// link targets instead of making the user browse for a hidden folder.
///
/// Pure filesystem lookup: two directory listings and a few `fileExists`
/// probes. No Keychain access, no symlink resolution, no network.
enum ClaudeConfigDirDetector {
    /// Any of these inside a directory marks it as a Claude Code config dir.
    /// `.claude.json` and `.credentials.json` are written there for a custom
    /// `CLAUDE_CONFIG_DIR`; `projects` is the sessions folder every config dir
    /// gets after the first run. The default `~/.claude` keeps its
    /// `.claude.json` one level up (in the home directory), so `projects` is
    /// usually what qualifies it.
    static let markers: [String] = [".claude.json", ".credentials.json", "projects"]

    /// Name TokenEater proposes for a freshly linked profile when the user
    /// picks the default directory or a directory whose name carries no hint.
    static let defaultSuggestedName = "Claude Code"

    /// Absolute paths (no trailing slash): the default `~/.claude` first, then
    /// `~/.claude-*`, then `~/.config/claude*`, each group in name order. Only
    /// directories containing one of `markers` are returned.
    static func candidates(home: String, fileManager: FileManager = .default) -> [String] {
        let root = stripTrailingSlashes(home)
        var result: [String] = []

        func consider(_ path: String) {
            guard isDirectory(path, fileManager),
                  looksLikeConfigDir(path, fileManager: fileManager),
                  !result.contains(path) else { return }
            result.append(path)
        }

        consider(root + "/.claude")
        for name in sortedEntries(of: root, fileManager) where name.hasPrefix(".claude-") {
            consider(root + "/" + name)
        }
        let configRoot = root + "/.config"
        for name in sortedEntries(of: configRoot, fileManager) where name.hasPrefix("claude") {
            consider(configRoot + "/" + name)
        }
        return result
    }

    /// True when `path` contains at least one of `markers`.
    static func looksLikeConfigDir(_ path: String, fileManager: FileManager = .default) -> Bool {
        let base = stripTrailingSlashes(path)
        return markers.contains { fileManager.fileExists(atPath: base + "/" + $0) }
    }

    /// Profile name derived from a config directory: the last path component
    /// without its leading dot and `claude` prefix, capitalised
    /// (`~/.claude-work` -> "Work", `~/.config/claude-x` -> "X"). Directories
    /// carrying no hint (`~/.claude`, `~/.config/claude`) fall back to
    /// `defaultSuggestedName`.
    static func suggestedName(forConfigDir path: String) -> String {
        var last = (stripTrailingSlashes(path) as NSString).lastPathComponent
        if last.hasPrefix(".") { last.removeFirst() }
        if last.lowercased().hasPrefix("claude") {
            last = String(last.dropFirst("claude".count))
        }
        last = last.trimmingCharacters(in: CharacterSet(charactersIn: "-_. "))
        guard let first = last.first else { return defaultSuggestedName }
        return first.uppercased() + last.dropFirst()
    }

    // MARK: - Private

    private static func isDirectory(_ path: String, _ fileManager: FileManager) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func sortedEntries(of directory: String, _ fileManager: FileManager) -> [String] {
        ((try? fileManager.contentsOfDirectory(atPath: directory)) ?? []).sorted()
    }

    private static func stripTrailingSlashes(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }
}
