import Testing
import Foundation

@Suite("TerminalTokenStore")
struct TerminalTokenStoreTests {

    private static let account = "tester"
    private static let profileID = UUID(uuidString: "6F1C2B9E-0D7A-4C1B-9E3F-2A4B5C6D7E8F")!
    private static let service = "TokenEater terminal token: 6F1C2B9E-0D7A-4C1B-9E3F-2A4B5C6D7E8F"
    private static let token = "sk-ant-oat01-Zq3vR8kT2mW9pL4xN7cB1hJ6yF0dS5gA-Ue_Io8"

    /// Records every spawn the store asks for.
    private final class Recorder: @unchecked Sendable {
        struct Run {
            let executable: String
            let arguments: [String]
            let stdin: Data?
            let timeout: TimeInterval
        }
        var runs: [Run] = []
        var stdinText: String? { runs.first?.stdin.map { String(decoding: $0, as: UTF8.self) } }
    }

    private typealias Responder = @Sendable (_ run: Recorder.Run) throws -> TerminalTokenStore.ProcessRunResult

    private static let success: Responder = { _ in
        TerminalTokenStore.ProcessRunResult(status: 0, stdout: Data(), stderr: "")
    }

    private static func exiting(_ status: Int32, stderr: String = "") -> Responder {
        { _ in TerminalTokenStore.ProcessRunResult(status: status, stdout: Data(), stderr: stderr) }
    }

    private func makeSUT(
        account: String = Self.account,
        respond: @escaping Responder = Self.success
    ) -> (sut: TerminalTokenStore, recorder: Recorder) {
        let recorder = Recorder()
        let sut = TerminalTokenStore(account: account, runner: { executable, arguments, stdin, timeout in
            let run = Recorder.Run(executable: executable, arguments: arguments, stdin: stdin, timeout: timeout)
            recorder.runs.append(run)
            return try respond(run)
        })
        return (sut, recorder)
    }

    /// Independent of the store's encoder on purpose.
    private static func hex(_ string: String) -> String {
        string.utf8.map { String(format: "%02x", $0) }.joined()
    }

    private static func string(fromHex hex: String) -> String? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    /// The `-X` value of the command written on stdin.
    private static func hexArgument(in command: String) -> String? {
        command.trimmingCharacters(in: .newlines).components(separatedBy: " -X ").last
    }

    /// The `-l` value of the command written on stdin, unquoted.
    private static func labelArgument(in command: String) -> String? {
        guard let start = command.range(of: " -l \""), let end = command.range(of: "\" -X ") else { return nil }
        return String(command[start.upperBound..<end.lowerBound])
    }

    /// The message of a `.writeFailed`, nil when `body` succeeds or throws anything else.
    private func writeFailure(_ body: () throws -> Void) -> String? {
        do {
            try body()
            return nil
        } catch TerminalTokenStoreError.writeFailed(let message) {
            return message
        } catch {
            return nil
        }
    }

    // MARK: - save: command

    @Test("save runs security -i and writes exactly the add-generic-password line on stdin")
    func saveWritesCommandOnStdin() throws {
        let (sut, recorder) = makeSUT()
        try sut.save(token: Self.token, profileID: Self.profileID, profileName: "Work")

        #expect(recorder.runs.count == 1)
        let run = try #require(recorder.runs.first)
        #expect(run.executable == "/usr/bin/security")
        #expect(run.arguments == ["-i"])
        #expect(run.timeout == 5)
        #expect(recorder.stdinText == """
        add-generic-password -U -a "tester" -s "\(Self.service)" -l "TokenEater terminal token (Work)" -X \(Self.hex(Self.token))\n
        """)
    }

    @Test("the token and its hex never appear in argv")
    func secretNeverInArgv() throws {
        let (sut, recorder) = makeSUT()
        try sut.save(token: Self.token, profileID: Self.profileID, profileName: "Work")

        let hex = Self.hex(Self.token)
        let body = String(Self.token.dropFirst(TerminalTokenFormat.prefix.count))
        for run in recorder.runs {
            for argument in [run.executable] + run.arguments {
                #expect(!argument.contains(Self.token))
                #expect(!argument.contains(body))
                #expect(!argument.contains(hex))
                #expect(!argument.contains(hex.uppercased()))
            }
        }
        // ...it travels on stdin instead.
        #expect(recorder.stdinText?.contains(hex) == true)
    }

    @Test("the -X value is the lowercase hex of the token's UTF-8 bytes")
    func hexEncoding() throws {
        let (sut, recorder) = makeSUT()
        try sut.save(token: Self.token, profileID: Self.profileID, profileName: "Work")

        let command = try #require(recorder.stdinText)
        let hex = try #require(Self.hexArgument(in: command))
        #expect(hex.hasPrefix("736b2d616e742d6f617430312d"))   // "sk-ant-oat01-"
        #expect(hex == hex.lowercased())
        #expect(Self.string(fromHex: hex) == Self.token)
        #expect(TerminalTokenStore.hexString(Data([0x00, 0xab, 0xff, 0x7b])) == "00abff7b")
    }

    @Test("save trims surrounding whitespace before hex-encoding")
    func saveTrimsToken() throws {
        let (sut, recorder) = makeSUT()
        try sut.save(token: "  \n\t\(Self.token) \r\n", profileID: Self.profileID, profileName: "Work")

        let command = try #require(recorder.stdinText)
        let hex = try #require(Self.hexArgument(in: command))
        #expect(hex == Self.hex(Self.token))
    }

    @Test("an implausible token throws and never spawns a process", arguments: [
        "",
        "   ",
        "hello",
        "sk-ant-oat01-short",
        "sk-ant-api03-Zq3vR8kT2mW9pL4xN7cB1hJ6yF0dS5gA-Ue_Io8",
        "sk-ant-oat01-Zq3vR8kT2mW9pL4x N7cB1hJ6yF0dS5gA-Ue_Io8",
        "sk-ant-oat01-Zq3vR8kT2mW9pL4x\nN7cB1hJ6yF0dS5gA-Ue_Io8",
    ])
    func implausibleTokenThrows(token: String) {
        let (sut, recorder) = makeSUT()
        #expect(throws: TerminalTokenStoreError.implausibleToken) {
            try sut.save(token: token, profileID: Self.profileID, profileName: "Work")
        }
        #expect(recorder.runs.isEmpty)
    }

    // MARK: - save: label

    @Test("the label drops quotes, backslashes, control characters and line breaks")
    func labelSanitising() throws {
        let (sut, recorder) = makeSUT()
        try sut.save(token: Self.token, profileID: Self.profileID,
                     profileName: "Ac\"me\" \\Labs\n\tTeam\u{07}\r\u{2028}!")

        let command = try #require(recorder.stdinText)
        #expect(Self.labelArgument(in: command) == "TokenEater terminal token (Acme LabsTeam!)")
        // One command line, so one trailing newline and no other.
        #expect(command.filter(\.isNewline).count == 1)
        #expect(command.hasSuffix("\n"))
    }

    @Test("the label keeps apostrophes, $, #, accents and emoji")
    func labelKeepsOtherCharacters() throws {
        let name = "O'Brien $HOME #1 Gérard 日本 🚀"
        let (sut, recorder) = makeSUT()
        try sut.save(token: Self.token, profileID: Self.profileID, profileName: name)

        let command = try #require(recorder.stdinText)
        #expect(Self.labelArgument(in: command) == "TokenEater terminal token (\(name))")
    }

    @Test("a name with nothing printable left yields the bare label; a long one is capped")
    func labelEdgeCases() {
        #expect(TerminalTokenStore.label(forProfileName: "\"\\\n\t") == "TokenEater terminal token")
        #expect(TerminalTokenStore.label(forProfileName: "") == "TokenEater terminal token")
        let long = String(repeating: "x", count: 200)
        #expect(TerminalTokenStore.label(forProfileName: long)
                == "TokenEater terminal token (\(String(repeating: "x", count: TerminalTokenStore.maxLabelNameLength)))")
    }

    // MARK: - save: guards

    @Test("an account that cannot be quoted for security -i fails before spawning")
    func unsafeAccountFails() {
        for account in ["te\"ster", "te\\ster", "te\nster"] {
            let (sut, recorder) = makeSUT(account: account)
            #expect(writeFailure { try sut.save(token: Self.token, profileID: Self.profileID, profileName: "Work") } != nil)
            #expect(recorder.runs.isEmpty)
        }
    }

    @Test("a command too long for the security -i line buffer fails before spawning")
    func oversizedCommandFails() throws {
        // Plausible by shape, but its hex alone overflows the line buffer: a
        // split line would store a truncated secret.
        let huge = TerminalTokenFormat.prefix + String(repeating: "A", count: 2_100)
        let (sut, recorder) = makeSUT()
        let message = writeFailure { try sut.save(token: huge, profileID: Self.profileID, profileName: "Work") }
        #expect(message?.contains("too long") == true)
        #expect(recorder.runs.isEmpty)

        // A realistic token with a long name stays well within the limit.
        let (ok, okRecorder) = makeSUT()
        try ok.save(token: Self.token, profileID: Self.profileID, profileName: String(repeating: "é", count: 500))
        let command = try #require(okRecorder.stdinText)
        #expect(command.utf8.count <= TerminalTokenStore.maxCommandLineBytes)
    }

    // MARK: - save: failures

    @Test("a non-zero exit is writeFailed carrying stderr")
    func nonZeroExitFails() {
        let stderr = "security: SecKeychainItemCreateFromContent (<default>): User interaction is not allowed.\nadd-generic-password: returned -25308"
        let (sut, _) = makeSUT(respond: Self.exiting(51, stderr: stderr + "\n"))
        #expect(writeFailure { try sut.save(token: Self.token, profileID: Self.profileID, profileName: "Work") } == stderr)
    }

    @Test("a non-zero exit with nothing on stderr reports the status")
    func nonZeroExitWithoutStderr() {
        let (sut, _) = makeSUT(respond: Self.exiting(44))
        #expect(writeFailure { try sut.save(token: Self.token, profileID: Self.profileID, profileName: "Work") }
                == "security exited with 44")
    }

    @Test("exit 0 with an error on stderr still fails (security -i reports the status of its last line)")
    func zeroExitWithStderrFails() {
        let stderr = "security: SecKeychainItemModifyContent: The user name or passphrase you entered is not correct.\nadd-generic-password: returned -25293"
        let (sut, _) = makeSUT(respond: Self.exiting(0, stderr: stderr))
        #expect(writeFailure { try sut.save(token: Self.token, profileID: Self.profileID, profileName: "Work") } == stderr)
    }

    @Test("exit 0 with only whitespace on stderr succeeds")
    func zeroExitWithBlankStderrSucceeds() throws {
        let (sut, _) = makeSUT(respond: Self.exiting(0, stderr: " \n"))
        try sut.save(token: Self.token, profileID: Self.profileID, profileName: "Work")
    }

    @Test("a timeout or a launch error is writeFailed")
    func runnerErrorsFail() {
        let (timedOut, _) = makeSUT(respond: { _ in throw TerminalTokenStore.ProcessRunError.timedOut })
        let timeoutMessage = writeFailure { try timedOut.save(token: Self.token, profileID: Self.profileID, profileName: "Work") }
        #expect(timeoutMessage?.contains("timed out") == true)

        let (unlaunchable, _) = makeSUT(respond: { _ in throw TerminalTokenStore.ProcessRunError.launchFailed("no such file") })
        let launchMessage = writeFailure { try unlaunchable.save(token: Self.token, profileID: Self.profileID, profileName: "Work") }
        #expect(launchMessage?.contains("launch failed") == true)
    }

    // MARK: - exists / delete

    @Test("exists looks the item up by account and service, without -w")
    func existsArguments() throws {
        let (sut, recorder) = makeSUT()
        #expect(sut.exists(profileID: Self.profileID))

        let run = try #require(recorder.runs.first)
        #expect(run.executable == "/usr/bin/security")
        #expect(run.arguments == ["find-generic-password", "-a", "tester", "-s", Self.service])
        #expect(run.stdin == nil)
    }

    @Test("exists is false on a non-zero exit or a runner error")
    func existsFalse() {
        #expect(!makeSUT(respond: Self.exiting(44)).sut.exists(profileID: Self.profileID))
        #expect(!makeSUT(respond: { _ in throw TerminalTokenStore.ProcessRunError.timedOut }).sut.exists(profileID: Self.profileID))
    }

    @Test("delete removes the item by account and service and ignores errors")
    func deleteArguments() throws {
        let (sut, recorder) = makeSUT(respond: Self.exiting(44, stderr: "The specified item could not be found in the keychain."))
        sut.delete(profileID: Self.profileID)

        let run = try #require(recorder.runs.first)
        #expect(recorder.runs.count == 1)
        #expect(run.executable == "/usr/bin/security")
        #expect(run.arguments == ["delete-generic-password", "-a", "tester", "-s", Self.service])
        #expect(run.stdin == nil)

        makeSUT(respond: { _ in throw TerminalTokenStore.ProcessRunError.launchFailed("x") }).sut.delete(profileID: Self.profileID)
    }

    // MARK: - Real process runner (no Keychain)

    @Test("runProcess feeds stdin to the child and returns its stdout")
    func runProcessPipesStdin() throws {
        let input = Data("add-generic-password -X 00ff\n".utf8)
        let result = try TerminalTokenStore.runProcess(executable: "/bin/cat", arguments: [], stdin: input, timeout: 5)
        #expect(result.status == 0)
        #expect(result.stdout == input)
        #expect(result.stderr.isEmpty)
    }

    @Test("runProcess without input gives the child an empty stdin instead of the caller's")
    func runProcessNilStdin() throws {
        let result = try TerminalTokenStore.runProcess(executable: "/bin/cat", arguments: [], stdin: nil, timeout: 5)
        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)
    }

    @Test("runProcess reports the exit status and trimmed stderr")
    func runProcessStatusAndStderr() throws {
        let result = try TerminalTokenStore.runProcess(
            executable: "/bin/sh", arguments: ["-c", "echo out; echo oops >&2; exit 3"], stdin: nil, timeout: 5
        )
        #expect(result.status == 3)
        #expect(result.stdout == Data("out\n".utf8))
        #expect(result.stderr == "oops")
    }

    @Test("runProcess survives a child that exits without reading its stdin")
    func runProcessChildIgnoresStdin() throws {
        let result = try TerminalTokenStore.runProcess(
            executable: "/usr/bin/true", arguments: [], stdin: Data(repeating: 0x61, count: 256 * 1024), timeout: 5
        )
        #expect(result.status == 0)
    }

    @Test("runProcess terminates a child that outlives the timeout")
    func runProcessTimeout() {
        let start = Date()
        #expect(throws: TerminalTokenStore.ProcessRunError.timedOut) {
            try TerminalTokenStore.runProcess(executable: "/bin/sleep", arguments: ["10"], stdin: nil, timeout: 0.3)
        }
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test("runProcess reports a launch failure")
    func runProcessLaunchFailure() {
        #expect(throws: TerminalTokenStore.ProcessRunError.self) {
            try TerminalTokenStore.runProcess(
                executable: "/nonexistent/tokeneater-security", arguments: [], stdin: nil, timeout: 5
            )
        }
    }

    // MARK: - Real Keychain (opt-in)

    /// Writes, reads back, replaces and deletes a real login-Keychain item.
    /// Skipped unless `TOKENEATER_KEYCHAIN_TESTS=1` (through xcodebuild:
    /// `TEST_RUNNER_TOKENEATER_KEYCHAIN_TESTS=1 xcodebuild … test`). Needs an
    /// unlocked login Keychain; the item is removed even when an expectation fails.
    @Test(
        "real Keychain round trip through /usr/bin/security",
        .enabled(if: ProcessInfo.processInfo.environment["TOKENEATER_KEYCHAIN_TESTS"] == "1",
                 "set TOKENEATER_KEYCHAIN_TESTS=1 to touch the real login Keychain")
    )
    func realKeychainRoundTrip() throws {
        let profileID = UUID()
        let service = TerminalTokenKeychain.service(for: profileID)
        let sut = TerminalTokenStore()
        defer { sut.delete(profileID: profileID) }

        func readSecret() throws -> String {
            let result = try TerminalTokenStore.runProcess(
                executable: "/usr/bin/security",
                arguments: ["find-generic-password", "-a", NSUserName(), "-s", service, "-w"],
                stdin: nil, timeout: 5
            )
            #expect(result.status == 0, "find-generic-password -w: \(result.stderr)")
            return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func randomToken() -> String {
            let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
            return TerminalTokenFormat.prefix + String((0..<95).map { _ in alphabet.randomElement()! })
        }

        #expect(!sut.exists(profileID: profileID))

        let first = randomToken()
        try sut.save(token: first, profileID: profileID, profileName: "Round \"trip\" O'Brien")
        #expect(sut.exists(profileID: profileID))
        #expect(try readSecret() == first)

        let attributes = try TerminalTokenStore.runProcess(
            executable: "/usr/bin/security",
            arguments: ["find-generic-password", "-a", NSUserName(), "-s", service],
            stdin: nil, timeout: 5
        )
        let listing = String(decoding: attributes.stdout, as: UTF8.self) + attributes.stderr
        #expect(listing.contains("TokenEater terminal token (Round trip O'Brien)"))

        // -U replaces the secret of the existing item.
        let second = randomToken()
        try sut.save(token: second, profileID: profileID, profileName: "Round trip")
        #expect(try readSecret() == second)

        sut.delete(profileID: profileID)
        #expect(!sut.exists(profileID: profileID))
    }
}
