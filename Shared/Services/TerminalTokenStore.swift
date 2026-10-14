import Foundation
import os.log

private let logger = Logger(subsystem: "com.tokeneater.app", category: "TerminalTokenStore")

/// Keeps each profile's terminal token (from `claude setup-token`) in the
/// login Keychain, one generic password per profile under
/// `TerminalTokenKeychain.service(for:)`. See `docs/terminal-accounts-plan.md`
/// §3.1.
///
/// Every operation goes through `/usr/bin/security` rather than the Security
/// framework, on purpose: a Keychain item's ACL trusts the application that
/// created it. An item created by `/usr/bin/security` can therefore be read
/// back by `/usr/bin/security find-generic-password -w` without an access
/// prompt, which is exactly what the generated `cla` shell function runs. An
/// item created by TokenEater itself would make every `cla` prompt (or fail in
/// a non-interactive shell).
///
/// The secret never reaches a process's argv, where any local user could read
/// it with `ps`: `save` starts `security -i` (interactive mode) and writes the
/// `add-generic-password` command on its stdin, with the token hex-encoded
/// (`-X`). TokenEater never reads the secret back.
///
/// The process spawn is injectable: the unit tests never touch the Keychain.
final class TerminalTokenStore: TerminalTokenStoreProtocol, @unchecked Sendable {

    struct ProcessRunResult: Equatable {
        let status: Int32
        let stdout: Data
        let stderr: String
    }

    enum ProcessRunError: Error, Equatable {
        case launchFailed(String)
        case timedOut
    }

    /// Spawns `executable` with `arguments`, feeds it `stdin` (nil: no input),
    /// and waits at most `timeout` seconds for it to exit. The default runs a
    /// real `Process`; tests capture the call instead.
    typealias ProcessRunner = @Sendable (
        _ executable: String, _ arguments: [String], _ stdin: Data?, _ timeout: TimeInterval
    ) throws -> ProcessRunResult

    static let securityExecutable = "/usr/bin/security"
    /// `security` can block on Keychain authorization when launched from a
    /// headless app (#217); same watchdog as the Claude Code credential write.
    static let timeout: TimeInterval = 5
    static let labelPrefix = "TokenEater terminal token"
    /// The label only helps a human recognise the item in Keychain Access;
    /// the shell finds it by service.
    static let maxLabelNameLength = 64
    /// `security -i` reads each command into a 4096-byte line buffer. A longer
    /// line is split, and the first fragment still runs: for
    /// `add-generic-password` that would store a truncated secret. Measured on
    /// macOS 26, a line of 4095 bytes including its newline is the largest
    /// read whole; stay below it with a margin.
    static let maxCommandLineBytes = 4000

    private let account: String
    private let runner: ProcessRunner

    /// - Parameters:
    ///   - account: the Keychain account attribute. The macOS user name, which
    ///     is what the generated shell function passes to `-a`.
    ///   - runner: spawns `/usr/bin/security`; injectable for tests.
    init(
        account: String = NSUserName(),
        runner: @escaping ProcessRunner = {
            try TerminalTokenStore.runProcess(executable: $0, arguments: $1, stdin: $2, timeout: $3)
        }
    ) {
        self.account = account
        self.runner = runner
    }

    // MARK: - TerminalTokenStoreProtocol

    /// `security -i` with `add-generic-password -U -a … -s … -l … -X <hex>` on
    /// stdin. `-U` replaces an existing item in place (keeping its ACL), `-X`
    /// carries the token as hex so no character of it can break the command
    /// line.
    func save(token: String, profileID: UUID, profileName: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TerminalTokenFormat.isPlausible(trimmed) else {
            throw TerminalTokenStoreError.implausibleToken
        }
        let command = try Self.addCommand(
            account: account,
            service: TerminalTokenKeychain.service(for: profileID),
            label: Self.label(forProfileName: profileName),
            hexToken: Self.hexString(Data(trimmed.utf8))
        )

        let result: ProcessRunResult
        do {
            result = try runner(Self.securityExecutable, ["-i"], Data(command.utf8), Self.timeout)
        } catch ProcessRunError.timedOut {
            logger.error("security -i timed out after \(Int(Self.timeout), privacy: .public) s")
            throw TerminalTokenStoreError.writeFailed("security timed out after \(Int(Self.timeout)) s")
        } catch {
            throw TerminalTokenStoreError.writeFailed("security launch failed: \(error)")
        }

        // Interactive mode prints "<command>: returned <code>" on stderr for
        // every failed command, but its exit status is the one of the *last*
        // line it read, which can be 0 after a failure (an empty line that
        // follows, older releases). A successful add prints nothing, so any
        // stderr output counts as a failure too. A follow-up `exists` would
        // not do: it is true when replacing an existing item failed.
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0, stderr.isEmpty else {
            logger.error("security add-generic-password failed (exit \(result.status, privacy: .public))")
            throw TerminalTokenStoreError.writeFailed(
                stderr.isEmpty ? "security exited with \(result.status)" : stderr
            )
        }
    }

    /// `security find-generic-password -a … -s …` without `-w`: matches on
    /// attributes only, so it never reads the secret nor triggers a prompt.
    func exists(profileID: UUID) -> Bool {
        let arguments = ["find-generic-password", "-a", account, "-s", TerminalTokenKeychain.service(for: profileID)]
        guard let result = try? runner(Self.securityExecutable, arguments, nil, Self.timeout) else { return false }
        return result.status == 0
    }

    /// `security delete-generic-password -a … -s …`. Errors are ignored: a
    /// missing item is already the goal.
    func delete(profileID: UUID) {
        let arguments = ["delete-generic-password", "-a", account, "-s", TerminalTokenKeychain.service(for: profileID)]
        _ = try? runner(Self.securityExecutable, arguments, nil, Self.timeout)
    }

    // MARK: - Command line

    /// `TokenEater terminal token (<profile name>)`, with the name stripped of
    /// what cannot sit inside a double-quoted `security -i` argument (`"`,
    /// `\`, control characters, line breaks) and capped at
    /// `maxLabelNameLength` characters.
    static func label(forProfileName profileName: String) -> String {
        let unsafe = CharacterSet.controlCharacters
            .union(.newlines)
            .union(CharacterSet(charactersIn: "\"\\"))
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: profileName.unicodeScalars.filter { !unsafe.contains($0) })
        let name = String(String(scalars).trimmingCharacters(in: .whitespaces).prefix(maxLabelNameLength))
        return name.isEmpty ? labelPrefix : "\(labelPrefix) (\(name))"
    }

    /// The single line written to `security -i`. Every value is double-quoted
    /// (the profile name may contain spaces, `'`, `$`, `#`, …); the hex token
    /// needs no quoting.
    static func addCommand(account: String, service: String, label: String, hexToken: String) throws -> String {
        let line = "add-generic-password -U"
            + " -a \(try quoted(account))"
            + " -s \(try quoted(service))"
            + " -l \(try quoted(label))"
            + " -X \(hexToken)\n"
        guard line.utf8.count <= maxCommandLineBytes else {
            throw TerminalTokenStoreError.writeFailed(
                "the Keychain command is too long for security -i (\(line.utf8.count) bytes)"
            )
        }
        return line
    }

    /// `"value"`. `security -i` honours `\` escapes and ends the line at a line
    /// break, so a value containing either (or a `"`) cannot be passed safely.
    private static func quoted(_ value: String) throws -> String {
        let unsafe = CharacterSet.controlCharacters.union(.newlines).union(CharacterSet(charactersIn: "\"\\"))
        guard !value.unicodeScalars.contains(where: { unsafe.contains($0) }) else {
            throw TerminalTokenStoreError.writeFailed("unsupported character in a Keychain attribute")
        }
        return "\"\(value)\""
    }

    /// Lowercase hex, the form `security add-generic-password -X` expects.
    static func hexString(_ data: Data) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8](repeating: 0, count: data.count * 2)
        for (i, byte) in data.enumerated() {
            out[i * 2] = digits[Int(byte >> 4)]
            out[i * 2 + 1] = digits[Int(byte & 0x0f)]
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: - Process

    /// Default `ProcessRunner`. stdin is a pipe when there is input and
    /// `/dev/null` otherwise (never the app's own stdin, which `security -i`
    /// would read commands from). stdout and stderr are drained while the
    /// child runs, and the wait happens on a background queue behind a
    /// watchdog so a child blocked on Keychain authorization cannot hang the
    /// caller (same pattern as `SecurityCLIReader`).
    static func runProcess(executable: String, arguments: [String], stdin: Data?, timeout: TimeInterval) throws -> ProcessRunResult {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = stdin.map { _ in Pipe() }
        task.standardOutput = stdoutPipe
        task.standardError = stderrPipe
        task.standardInput = stdinPipe ?? FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            throw ProcessRunError.launchFailed(error.localizedDescription)
        }

        let output = PipeDrain(stdoutPipe.fileHandleForReading)
        let errors = PipeDrain(stderrPipe.fileHandleForReading)

        if let stdin, let stdinPipe {
            let writer = stdinPipe.fileHandleForWriting
            // A child that exits without reading must surface as EPIPE here,
            // not as a SIGPIPE that kills the app.
            _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
            DispatchQueue.global(qos: .userInitiated).async {
                try? writer.write(contentsOf: stdin)
                try? writer.close()
            }
        }

        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            task.waitUntilExit()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            task.terminate()
            throw ProcessRunError.timedOut
        }
        let stderrText = String(decoding: errors.collected(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ProcessRunResult(status: task.terminationStatus, stdout: output.collected(), stderr: stderrText)
    }

    /// Reads a pipe to end-of-file on a background queue.
    private final class PipeDrain: @unchecked Sendable {
        private var data = Data()
        private let finished = DispatchSemaphore(value: 0)

        init(_ handle: FileHandle) {
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                data = handle.readDataToEndOfFile()
                finished.signal()
            }
        }

        /// What was read. The child has exited, so end-of-file is imminent;
        /// the short grace only covers a descendant still holding the pipe.
        func collected() -> Data {
            finished.wait(timeout: .now() + 1) == .success ? data : Data()
        }
    }
}
