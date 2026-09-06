import Foundation
import os.log

private let logger = Logger(subsystem: "com.tokeneater.app", category: "ClaudeCodeCredentialStore")

/// Reads and writes Claude Code's own credential store for a config directory.
///
/// The read order mirrors what Claude Code does on macOS (verified against
/// 2.1.261, see `docs/multi-profile-plan.md` §0): the Keychain generic password
/// named by `ClaudeKeychainServiceName`, read through `/usr/bin/security`
/// because that is the only binary the item's ACL trusts; then
/// `<configDir>/.credentials.json`; then - for the default `~/.claude` only -
/// the Claude Desktop `config.json` path, which yields an access token but no
/// refresh token and can never be written.
///
/// A write-back always targets the backing the read came from and merges into
/// the raw payload so keys this build does not know about survive. Every
/// reader and the process spawn are injectable: the unit tests never touch the
/// Keychain, the real home directory or `/usr/bin/security`.
final class ClaudeCodeCredentialStore: ClaudeCodeCredentialStoreProtocol, @unchecked Sendable {

    typealias SecurityReaderFactory = @Sendable (_ service: String) -> SecurityCLIReaderProtocol
    typealias FileReaderFactory = @Sendable (_ path: String) -> CredentialsFileReaderProtocol

    struct ProcessRunResult: Equatable {
        let terminationStatus: Int32
        let stderr: String
    }

    enum ProcessRunError: Error, Equatable {
        case launchFailed(String)
        case timedOut
    }

    /// Spawns `executable` with `arguments` and waits at most `timeout`
    /// seconds for it to exit. The default runs a real `Process`; tests
    /// capture the argv instead.
    typealias ProcessRunner = @Sendable (_ executable: String, _ arguments: [String], _ timeout: TimeInterval) throws -> ProcessRunResult

    static let securityExecutable = "/usr/bin/security"
    static let credentialsFileName = ".credentials.json"
    /// `security add-generic-password` can hang on Keychain authorization the
    /// same way the read does (#217). A bit longer than the 3 s read watchdog
    /// because an update also rewrites the item's ACL.
    static let writeTimeout: TimeInterval = 5

    private let realHome: String
    private let account: String
    private let securityReaderFactory: SecurityReaderFactory
    private let fileReaderFactory: FileReaderFactory
    private let configReader: ClaudeConfigReaderProtocol
    private let decryptionService: ElectronDecryptionServiceProtocol
    private let processRunner: ProcessRunner

    /// - Parameters:
    ///   - realHome: the real home directory (`getpwuid`), never the sandbox
    ///     container; used to resolve the default config dir.
    ///   - account: the Keychain account attribute Claude Code uses, i.e. the
    ///     macOS user name.
    init(
        realHome: String = ClaudeKeychainServiceName.realHome,
        account: String = NSUserName(),
        securityReaderFactory: @escaping SecurityReaderFactory = { SecurityCLIReader(service: $0) },
        fileReaderFactory: @escaping FileReaderFactory = { CredentialsFileReader(filePath: $0) },
        configReader: ClaudeConfigReaderProtocol = ClaudeConfigReader(),
        decryptionService: ElectronDecryptionServiceProtocol = ElectronDecryptionService(),
        processRunner: @escaping ProcessRunner = ClaudeCodeCredentialStore.runProcess
    ) {
        self.realHome = realHome
        self.account = account
        self.securityReaderFactory = securityReaderFactory
        self.fileReaderFactory = fileReaderFactory
        self.configReader = configReader
        self.decryptionService = decryptionService
        self.processRunner = processRunner
    }

    // MARK: - Read

    func read(configDir: String?) -> ClaudeCodeCredentialRead? {
        let service = ClaudeKeychainServiceName.service(forConfigDir: configDir, realHome: realHome)
        if let payload = securityReaderFactory(service).readPayload(),
           let parsed = ClaudeCredentialsPayload.parse(string: payload) {
            return ClaudeCodeCredentialRead(credentials: parsed.credentials, raw: parsed.raw, backing: .keychain(service: service))
        }

        let path = credentialsFilePath(configDir: configDir)
        if let data = fileReaderFactory(path).readPayload(),
           let parsed = ClaudeCredentialsPayload.parse(data) {
            return ClaudeCodeCredentialRead(credentials: parsed.credentials, raw: parsed.raw, backing: .file(path: path))
        }

        // Claude Desktop keeps a single token cache for the machine, so it can
        // only stand in for the default config dir.
        if ClaudeKeychainServiceName.isDefaultDir(configDir, realHome: realHome),
           let token = claudeDesktopToken() {
            return ClaudeCodeCredentialRead(credentials: OAuthCredentials(accessToken: token), raw: [:], backing: .claudeDesktop)
        }
        return nil
    }

    func exists(configDir: String?) -> Bool {
        if read(configDir: configDir) != nil { return true }
        // A Claude Desktop token that is not decryptable yet still counts as a
        // source (same contract as `TokenProvider.hasTokenSource`).
        return ClaudeKeychainServiceName.isDefaultDir(configDir, realHome: realHome)
            && configReader.readEncryptedToken() != nil
    }

    /// `<resolved config dir>/.credentials.json`.
    func credentialsFilePath(configDir: String?) -> String {
        resolvedConfigDir(configDir) + "/" + Self.credentialsFileName
    }

    private func resolvedConfigDir(_ configDir: String?) -> String {
        guard let configDir else { return realHome + "/.claude" }
        return ClaudeKeychainServiceName.normalize(configDir, realHome: realHome)
    }

    private func claudeDesktopToken() -> String? {
        guard let encrypted = configReader.readEncryptedToken() else { return nil }
        if decryptionService.hasEncryptionKey, let token = decryptDesktopToken(encrypted) {
            return token
        }
        if decryptionService.trySilentRebootstrap(), let token = decryptDesktopToken(encrypted) {
            logger.info("Claude Desktop token recovered via silent re-bootstrap of the decryption key")
            return token
        }
        return nil
    }

    private func decryptDesktopToken(_ encrypted: String) -> String? {
        guard let data = try? decryptionService.decrypt(encrypted) else { return nil }
        return Self.extractDesktopToken(from: data)
    }

    /// The two shapes Claude Desktop's decrypted token cache has used:
    /// `claudeAiOauth.accessToken`, or the older `{"<uuid>": {"token": "sk-ant-…"}}`
    /// map (same rules as the legacy `TokenProvider`).
    static func extractDesktopToken(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let oauth = json[ClaudeCredentialsPayload.rootKey] as? [String: Any],
           let token = oauth["accessToken"] as? String, !token.isEmpty {
            return token
        }
        for (_, value) in json {
            if let entry = value as? [String: Any],
               let token = entry["token"] as? String,
               token.hasPrefix("sk-ant-") {
                return token
            }
        }
        return nil
    }

    // MARK: - Write

    func write(_ credentials: OAuthCredentials, raw: [String: Any], backing: ClaudeCodeCredentialBacking) throws {
        switch backing {
        case .claudeDesktop:
            throw ClaudeCodeCredentialStoreError.readOnlyBacking
        case .file(let path):
            try writeFile(credentials, raw: raw, path: path)
        case .keychain(let service):
            try writeKeychain(credentials, raw: raw, service: service)
        }
    }

    /// Replaces the credentials file atomically. Refuses to create one: a
    /// missing file means Claude Code keeps this dir's credentials elsewhere
    /// and a stray file would shadow nothing useful.
    private func writeFile(_ credentials: OAuthCredentials, raw: [String: Any], path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw ClaudeCodeCredentialStoreError.writeFailed("credentials file does not exist")
        }
        guard let data = ClaudeCredentialsPayload.mergedData(credentials, into: raw) else {
            throw ClaudeCodeCredentialStoreError.serializationFailed
        }
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            throw ClaudeCodeCredentialStoreError.writeFailed(error.localizedDescription)
        }
        // An atomic write lands as a new inode with umask permissions; Claude
        // Code keeps the file owner-only.
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } catch {
            throw ClaudeCodeCredentialStoreError.writeFailed("chmod 0600 failed: \(error.localizedDescription)")
        }
    }

    /// `security add-generic-password -U -a <user> -s <service> -X <hex>`:
    /// exactly the command Claude Code runs. `-U` updates the existing item in
    /// place (keeping its ACL), `-X` passes the payload as hex so no quoting
    /// or shell metacharacter in the JSON can leak into the argv.
    private func writeKeychain(_ credentials: OAuthCredentials, raw: [String: Any], service: String) throws {
        guard let data = ClaudeCredentialsPayload.mergedData(credentials, into: raw) else {
            throw ClaudeCodeCredentialStoreError.serializationFailed
        }
        let arguments = [
            "add-generic-password",
            "-U",
            "-a", account,
            "-s", service,
            "-X", Self.hexString(data),
        ]
        let result: ProcessRunResult
        do {
            result = try processRunner(Self.securityExecutable, arguments, Self.writeTimeout)
        } catch {
            throw ClaudeCodeCredentialStoreError.writeFailed("security launch failed: \(error)")
        }
        guard result.terminationStatus == 0 else {
            logger.error("security add-generic-password exited with \(result.terminationStatus, privacy: .public)")
            throw ClaudeCodeCredentialStoreError.writeFailed(
                "security exited with \(result.terminationStatus): \(result.stderr)"
            )
        }
    }

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

    /// Default `ProcessRunner`: same watchdog pattern as `SecurityCLIReader`
    /// so a child blocked on Keychain authorization cannot hang the caller.
    static func runProcess(executable: String, arguments: [String], timeout: TimeInterval) throws -> ProcessRunResult {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr
        do {
            try task.run()
        } catch {
            throw ProcessRunError.launchFailed(error.localizedDescription)
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
        _ = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let stderrText = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return ProcessRunResult(terminationStatus: task.terminationStatus, stderr: stderrText)
    }
}
