import Foundation

/// Phase 0 placeholder: lane T2 replaces this file with the implementation
/// described in `docs/terminal-accounts-plan.md` §3.3 (and adds
/// `Shared/Helpers/TerminalIntegrationGenerator.swift`, §3.2).
final class TerminalIntegrationService: TerminalIntegrationServiceProtocol, @unchecked Sendable {
    let realHome: String

    init(realHome: String = ClaudeKeychainServiceName.realHome) {
        self.realHome = realHome
    }

    var scriptPath: String { realHome + "/.config/tokeneater/claude-accounts.zsh" }
    var tabConfigDirectory: String { realHome + "/.warp/tab_configs" }
    var isWarpInstalled: Bool { false }

    func regenerate(entries: [TerminalAccountEntry]) throws {}
    func removeGeneratedFiles() throws {}
    func shellIntegrationStatus() -> ShellIntegrationStatus { .notInstalled }
    func installShellIntegration() throws {}
    func uninstallShellIntegration() throws {}
}
