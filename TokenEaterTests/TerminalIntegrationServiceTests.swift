import Testing
import Foundation

@Suite("TerminalIntegrationService")
struct TerminalIntegrationServiceTests {

    /// A throwaway home directory, removed when the test ends.
    private final class TempHome {
        let path: String
        init(withWarp: Bool = true) throws {
            path = FileManager.default.temporaryDirectory
                .appendingPathComponent("te-home-\(UUID().uuidString)").path
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            if withWarp {
                try FileManager.default.createDirectory(atPath: path + "/.warp", withIntermediateDirectories: true)
            }
        }
        deinit { try? FileManager.default.removeItem(atPath: path) }
    }

    private static func entry(_ name: String, profileName: String? = nil, color: WarpTabColor = .cyan) -> TerminalAccountEntry {
        let id = UUID()
        return TerminalAccountEntry(
            name: name,
            profileID: id,
            profileName: profileName ?? name.uppercased(),
            accountUUID: "acc-\(name)",
            warpColor: color,
            keychainService: TerminalTokenKeychain.service(for: id)
        )
    }

    private let fm = FileManager.default

    private func makeSUT(_ home: TempHome, warpAppPath: String? = nil) -> TerminalIntegrationService {
        TerminalIntegrationService(realHome: home.path, warpAppPath: warpAppPath ?? home.path + "/no-Warp.app")
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    private func permissions(_ path: String) throws -> Int? {
        (try fm.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue
    }

    private func tabConfigFiles(_ sut: TerminalIntegrationService) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: sut.tabConfigDirectory)) ?? []).sorted()
    }

    // MARK: - Paths

    @Test("Every path derives from the injected home")
    func paths() throws {
        let home = try TempHome()
        let sut = makeSUT(home)
        #expect(sut.scriptPath == home.path + "/.config/tokeneater/claude-accounts.zsh")
        #expect(sut.pendingDirectory == home.path + "/.config/tokeneater/pending")
        #expect(sut.tabConfigDirectory == home.path + "/.warp/tab_configs")
        #expect(sut.zshrcPath == home.path + "/.zshrc")
    }

    @Test("Warp counts as installed in /Applications or in ~/Applications")
    func warpInstalled() throws {
        let home = try TempHome()
        #expect(!makeSUT(home).isWarpInstalled)

        let appPath = home.path + "/SystemApps/Warp.app"
        try fm.createDirectory(atPath: appPath, withIntermediateDirectories: true)
        #expect(makeSUT(home, warpAppPath: appPath).isWarpInstalled)

        try fm.createDirectory(atPath: home.path + "/Applications/Warp.app", withIntermediateDirectories: true)
        #expect(makeSUT(home).isWarpInstalled)
    }

    // MARK: - regenerate

    @Test("regenerate writes the script, one Tab Config per account and a private pending directory")
    func regenerateWritesFiles() throws {
        let home = try TempHome()
        let sut = makeSUT(home)
        let entries = [Self.entry("gpt", color: .magenta), Self.entry("work")]
        try sut.regenerate(entries: entries)

        #expect(try read(sut.scriptPath) == TerminalIntegrationGenerator.zshScript(for: entries))
        #expect(try permissions(sut.scriptPath) == 0o644)
        #expect(try permissions(sut.pendingDirectory) == 0o700)
        #expect(tabConfigFiles(sut) == ["tokeneater_gpt.toml", "tokeneater_work.toml"])
        let gptConfig = sut.tabConfigDirectory + "/tokeneater_gpt.toml"
        #expect(try read(gptConfig) == TerminalIntegrationGenerator.warpTabConfig(for: entries[0]))
        #expect(try permissions(gptConfig) == 0o644)
    }

    @Test("regenerate is repeatable and rewrites changed content")
    func regenerateTwice() throws {
        let home = try TempHome()
        let sut = makeSUT(home)
        try sut.regenerate(entries: [Self.entry("gpt", color: .red)])
        try sut.regenerate(entries: [Self.entry("gpt", color: .red)])
        let recoloured = Self.entry("gpt", color: .yellow)
        try sut.regenerate(entries: [recoloured])

        #expect(try read(sut.tabConfigDirectory + "/tokeneater_gpt.toml").contains("color = \"yellow\""))
        #expect(tabConfigFiles(sut) == ["tokeneater_gpt.toml"])
    }

    @Test("An existing pending directory is tightened to 0700")
    func pendingDirectoryPermissions() throws {
        let home = try TempHome()
        let sut = makeSUT(home)
        try fm.createDirectory(atPath: sut.pendingDirectory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o755])
        try sut.regenerate(entries: [])
        #expect(try permissions(sut.pendingDirectory) == 0o700)
    }

    @Test("Without ~/.warp only the script is written")
    func regenerateWithoutWarp() throws {
        let home = try TempHome(withWarp: false)
        let sut = makeSUT(home)
        try sut.regenerate(entries: [Self.entry("gpt")])

        #expect(fm.fileExists(atPath: sut.scriptPath))
        #expect(!fm.fileExists(atPath: home.path + "/.warp"))
    }

    @Test("Stale generated Tab Configs are pruned; the user's own files are kept")
    func regeneratePrunesOnlyMarkedFiles() throws {
        let home = try TempHome()
        let sut = makeSUT(home)
        try sut.regenerate(entries: [Self.entry("old"), Self.entry("gpt")])
        let dir = sut.tabConfigDirectory
        // Same prefix but written by the user (no marker on the first line).
        try Data("name = \"mine\"\n# Generated by TokenEater\n".utf8).write(to: URL(fileURLWithPath: dir + "/tokeneater_mine.toml"))
        // Marker present but not one of ours by name.
        try Data("# Generated by TokenEater\n".utf8).write(to: URL(fileURLWithPath: dir + "/other.toml"))
        try Data("# Generated by TokenEater\n".utf8).write(to: URL(fileURLWithPath: dir + "/tokeneater_notes.txt"))
        // A directory that merely looks like a generated file.
        try fm.createDirectory(atPath: dir + "/tokeneater_folder.toml", withIntermediateDirectories: true)

        // "old" renamed to "new".
        try sut.regenerate(entries: [Self.entry("new"), Self.entry("gpt")])

        #expect(tabConfigFiles(sut) == [
            "other.toml", "tokeneater_folder.toml", "tokeneater_gpt.toml",
            "tokeneater_mine.toml", "tokeneater_new.toml", "tokeneater_notes.txt",
        ])
    }

    @Test("Entries whose name is not a valid slug are skipped everywhere")
    func regenerateSkipsInvalidNames() throws {
        let home = try TempHome()
        let sut = makeSUT(home)
        let evil = Self.entry("../../evil")
        try sut.regenerate(entries: [evil, Self.entry("gpt")])

        #expect(tabConfigFiles(sut) == ["tokeneater_gpt.toml"])
        #expect(!fm.fileExists(atPath: home.path + "/evil.toml"))
        #expect(!fm.fileExists(atPath: home.path + "/.warp/evil.toml"))
        #expect(!(try read(sut.scriptPath)).contains("evil"))
    }

    // MARK: - removeGeneratedFiles

    @Test("removeGeneratedFiles deletes the script, handoffs and marked Tab Configs only")
    func removeGeneratedFiles() throws {
        let home = try TempHome()
        let sut = makeSUT(home)
        try sut.regenerate(entries: [Self.entry("gpt"), Self.entry("work")])
        try Data("1\n/x\n\n".utf8).write(to: URL(fileURLWithPath: sut.pendingDirectory + "/gpt"))
        let userFile = sut.tabConfigDirectory + "/tokeneater_mine.toml"
        try Data("name = \"mine\"\n".utf8).write(to: URL(fileURLWithPath: userFile))

        try sut.removeGeneratedFiles()

        #expect(!fm.fileExists(atPath: sut.scriptPath))
        #expect(!fm.fileExists(atPath: sut.pendingDirectory))
        #expect(tabConfigFiles(sut) == ["tokeneater_mine.toml"])
    }

    @Test("removeGeneratedFiles succeeds when nothing was generated")
    func removeGeneratedFilesWhenEmpty() throws {
        let home = try TempHome(withWarp: false)
        try makeSUT(home).removeGeneratedFiles()
    }

    // MARK: - ~/.zshrc

    @Test("No ~/.zshrc: .noZshrc, and install creates it with the block")
    func installCreatesZshrc() throws {
        let home = try TempHome()
        let sut = makeSUT(home)
        #expect(sut.shellIntegrationStatus() == .noZshrc)

        try sut.installShellIntegration()

        #expect(sut.shellIntegrationStatus() == .installed)
        #expect(try read(sut.zshrcPath) == """
        # >>> TokenEater terminal accounts >>>
        [[ -f "$HOME/.config/tokeneater/claude-accounts.zsh" ]] && source "$HOME/.config/tokeneater/claude-accounts.zsh"
        # <<< TokenEater terminal accounts <<<

        """)
    }

    @Test("install appends once after a blank line; uninstall restores the file byte for byte")
    func installUninstallRoundTrip() throws {
        let home = try TempHome()
        let sut = makeSUT(home)
        let original = "export PATH=\"$HOME/bin:$PATH\"\nalias ll='ls -l'\n"
        try Data(original.utf8).write(to: URL(fileURLWithPath: sut.zshrcPath))
        #expect(sut.shellIntegrationStatus() == .notInstalled)

        try sut.installShellIntegration()
        try sut.installShellIntegration()

        let installed = try read(sut.zshrcPath)
        #expect(installed == original + "\n" + TerminalIntegrationService.zshrcBlock + "\n")
        #expect(installed.components(separatedBy: TerminalIntegrationService.zshrcBlockStart).count == 2)
        #expect(sut.shellIntegrationStatus() == .installed)

        try sut.uninstallShellIntegration()
        #expect(try read(sut.zshrcPath) == original)
        #expect(sut.shellIntegrationStatus() == .notInstalled)

        try sut.uninstallShellIntegration()
        #expect(try read(sut.zshrcPath) == original)
    }

    @Test("A ~/.zshrc without a final newline gets one before the blank line")
    func installWithoutTrailingNewline() throws {
        let home = try TempHome()
        let sut = makeSUT(home)
        try Data("export A=1".utf8).write(to: URL(fileURLWithPath: sut.zshrcPath))
        try sut.installShellIntegration()
        #expect(try read(sut.zshrcPath) == "export A=1\n\n" + TerminalIntegrationService.zshrcBlock + "\n")
        try sut.uninstallShellIntegration()
        #expect(try read(sut.zshrcPath) == "export A=1\n")
    }

    @Test("uninstall removes only the block, wherever it sits, and keeps its permissions")
    func uninstallKeepsSurroundings() throws {
        let home = try TempHome()
        let sut = makeSUT(home)
        let content = "a=1\n\n" + TerminalIntegrationService.zshrcBlock + "\nb=2\n"
        try Data(content.utf8).write(to: URL(fileURLWithPath: sut.zshrcPath))
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sut.zshrcPath)

        try sut.uninstallShellIntegration()

        #expect(try read(sut.zshrcPath) == "a=1\nb=2\n")
        #expect(try permissions(sut.zshrcPath) == 0o600)
    }

    @Test("A half-deleted block is not reported as installed nor stripped")
    func incompleteBlock() throws {
        let home = try TempHome()
        let sut = makeSUT(home)
        let content = "a=1\n" + TerminalIntegrationService.zshrcBlockStart + "\nb=2\n"
        try Data(content.utf8).write(to: URL(fileURLWithPath: sut.zshrcPath))
        #expect(sut.shellIntegrationStatus() == .notInstalled)

        try sut.uninstallShellIntegration()
        #expect(try read(sut.zshrcPath) == content)
    }

    @Test("uninstall without ~/.zshrc does nothing")
    func uninstallWithoutZshrc() throws {
        let home = try TempHome()
        let sut = makeSUT(home)
        try sut.uninstallShellIntegration()
        #expect(!fm.fileExists(atPath: sut.zshrcPath))
    }

    @Test("A symlinked ~/.zshrc stays a symlink; its target gets the block")
    func installThroughSymlink() throws {
        let home = try TempHome()
        let sut = makeSUT(home)
        let target = home.path + "/dotfiles-zshrc"
        try Data("export A=1\n".utf8).write(to: URL(fileURLWithPath: target))
        try fm.createSymbolicLink(atPath: sut.zshrcPath, withDestinationPath: target)

        try sut.installShellIntegration()

        #expect(try fm.destinationOfSymbolicLink(atPath: sut.zshrcPath) == target)
        #expect(try read(target).contains(TerminalIntegrationService.zshrcBlockStart))
        #expect(sut.shellIntegrationStatus() == .installed)
    }
}
