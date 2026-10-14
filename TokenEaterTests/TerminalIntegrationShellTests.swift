import Testing
import Foundation

/// Runs the generated `cla` / `claw` script under a real `/bin/zsh` in a
/// throwaway home. Every external program the script calls is a stub selected
/// through the `TOKENEATER_*_BIN` overrides, so nothing touches the real
/// Keychain, `~/.claude.json`, Claude Code or Warp.
///
/// Stubs (zsh scripts, `zsh -f` so no rc file runs):
/// - `security`: answers with `STUB_TOKEN` (only for `STUB_TOKEN_SERVICE` when
///   set), exit 44 (item not found) otherwise; logs its argv.
/// - `plutil`: prints `STUB_LIVE` as the signed-in account UUID.
/// - `claude`: records whether `CLAUDE_CODE_OAUTH_TOKEN` is set, its physical
///   working directory and every argument, NUL-separated.
/// - `open`: logs the URL, exits with `STUB_OPEN_STATUS`.
final class TerminalShellSandbox {
    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// What the stub `claude` saw.
    struct ClaudeRun: Equatable {
        /// nil when `CLAUDE_CODE_OAUTH_TOKEN` was not in its environment.
        let token: String?
        let directory: String
        let arguments: [String]
    }

    let root: String
    let home: String
    let project: String
    let bin: String
    let logs: String
    let pendingDirectory: String
    let scriptPath: String
    let driverPath: String

    init(entries: [TerminalAccountEntry]) throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("te-shell-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        // Physical path (/private/var/...), which is what `pwd -P` reports.
        root = Self.realPath(base.path)
        home = root + "/home"
        project = root + "/project with 'quotes' $dollar"
        bin = root + "/bin"
        logs = root + "/logs"
        pendingDirectory = home + "/.config/tokeneater/pending"
        scriptPath = root + "/claude-accounts.zsh"
        driverPath = root + "/driver.zsh"
        for dir in [home, project, bin, logs] {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        try write(TerminalIntegrationGenerator.zshScript(for: entries), to: scriptPath)
        try writeStubs()
        // Sources the script like ~/.zshrc would, runs the command given as
        // arguments, then records what is left in the calling shell.
        try write(#"""
        source "$TE_SCRIPT" || exit 99
        "$@"
        te_rc=$?
        print -r -- "${+CLAUDE_CODE_OAUTH_TOKEN}:${CLAUDE_CODE_OAUTH_TOKEN:-}|${+token}|${+name}|${+stored}|${+pending}" > "$STUB_LOG/after"
        exit $te_rc

        """#, to: driverPath)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: root)
    }

    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: - Running

    /// Runs `zsh -f driver.zsh <arguments…>` with a minimal environment
    /// (nothing inherited from the test runner, which may itself run inside
    /// Claude Code with its own `CLAUDE_*` variables).
    @discardableResult
    func run(
        _ arguments: [String],
        in directory: String? = nil,
        token: String? = nil,
        tokenService: String? = nil,
        liveAccount: String? = nil,
        environment extra: [String: String] = [:],
        driver: String? = nil
    ) throws -> Result {
        var env: [String: String] = [
            "PATH": "/usr/bin:/bin",
            "HOME": home,
            "USER": "tester",
            "LANG": "en_US.UTF-8",
            "TE_SCRIPT": scriptPath,
            "STUB_LOG": logs,
            "TOKENEATER_SECURITY_BIN": bin + "/security",
            "TOKENEATER_PLUTIL_BIN": bin + "/plutil",
            "TOKENEATER_CLAUDE_BIN": bin + "/claude",
            "TOKENEATER_OPEN_BIN": bin + "/open",
            "TOKENEATER_PENDING_DIR": pendingDirectory,
        ]
        if let token { env["STUB_TOKEN"] = token }
        if let tokenService { env["STUB_TOKEN_SERVICE"] = tokenService }
        if let liveAccount { env["STUB_LIVE"] = liveAccount }
        env.merge(extra) { _, new in new }

        let stdoutPath = root + "/stdout", stderrPath = root + "/stderr"
        FileManager.default.createFile(atPath: stdoutPath, contents: nil)
        FileManager.default.createFile(atPath: stderrPath, contents: nil)
        let stdout = try FileHandle(forWritingTo: URL(fileURLWithPath: stdoutPath))
        let stderr = try FileHandle(forWritingTo: URL(fileURLWithPath: stderrPath))
        defer { try? stdout.close(); try? stderr.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", driver ?? driverPath] + arguments
        process.environment = env
        process.currentDirectoryURL = URL(fileURLWithPath: directory ?? root)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let deadline = Date().addingTimeInterval(20)
        while process.isRunning && Date() < deadline { usleep(10_000) }
        if process.isRunning {
            process.terminate()
            Issue.record("zsh did not finish within 20 s: \(arguments)")
        }
        process.waitUntilExit()
        return Result(
            status: process.terminationStatus,
            stdout: (try? String(contentsOfFile: stdoutPath, encoding: .utf8)) ?? "",
            stderr: (try? String(contentsOfFile: stderrPath, encoding: .utf8)) ?? ""
        )
    }

    /// The last `claude` stub run, nil when Claude was not started.
    func claudeRun() -> ClaudeRun? {
        guard let data = FileManager.default.contents(atPath: logs + "/claude.out") else { return nil }
        var fields = String(decoding: data, as: UTF8.self).components(separatedBy: "\0")
        if fields.last == "" { fields.removeLast() }
        guard fields.count >= 2 else { return nil }
        let token = fields[0].hasPrefix("TOKEN=") ? String(fields[0].dropFirst("TOKEN=".count)) : nil
        return ClaudeRun(
            token: token,
            directory: String(fields[1].dropFirst("PWD=".count)),
            arguments: Array(fields.dropFirst(2))
        )
    }

    /// Lines a stub logged (`security`, `plutil`, `open`), empty when never run.
    func log(_ stub: String) -> [String] {
        guard let text = try? String(contentsOfFile: logs + "/\(stub).log", encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    /// `set:value|token|name|stored|pending` as seen by the calling shell after the command.
    func shellStateAfter() -> String {
        ((try? String(contentsOfFile: logs + "/after", encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .newlines)
    }

    func resetLogs() throws {
        let fm = FileManager.default
        try fm.removeItem(atPath: logs)
        try fm.createDirectory(atPath: logs, withIntermediateDirectories: true)
    }

    func write(_ content: String, to path: String, executable: Bool = false) throws {
        try Data(content.utf8).write(to: URL(fileURLWithPath: path))
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
    }

    private func writeStubs() throws {
        try write(#"""
        #!/bin/zsh -f
        print -r -- "$*" >> "$STUB_LOG/security.log"
        [[ -n ${STUB_TOKEN:-} ]] || exit 44
        typeset -i s=${@[(Ie)-s]}
        if [[ -n ${STUB_TOKEN_SERVICE:-} && ${@[s+1]} != "$STUB_TOKEN_SERVICE" ]]; then
          exit 44
        fi
        (( ${@[(Ie)-w]} )) && print -r -- "$STUB_TOKEN"
        exit 0

        """#, to: bin + "/security", executable: true)
        try write(#"""
        #!/bin/zsh -f
        print -r -- "$*" >> "$STUB_LOG/plutil.log"
        [[ -n ${STUB_LIVE:-} ]] || exit 1
        print -r -- "$STUB_LIVE"

        """#, to: bin + "/plutil", executable: true)
        try write(#"""
        #!/bin/zsh -f
        {
          if (( ${+CLAUDE_CODE_OAUTH_TOKEN} )); then
            print -rN -- "TOKEN=$CLAUDE_CODE_OAUTH_TOKEN"
          else
            print -rN -- "NO-TOKEN"
          fi
          print -rN -- "PWD=$(/bin/pwd -P)" "$@"
        } > "$STUB_LOG/claude.out"

        """#, to: bin + "/claude", executable: true)
        try write(#"""
        #!/bin/zsh -f
        print -r -- "$*" >> "$STUB_LOG/open.log"
        exit ${STUB_OPEN_STATUS:-0}

        """#, to: bin + "/open", executable: true)
    }
}

@Suite("Terminal integration zsh behaviour")
struct TerminalIntegrationShellTests {

    private static let gptID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private static let workID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    private static let gpt = TerminalAccountEntry(
        name: "gpt",
        profileID: gptID,
        profileName: "GPT shared",
        accountUUID: "acc-gpt",
        warpColor: .magenta,
        keychainService: TerminalTokenKeychain.service(for: gptID)
    )
    /// Free-text profile name full of shell syntax: it must only ever be printed.
    private static let work = TerminalAccountEntry(
        name: "work",
        profileID: workID,
        profileName: #"O'Brien "$HOME" `touch pwned` $(touch pwned) \ *"#,
        accountUUID: nil,
        warpColor: .green,
        keychainService: TerminalTokenKeychain.service(for: workID)
    )

    /// Arguments that break naive quoting.
    private static let trickyArguments = [
        "--resume", "a b", "", "it's", #""double""#, "$HOME", "*", "`id`", "$(id)", #"back\slash"#, "new\nline", "--",
    ]

    private static let token = "sk-ant-oat01-test-token-0123456789abcdefghijklmnop"

    private func makeSandbox() throws -> TerminalShellSandbox {
        try TerminalShellSandbox(entries: [Self.gpt, Self.work])
    }

    /// `~/.claude.json` must exist for `cla` to ask `plutil` about it.
    private func writeGlobalConfig(_ sandbox: TerminalShellSandbox, in dir: String? = nil) throws {
        try sandbox.write("{}", to: (dir ?? sandbox.home) + "/.claude.json")
    }

    // MARK: - cla with a terminal token

    @Test("A stored token reaches claude as CLAUDE_CODE_OAUTH_TOKEN with every argument unchanged")
    func tokenAndArguments() throws {
        let sandbox = try makeSandbox()
        let result = try sandbox.run(["cla", "gpt"] + Self.trickyArguments, token: Self.token)

        #expect(result.status == 0)
        #expect(result.stderr.isEmpty)
        let run = try #require(sandbox.claudeRun())
        #expect(run.token == Self.token)
        #expect(run.arguments == Self.trickyArguments)
        #expect(run.directory == sandbox.root)
        // The Keychain lookup is for this account's item, by the macOS user.
        let lookup = try #require(sandbox.log("security").last)
        #expect(lookup == "find-generic-password -a tester -s \(Self.gpt.keychainService) -w")
        // Nothing to print in a pipe: the OSC title only goes to a terminal.
        #expect(!result.stdout.contains("\u{1B}]0;"))
    }

    @Test("Claude's exit status is cla's")
    func exitStatusPropagates() throws {
        let sandbox = try makeSandbox()
        try sandbox.write("#!/bin/zsh -f\nexit 7\n", to: sandbox.bin + "/claude", executable: true)
        #expect(try sandbox.run(["cla", "gpt"], token: Self.token).status == 7)
    }

    @Test("The token never stays in the calling shell, not even as a local")
    func tokenDoesNotLeak() throws {
        let sandbox = try makeSandbox()
        try sandbox.run(["cla", "gpt", "-p", "hi"], token: Self.token)
        #expect(sandbox.claudeRun()?.token == Self.token)
        #expect(sandbox.shellStateAfter() == "0:|0|0|0|0")
    }

    @Test("A token exported in the shell is overridden for claude and left as it was")
    func exportedTokenIsOverriddenNotChanged() throws {
        let sandbox = try makeSandbox()
        try sandbox.run(["cla", "gpt"], token: Self.token, environment: ["CLAUDE_CODE_OAUTH_TOKEN": "outer"])
        #expect(sandbox.claudeRun()?.token == Self.token)
        #expect(sandbox.shellStateAfter() == "1:outer|0|0|0|0")
    }

    // MARK: - cla without a terminal token

    @Test("No token, but the account is signed in to ~/.claude: plain claude without the variable")
    func liveAccountFallback() throws {
        let sandbox = try makeSandbox()
        try writeGlobalConfig(sandbox)
        let result = try sandbox.run(["cla", "gpt", "--resume", "a b"], liveAccount: "acc-gpt")

        #expect(result.status == 0)
        let run = try #require(sandbox.claudeRun())
        #expect(run.token == nil)
        #expect(run.arguments == ["--resume", "a b"])
        #expect(sandbox.log("plutil") == ["-extract oauthAccount.accountUuid raw -o - \(sandbox.home)/.claude.json"])
    }

    @Test("The ~/.claude fallback hides a token exported in the shell from claude")
    func liveAccountFallbackHidesExportedToken() throws {
        let sandbox = try makeSandbox()
        try writeGlobalConfig(sandbox)
        try sandbox.run(["cla", "gpt"], liveAccount: "acc-gpt", environment: ["CLAUDE_CODE_OAUTH_TOKEN": "outer"])
        #expect(try #require(sandbox.claudeRun()).token == nil)
        #expect(sandbox.shellStateAfter() == "1:outer|0|0|0|0")
    }

    @Test("CLAUDE_CONFIG_DIR moves the global config cla reads")
    func liveAccountHonoursConfigDir() throws {
        let sandbox = try makeSandbox()
        let configDir = sandbox.root + "/alt-config"
        try FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        try writeGlobalConfig(sandbox, in: configDir)
        try sandbox.run(["cla", "gpt"], liveAccount: "acc-gpt", environment: ["CLAUDE_CONFIG_DIR": configDir])

        #expect(sandbox.log("plutil") == ["-extract oauthAccount.accountUuid raw -o - \(configDir)/.claude.json"])
        #expect(sandbox.claudeRun()?.token == nil)
    }

    @Test("No token and another account in ~/.claude: error, claude never runs")
    func otherLiveAccountFails() throws {
        let sandbox = try makeSandbox()
        try writeGlobalConfig(sandbox)
        let result = try sandbox.run(["cla", "gpt", "-p", "hi"], liveAccount: "acc-someone-else")

        #expect(result.status == 1)
        #expect(result.stderr.contains("No terminal token for gpt - TokenEater → Settings → Accounts → GPT shared → Terminal"))
        #expect(sandbox.claudeRun() == nil)
    }

    @Test("No token and no known account: error naming the profile literally, nothing evaluated")
    func noTokenNoAccountFails() throws {
        let sandbox = try makeSandbox()
        try writeGlobalConfig(sandbox)
        let result = try sandbox.run(["cla", "work"], liveAccount: "acc-gpt")

        #expect(result.status == 1)
        #expect(result.stderr.contains("No terminal token for work"))
        #expect(result.stderr.contains(Self.work.profileName))
        #expect(sandbox.claudeRun() == nil)
        #expect(!FileManager.default.fileExists(atPath: sandbox.root + "/pwned"))
    }

    // MARK: - Usage and unknown accounts

    @Test("cla alone lists every account, its profile name and how it signs in")
    func usageListsAccounts() throws {
        let sandbox = try makeSandbox()
        try writeGlobalConfig(sandbox)
        let result = try sandbox.run(["cla"], token: Self.token, tokenService: Self.work.keychainService, liveAccount: "acc-gpt")

        #expect(result.status == 0)
        #expect(result.stdout.contains("Usage: cla <account>"))
        #expect(result.stdout.contains("claw [-w|--new-window] <account>"))
        let lines = result.stdout.components(separatedBy: "\n")
        let gptLine = try #require(lines.first { $0.hasPrefix("  gpt ") })
        #expect(gptLine.contains("GPT shared"))
        #expect(gptLine.contains("session of ~/.claude"))
        let workLine = try #require(lines.first { $0.hasPrefix("  work ") })
        #expect(workLine.contains(Self.work.profileName))
        #expect(workLine.contains("terminal token"))
        #expect(sandbox.claudeRun() == nil)
        #expect(!FileManager.default.fileExists(atPath: sandbox.root + "/pwned"))
    }

    @Test("-h and --help print the usage too", arguments: ["-h", "--help"])
    func helpFlags(flag: String) throws {
        let sandbox = try makeSandbox()
        let result = try sandbox.run(["cla", flag])
        #expect(result.status == 0)
        #expect(result.stdout.contains("Usage: cla <account>"))
        #expect(sandbox.claudeRun() == nil)
    }

    @Test("An unknown account prints an error and the usage, status 2", arguments: ["cla", "claw"])
    func unknownAccount(command: String) throws {
        let sandbox = try makeSandbox()
        let result = try sandbox.run([command, "nope", "--resume"], token: Self.token)

        #expect(result.status == 2)
        #expect(result.stderr.contains("\(command): unknown account 'nope'"))
        #expect(result.stderr.contains("Usage: cla <account>"))
        #expect(result.stderr.contains("  gpt "))
        #expect(sandbox.claudeRun() == nil)
        #expect(sandbox.log("open").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: sandbox.pendingDirectory + "/nope"))
    }

    // MARK: - claw

    @Test("claw writes a private handoff without the token and opens the account's Tab Config")
    func clawWritesHandoff() throws {
        let sandbox = try makeSandbox()
        let result = try sandbox.run(["claw", "gpt", "--model", "opus", "a b"], in: sandbox.project, token: Self.token)

        #expect(result.status == 0)
        #expect(sandbox.log("open") == ["warp://tab_config/tokeneater_gpt"])
        let handoffPath = sandbox.pendingDirectory + "/gpt"
        let handoff = try String(contentsOfFile: handoffPath, encoding: .utf8)
        #expect(!handoff.contains(Self.token))
        #expect(!handoff.contains("sk-ant"))
        let lines = handoff.components(separatedBy: "\n")
        #expect(lines.count == 4) // three lines + trailing newline
        let stamp = try #require(TimeInterval(lines[0]))
        #expect(abs(stamp - Date().timeIntervalSince1970) < 60)
        // claw never needs the Keychain.
        #expect(sandbox.log("security").isEmpty)
        // Private: 0700 directory, 0600 file.
        let fm = FileManager.default
        #expect((try fm.attributesOfItem(atPath: handoffPath)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((try fm.attributesOfItem(atPath: sandbox.pendingDirectory)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test("claw -w / --new-window opens the Tab Config in a new window", arguments: ["-w", "--new-window"])
    func clawNewWindow(flag: String) throws {
        let sandbox = try makeSandbox()
        let result = try sandbox.run(["claw", flag, "gpt", "-c"], in: sandbox.project)
        #expect(result.status == 0)
        #expect(sandbox.log("open") == ["warp://tab_config/tokeneater_gpt?new_window=true"])
        #expect(FileManager.default.fileExists(atPath: sandbox.pendingDirectory + "/gpt"))
    }

    @Test("A failing open removes the handoff and fails claw")
    func clawOpenFailure() throws {
        let sandbox = try makeSandbox()
        let result = try sandbox.run(["claw", "gpt"], in: sandbox.project, environment: ["STUB_OPEN_STATUS": "1"])
        #expect(result.status == 1)
        #expect(!FileManager.default.fileExists(atPath: sandbox.pendingDirectory + "/gpt"))
    }

    // MARK: - --te-pending (the Warp tab side)

    @Test("--te-pending consumes a fresh handoff: claw's directory, then its arguments, then the tab's")
    func pendingConsumesFreshHandoff() throws {
        let sandbox = try makeSandbox()
        try sandbox.run(["claw", "gpt"] + Self.trickyArguments, in: sandbox.project)
        try sandbox.resetLogs()

        let result = try sandbox.run(["cla", "gpt", "--te-pending", "--verbose"], in: sandbox.home, token: Self.token)

        #expect(result.status == 0)
        let run = try #require(sandbox.claudeRun())
        #expect(run.directory == sandbox.project)
        #expect(run.arguments == Self.trickyArguments + ["--verbose"])
        #expect(run.token == Self.token)
        #expect(!FileManager.default.fileExists(atPath: sandbox.pendingDirectory + "/gpt"))
        #expect(sandbox.shellStateAfter() == "0:|0|0|0|0")
    }

    @Test("--te-pending deletes and ignores a stale handoff, starting in the home directory")
    func pendingIgnoresStaleHandoff() throws {
        let sandbox = try makeSandbox()
        try FileManager.default.createDirectory(atPath: sandbox.pendingDirectory, withIntermediateDirectories: true)
        let stale = Int(Date().timeIntervalSince1970) - 500
        try sandbox.write("\(stale)\n\(sandbox.project)\n'old-argument'\n", to: sandbox.pendingDirectory + "/gpt")

        let result = try sandbox.run(["cla", "gpt", "--te-pending", "-c"], in: sandbox.root, token: Self.token)

        #expect(result.status == 0)
        let run = try #require(sandbox.claudeRun())
        #expect(run.directory == sandbox.home)
        #expect(run.arguments == ["-c"])
        #expect(!FileManager.default.fileExists(atPath: sandbox.pendingDirectory + "/gpt"))
    }

    @Test("--te-pending without a handoff starts plain cla in the home directory")
    func pendingWithoutHandoff() throws {
        let sandbox = try makeSandbox()
        let result = try sandbox.run(["cla", "gpt", "--te-pending"], in: sandbox.project, token: Self.token)

        #expect(result.status == 0)
        let run = try #require(sandbox.claudeRun())
        #expect(run.directory == sandbox.home)
        #expect(run.arguments.isEmpty)
    }

    @Test("A handoff is per account: another account's tab does not take it")
    func pendingIsPerAccount() throws {
        let sandbox = try makeSandbox()
        try sandbox.run(["claw", "gpt", "-c"], in: sandbox.project)
        try sandbox.run(["cla", "work", "--te-pending"], in: sandbox.root, token: Self.token)

        #expect(sandbox.claudeRun()?.arguments == [])
        #expect(FileManager.default.fileExists(atPath: sandbox.pendingDirectory + "/gpt"))
    }

    // MARK: - Robustness

    @Test("The user's shell options and aliases do not change how the functions behave")
    func hostileShellSettings() throws {
        let sandbox = try makeSandbox()
        let driver = sandbox.root + "/hostile-driver.zsh"
        try sandbox.write(#"""
        setopt ksh_arrays sh_word_split no_unset no_clobber err_return
        alias cla='print ALIAS' cd='print ALIAS' rm='rm -i' claude='print ALIAS'
        source "$TE_SCRIPT" || exit 99
        "$@"

        """#, to: driver)
        try sandbox.run(["claw", "gpt", "a b", ""], in: sandbox.project, driver: driver)
        let result = try sandbox.run(["cla", "gpt", "--te-pending", "x"], in: sandbox.home, token: Self.token, driver: driver)

        #expect(result.status == 0)
        let run = try #require(sandbox.claudeRun())
        #expect(run.directory == sandbox.project)
        #expect(run.arguments == ["a b", "", "x"])
    }

    @Test("Completion offers the accounts, then hands the rest of the line to claude's completion")
    func completion() throws {
        let sandbox = try makeSandbox()
        let driver = sandbox.root + "/completion-driver.zsh"
        try sandbox.write(#"""
        source "$TE_SCRIPT" || exit 99
        function compadd { print -r -- "compadd ${(j:,:)@}" }
        function _normal { print -r -- "normal ${(j:,:)words} $CURRENT" }
        function te_try { words=( "${@[1,-2]}" ); CURRENT=${@[-1]}; _te_cla }
        te_try cla '' 2
        te_try cla gpt --mo 3
        te_try claw -w '' 3
        te_try claw -w gpt --mo x 5

        """#, to: driver)
        let result = try sandbox.run([], driver: driver)

        #expect(result.stdout.components(separatedBy: "\n").filter { !$0.isEmpty } == [
            "compadd --,gpt,work",
            "normal claude,--mo 2",
            "compadd --,gpt,work",
            "normal claude,--mo,x 3",
        ])
    }
}
