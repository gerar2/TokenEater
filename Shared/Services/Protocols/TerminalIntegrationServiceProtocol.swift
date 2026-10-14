import Foundation

/// Whether `~/.zshrc` sources the generated script.
enum ShellIntegrationStatus: Equatable {
    case installed
    case notInstalled
    /// No `~/.zshrc` at all (`installShellIntegration` creates it).
    case noZshrc
}

/// Writes the generated terminal integration to disk: the zsh script with the
/// `cla` / `claw` functions (`~/.config/tokeneater/claude-accounts.zsh`), one
/// Warp Tab Config per account (`~/.warp/tab_configs/tokeneater_<name>.toml`),
/// and the marked block in `~/.zshrc` that sources the script.
/// See `docs/terminal-accounts-plan.md` §3.3.
protocol TerminalIntegrationServiceProtocol: Sendable {
    var scriptPath: String { get }
    var tabConfigDirectory: String { get }
    var isWarpInstalled: Bool { get }
    /// Writes the script and every Tab Config, and deletes generated Tab
    /// Configs (first line carries the marker) that are no longer listed.
    func regenerate(entries: [TerminalAccountEntry]) throws
    /// Deletes the script and every generated Tab Config.
    func removeGeneratedFiles() throws
    func shellIntegrationStatus() -> ShellIntegrationStatus
    func installShellIntegration() throws
    func uninstallShellIntegration() throws
}
