import Foundation

final class MockTerminalIntegrationService: TerminalIntegrationServiceProtocol, @unchecked Sendable {
    var scriptPath: String = "/tmp/te-mock/.config/tokeneater/claude-accounts.zsh"
    var tabConfigDirectory: String = "/tmp/te-mock/.warp/tab_configs"
    var isWarpInstalled: Bool = true
    var status: ShellIntegrationStatus = .notInstalled

    var regenerateCallCount = 0
    var lastEntries: [TerminalAccountEntry]?
    var regenerateError: Error?
    var removeCallCount = 0
    var installCallCount = 0
    var uninstallCallCount = 0

    func regenerate(entries: [TerminalAccountEntry]) throws {
        regenerateCallCount += 1
        if let regenerateError { throw regenerateError }
        lastEntries = entries
    }

    func removeGeneratedFiles() throws {
        removeCallCount += 1
        lastEntries = nil
    }

    func shellIntegrationStatus() -> ShellIntegrationStatus { status }

    func installShellIntegration() throws {
        installCallCount += 1
        status = .installed
    }

    func uninstallShellIntegration() throws {
        uninstallCallCount += 1
        status = .notInstalled
    }
}
