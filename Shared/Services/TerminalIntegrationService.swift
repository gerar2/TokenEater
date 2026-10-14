import Foundation

/// Writes the terminal integration to disk (`docs/terminal-accounts-plan.md`
/// §3.3): the zsh script with `cla` / `claw`, one Warp Tab Config per account,
/// and the marked block in `~/.zshrc` that sources the script.
///
/// Every path derives from `realHome` (the real home from `getpwuid`, never a
/// sandbox container), so tests run against a temporary directory. The service
/// only ever deletes what it generated: Tab Configs named `tokeneater_*.toml`
/// whose first line carries `TerminalIntegrationGenerator.marker`, the script,
/// and the exact `~/.zshrc` block it added.
final class TerminalIntegrationService: TerminalIntegrationServiceProtocol, @unchecked Sendable {
    static let zshrcBlockStart = "# >>> TokenEater terminal accounts >>>"
    static let zshrcBlockEnd = "# <<< TokenEater terminal accounts <<<"
    static let zshrcSourceLine =
        #"[[ -f "$HOME/.config/tokeneater/claude-accounts.zsh" ]] && source "$HOME/.config/tokeneater/claude-accounts.zsh""#

    static var zshrcBlock: String {
        [zshrcBlockStart, zshrcSourceLine, zshrcBlockEnd].joined(separator: "\n")
    }

    let realHome: String
    private let fileManager: FileManager
    private let warpAppPath: String

    init(
        realHome: String = ClaudeKeychainServiceName.realHome,
        fileManager: FileManager = .default,
        warpAppPath: String = "/Applications/Warp.app"
    ) {
        self.realHome = realHome
        self.fileManager = fileManager
        self.warpAppPath = warpAppPath
    }

    // MARK: - Paths

    var configDirectory: String { realHome + "/.config/tokeneater" }
    var scriptPath: String { configDirectory + "/claude-accounts.zsh" }
    /// Where `claw` leaves the handoff for the tab it opens (`0700`).
    var pendingDirectory: String { configDirectory + "/pending" }
    var warpDirectory: String { realHome + "/.warp" }
    var tabConfigDirectory: String { warpDirectory + "/tab_configs" }
    var zshrcPath: String { realHome + "/.zshrc" }

    /// Warp in `/Applications` or in the user's own `~/Applications`.
    var isWarpInstalled: Bool {
        fileManager.fileExists(atPath: warpAppPath)
            || fileManager.fileExists(atPath: realHome + "/Applications/Warp.app")
    }

    // MARK: - Generated files

    func regenerate(entries: [TerminalAccountEntry]) throws {
        // ProfileStore only hands out valid slugs; a hand-edited catalog must
        // still never produce a path outside the Tab Config directory.
        let usable = entries.filter { TerminalName.isValid($0.name) }

        try fileManager.createDirectory(atPath: configDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            atPath: pendingDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // createDirectory leaves an existing directory's mode alone.
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: pendingDirectory)
        try writeIfChanged(TerminalIntegrationGenerator.zshScript(for: usable), to: scriptPath)

        // No ~/.warp: Warp never ran here, so there is nothing to configure.
        guard isDirectory(warpDirectory) else { return }
        try fileManager.createDirectory(atPath: tabConfigDirectory, withIntermediateDirectories: true)
        var current: Set<String> = []
        for entry in usable {
            let file = TerminalIntegrationGenerator.tabConfigStem(for: entry.name) + ".toml"
            current.insert(file)
            try writeIfChanged(
                TerminalIntegrationGenerator.warpTabConfig(for: entry),
                to: tabConfigDirectory + "/" + file
            )
        }
        try removeGeneratedTabConfigs(except: current)
    }

    func removeGeneratedFiles() throws {
        if fileManager.fileExists(atPath: scriptPath) {
            try fileManager.removeItem(atPath: scriptPath)
        }
        // Leftover handoffs are meaningless once the script is gone.
        if fileManager.fileExists(atPath: pendingDirectory) {
            try fileManager.removeItem(atPath: pendingDirectory)
        }
        try removeGeneratedTabConfigs(except: [])
    }

    /// Deletes `tokeneater_*.toml` regular files that carry the marker on
    /// their first line and are not in `keep`. Anything else is the user's.
    private func removeGeneratedTabConfigs(except keep: Set<String>) throws {
        guard let files = try? fileManager.contentsOfDirectory(atPath: tabConfigDirectory) else { return }
        for file in files.sorted()
        where file.hasPrefix(TerminalIntegrationGenerator.tabConfigPrefix)
            && file.hasSuffix(".toml")
            && !keep.contains(file) {
            let path = tabConfigDirectory + "/" + file
            guard isRegularFile(path), firstLine(of: path).contains(TerminalIntegrationGenerator.marker) else {
                continue
            }
            try fileManager.removeItem(atPath: path)
        }
    }

    /// Atomic write (a reader never sees half a file), `0644`. Skipped when
    /// the content is already there so regenerating on every catalog change
    /// does not touch files Warp may be watching.
    private func writeIfChanged(_ content: String, to path: String) throws {
        let data = Data(content.utf8)
        if fileManager.contents(atPath: path) != data {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
    }

    private func firstLine(of path: String) -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? handle.close() }
        let head = String(decoding: handle.readData(ofLength: 1024), as: UTF8.self)
        return head.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
    }

    private func isRegularFile(_ path: String) -> Bool {
        (try? fileManager.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeRegular
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: - ~/.zshrc

    func shellIntegrationStatus() -> ShellIntegrationStatus {
        guard fileManager.fileExists(atPath: zshrcPath) else { return .noZshrc }
        guard let content = try? String(contentsOfFile: zshrcPath, encoding: .utf8) else { return .notInstalled }
        return Self.blockRange(in: content.components(separatedBy: "\n")) == nil ? .notInstalled : .installed
    }

    /// Appends the block, preceded by a blank line, unless a complete block is
    /// already there. Creates `~/.zshrc` when it does not exist.
    func installShellIntegration() throws {
        let existing = try readZshrc()
        if let existing, Self.blockRange(in: existing.components(separatedBy: "\n")) != nil { return }
        let content: String
        if let existing, !existing.isEmpty {
            content = existing + (existing.hasSuffix("\n") ? "" : "\n") + "\n" + Self.zshrcBlock + "\n"
        } else {
            content = Self.zshrcBlock + "\n"
        }
        try writeZshrc(content)
    }

    /// Removes every complete block, and the blank line `install` put before
    /// it, leaving the rest of the file byte for byte.
    func uninstallShellIntegration() throws {
        guard let existing = try readZshrc() else { return }
        var lines = existing.components(separatedBy: "\n")
        var changed = false
        while let range = Self.blockRange(in: lines) {
            var lower = range.lowerBound
            if lower > 0, lines[lower - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                lower -= 1
            }
            lines.removeSubrange(lower...range.upperBound)
            changed = true
        }
        if changed { try writeZshrc(lines.joined(separator: "\n")) }
    }

    /// Lines of the first block that has both its start and its end marker.
    /// A lone marker (block half-deleted by hand) does not count, so
    /// `uninstall` never removes anything beyond a well-formed block.
    static func blockRange(in lines: [String]) -> ClosedRange<Int>? {
        func trimmed(_ line: String) -> String { line.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let start = lines.firstIndex(where: { trimmed($0) == zshrcBlockStart }),
              let end = lines[start...].firstIndex(where: { trimmed($0) == zshrcBlockEnd })
        else { return nil }
        return start...end
    }

    /// nil when the file does not exist. Throws when it is not UTF-8 rather
    /// than risk rewriting someone's shell configuration wrongly.
    private func readZshrc() throws -> String? {
        guard fileManager.fileExists(atPath: zshrcPath) else { return nil }
        return try String(contentsOfFile: zshrcPath, encoding: .utf8)
    }

    /// Writes through a symlinked `~/.zshrc` (dotfiles repositories) to its
    /// target, atomically, keeping the file's permissions.
    private func writeZshrc(_ content: String) throws {
        let target = URL(fileURLWithPath: zshrcPath).resolvingSymlinksInPath().path
        let permissions = (try? fileManager.attributesOfItem(atPath: target))?[.posixPermissions] as? NSNumber
        try Data(content.utf8).write(to: URL(fileURLWithPath: target), options: .atomic)
        try fileManager.setAttributes([.posixPermissions: permissions ?? NSNumber(value: 0o644)], ofItemAtPath: target)
    }
}
