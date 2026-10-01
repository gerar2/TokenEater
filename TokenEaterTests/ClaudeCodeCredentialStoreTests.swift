import Testing
import Foundation

@Suite("ClaudeCodeCredentialStore")
struct ClaudeCodeCredentialStoreTests {

    private static let home = "/Users/tester"
    private static let account = "tester"

    private static let keychainJSON = """
    {"claudeAiOauth":{"accessToken":"kc-access","refreshToken":"kc-refresh","expiresAt":1767225600000,"scopes":["user:inference","user:profile"],"subscriptionType":"max","rateLimitTier":"default_claude_max_5x"},"other":{"keep":true}}
    """
    private static let fileJSON = """
    {"claudeAiOauth":{"accessToken":"file-access","refreshToken":"file-refresh","expiresAt":1767225600000,"scopes":["user:inference"],"subscriptionType":"pro"}}
    """

    private static let rotated = OAuthCredentials(
        accessToken: "new-access",
        refreshToken: "new-refresh",
        expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
        scopes: ["user:inference", "user:profile"],
        subscriptionType: "max"
    )

    /// Records what the store asked its collaborators for.
    private final class Capture: @unchecked Sendable {
        var services: [String] = []
        var paths: [String] = []
        var runs: [(executable: String, arguments: [String], timeout: TimeInterval)] = []
    }

    private func makeSUT(
        keychainPayload: String? = nil,
        filePayload: String? = nil,
        encryptedToken: String? = nil,
        decryptedData: Data? = nil,
        hasEncryptionKey: Bool = false,
        silentRebootstrapResult: Bool = false,
        exitStatus: Int32 = 0
    ) -> (sut: ClaudeCodeCredentialStore, capture: Capture, decryption: MockElectronDecryptionService) {
        let capture = Capture()
        let decryption = MockElectronDecryptionService()
        decryption._hasEncryptionKey = hasEncryptionKey
        decryption.decryptedData = decryptedData
        decryption.silentRebootstrapResult = silentRebootstrapResult
        let configReader = MockClaudeConfigReader()
        configReader.encryptedToken = encryptedToken

        let sut = ClaudeCodeCredentialStore(
            realHome: Self.home,
            account: Self.account,
            securityReaderFactory: { service in
                capture.services.append(service)
                let reader = MockSecurityCLIReader()
                reader.payload = keychainPayload
                return reader
            },
            fileReaderFactory: { path in
                capture.paths.append(path)
                let reader = MockCredentialsFileReader()
                reader.payload = filePayload.map { Data($0.utf8) }
                reader.fileExists = filePayload != nil
                return reader
            },
            configReader: configReader,
            decryptionService: decryption,
            processRunner: { executable, arguments, timeout in
                capture.runs.append((executable, arguments, timeout))
                return ClaudeCodeCredentialStore.ProcessRunResult(
                    terminationStatus: exitStatus,
                    stderr: exitStatus == 0 ? "" : "User interaction is not allowed."
                )
            }
        )
        return (sut, capture, decryption)
    }

    private static func data(fromHex hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    // MARK: - Read order

    @Test("Keychain is the primary source and the file is not consulted")
    func keychainFirst() throws {
        let (sut, capture, decryption) = makeSUT(keychainPayload: Self.keychainJSON, filePayload: Self.fileJSON)

        let read = try #require(sut.read(configDir: nil))

        #expect(read.backing == .keychain(service: "Claude Code-credentials"))
        #expect(read.credentials.accessToken == "kc-access")
        #expect(read.credentials.refreshToken == "kc-refresh")
        #expect(read.credentials.expiresAt == Date(timeIntervalSince1970: 1_767_225_600))
        #expect(read.credentials.subscriptionType == "max")
        #expect((read.raw["other"] as? [String: Any])?["keep"] as? Bool == true)
        #expect(capture.services == ["Claude Code-credentials"])
        #expect(capture.paths.isEmpty)
        #expect(decryption.decryptCallCount == 0)
    }

    @Test("A custom config dir uses the hashed Keychain service and its own credentials file")
    func customDirService() throws {
        let (sut, capture, _) = makeSUT(filePayload: Self.fileJSON)
        let expectedService = ClaudeKeychainServiceName.service(forConfigDir: "~/.claude-work", realHome: Self.home)
        #expect(expectedService == "Claude Code-credentials-" + ClaudeKeychainServiceName.hash8("/Users/tester/.claude-work"))

        let read = try #require(sut.read(configDir: "~/.claude-work/"))

        #expect(capture.services == [expectedService])
        #expect(capture.paths == ["/Users/tester/.claude-work/.credentials.json"])
        #expect(read.backing == .file(path: "/Users/tester/.claude-work/.credentials.json"))
        #expect(read.credentials.accessToken == "file-access")
    }

    @Test("Falls back to <configDir>/.credentials.json when the Keychain misses")
    func fileFallback() throws {
        let (sut, capture, decryption) = makeSUT(filePayload: Self.fileJSON)

        let read = try #require(sut.read(configDir: nil))

        #expect(read.backing == .file(path: "/Users/tester/.claude/.credentials.json"))
        #expect(read.credentials.accessToken == "file-access")
        #expect(read.credentials.scopes == ["user:inference"])
        #expect(capture.paths == ["/Users/tester/.claude/.credentials.json"])
        #expect(decryption.decryptCallCount == 0)
    }

    @Test("Unparsable Keychain payload falls through to the file")
    func garbageKeychainFallsThrough() throws {
        let (sut, _, _) = makeSUT(keychainPayload: "not json", filePayload: Self.fileJSON)
        let read = try #require(sut.read(configDir: nil))
        #expect(read.backing == .file(path: "/Users/tester/.claude/.credentials.json"))
    }

    @Test("Claude Desktop decryption is the last resort for the default dir only")
    func desktopFallbackDefaultOnly() throws {
        let decrypted = try JSONSerialization.data(withJSONObject: ["claudeAiOauth": ["accessToken": "desktop-token"]])
        let (sut, _, decryption) = makeSUT(encryptedToken: "encrypted-blob", decryptedData: decrypted, hasEncryptionKey: true)

        let read = try #require(sut.read(configDir: nil))
        #expect(read.backing == .claudeDesktop)
        #expect(read.credentials.accessToken == "desktop-token")
        #expect(read.credentials.refreshToken == nil)
        #expect(read.credentials.expiresAt == nil)
        #expect(read.raw.isEmpty)
        #expect(decryption.decryptCallCount == 1)

        // Same store, explicit default path: still eligible.
        #expect(sut.read(configDir: "~/.claude")?.backing == .claudeDesktop)

        // A custom dir never borrows the machine-wide Claude Desktop token.
        let before = decryption.decryptCallCount
        #expect(sut.read(configDir: "~/.claude-work") == nil)
        #expect(decryption.decryptCallCount == before)
    }

    @Test("Claude Desktop path recovers the key with a silent re-bootstrap")
    func desktopSilentRebootstrap() throws {
        let uuidShape: [String: Any] = ["uuid:uuid:https://api.anthropic.com": ["token": "sk-ant-test-only"]]
        let decrypted = try JSONSerialization.data(withJSONObject: uuidShape)
        let (sut, _, decryption) = makeSUT(
            encryptedToken: "encrypted-blob",
            decryptedData: decrypted,
            hasEncryptionKey: false,
            silentRebootstrapResult: true
        )

        let read = try #require(sut.read(configDir: nil))
        #expect(read.credentials.accessToken == "sk-ant-test-only")
        #expect(decryption.silentRebootstrapCallCount == 1)
    }

    @Test("Returns nil when no source is available")
    func nothingAvailable() {
        let (sut, _, _) = makeSUT()
        #expect(sut.read(configDir: nil) == nil)
        #expect(sut.read(configDir: "~/.claude-work") == nil)
    }

    // MARK: - exists

    @Test("exists reflects any readable backing, including an undecryptable Desktop token")
    func exists() {
        #expect(makeSUT().sut.exists(configDir: nil) == false)
        #expect(makeSUT(keychainPayload: Self.keychainJSON).sut.exists(configDir: nil))
        #expect(makeSUT(filePayload: Self.fileJSON).sut.exists(configDir: "~/.claude-work"))
        // Encrypted token present but no key yet: still a source (default dir only).
        let undecryptable = makeSUT(encryptedToken: "blob", hasEncryptionKey: false).sut
        #expect(undecryptable.exists(configDir: nil))
        #expect(undecryptable.exists(configDir: "~/.claude-work") == false)
    }

    // MARK: - Write: file

    @Test("write(.file) merges into the existing file, keeps unknown keys and sets 0600")
    func writeFileKeepsUnknownKeysAndPermissions() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokeneater-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent(".credentials.json").path
        try Data(Self.keychainJSON.utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)

        let (sut, capture, _) = makeSUT()
        let parsed = try #require(ClaudeCredentialsPayload.parse(string: Self.keychainJSON))

        try sut.write(Self.rotated, raw: parsed.raw, backing: .file(path: path))

        let contents = try #require(FileManager.default.contents(atPath: path))
        let reread = try #require(ClaudeCredentialsPayload.parse(contents))
        #expect(reread.credentials == Self.rotated)
        let oauth = try #require(reread.raw["claudeAiOauth"] as? [String: Any])
        #expect(oauth["rateLimitTier"] as? String == "default_claude_max_5x")
        #expect((reread.raw["other"] as? [String: Any])?["keep"] as? Bool == true)
        let permissions = try #require(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
        #expect(permissions == 0o600)
        #expect(capture.runs.isEmpty)
    }

    @Test("write(.file) refuses to create a credentials file that does not exist")
    func writeFileRequiresExistingFile() {
        let (sut, _, _) = makeSUT()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokeneater-missing-\(UUID().uuidString)/.credentials.json").path
        #expect(throws: ClaudeCodeCredentialStoreError.writeFailed("credentials file does not exist")) {
            try sut.write(Self.rotated, raw: [:], backing: .file(path: missing))
        }
    }

    // MARK: - Write: Keychain

    @Test("write(.keychain) runs security add-generic-password -U with the merged payload as hex")
    func writeKeychainBuildsArgv() throws {
        let (sut, capture, _) = makeSUT()
        let parsed = try #require(ClaudeCredentialsPayload.parse(string: Self.keychainJSON))
        let service = "Claude Code-credentials-7719f642"

        try sut.write(Self.rotated, raw: parsed.raw, backing: .keychain(service: service))

        #expect(capture.runs.count == 1)
        let run = try #require(capture.runs.first)
        #expect(run.executable == "/usr/bin/security")
        #expect(run.timeout == 5)
        #expect(run.arguments.count == 8)
        #expect(Array(run.arguments.prefix(7)) == ["add-generic-password", "-U", "-a", "tester", "-s", service, "-X"])

        let payload = try #require(Self.data(fromHex: run.arguments[7]))
        let reparsed = try #require(ClaudeCredentialsPayload.parse(payload))
        #expect(reparsed.credentials == Self.rotated)
        #expect((reparsed.raw["claudeAiOauth"] as? [String: Any])?["rateLimitTier"] as? String == "default_claude_max_5x")
        #expect((reparsed.raw["other"] as? [String: Any])?["keep"] as? Bool == true)
    }

    @Test("write(.keychain) surfaces a non-zero security exit as writeFailed")
    func writeKeychainNonZeroExit() {
        let (sut, _, _) = makeSUT(exitStatus: 45)
        #expect(throws: ClaudeCodeCredentialStoreError.self) {
            try sut.write(Self.rotated, raw: [:], backing: .keychain(service: "Claude Code-credentials"))
        }
        do {
            try sut.write(Self.rotated, raw: [:], backing: .keychain(service: "Claude Code-credentials"))
        } catch ClaudeCodeCredentialStoreError.writeFailed(let message) {
            #expect(message.contains("45"))
            #expect(message.contains("User interaction is not allowed."))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("write(.keychain) surfaces a launch failure or timeout as writeFailed")
    func writeKeychainLaunchFailure() {
        let sut = ClaudeCodeCredentialStore(
            realHome: Self.home,
            account: Self.account,
            securityReaderFactory: { _ in MockSecurityCLIReader() },
            fileReaderFactory: { _ in MockCredentialsFileReader() },
            configReader: MockClaudeConfigReader(),
            decryptionService: MockElectronDecryptionService(),
            processRunner: { _, _, _ in throw ClaudeCodeCredentialStore.ProcessRunError.timedOut }
        )
        #expect(throws: ClaudeCodeCredentialStoreError.self) {
            try sut.write(Self.rotated, raw: [:], backing: .keychain(service: "Claude Code-credentials"))
        }
    }

    @Test("hex encoding is lowercase and byte-exact")
    func hexEncoding() {
        #expect(ClaudeCodeCredentialStore.hexString(Data([0x00, 0xab, 0xff, 0x7b])) == "00abff7b")
        #expect(ClaudeCodeCredentialStore.hexString(Data()) == "")
    }

    // MARK: - Write: read-only backing

    @Test("write(.claudeDesktop) is refused")
    func writeClaudeDesktopReadOnly() {
        let (sut, capture, _) = makeSUT()
        #expect(throws: ClaudeCodeCredentialStoreError.readOnlyBacking) {
            try sut.write(Self.rotated, raw: [:], backing: .claudeDesktop)
        }
        #expect(capture.runs.isEmpty)
    }
}
