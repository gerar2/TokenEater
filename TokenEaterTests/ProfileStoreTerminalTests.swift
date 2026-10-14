import Testing
import Foundation

/// `ProfileStore`'s terminal-accounts surface (`docs/terminal-accounts-plan.md`
/// §4): the integration flag, regeneration on every catalog change, the
/// generated entries, the command name / Warp colour setters, the terminal
/// token through `MockTerminalTokenStore`, and the live `~/.claude` account.

private func terminalProfile(
    name: String,
    colorHex: String = ProfilePalette.presets[0],
    source: ProfileCredentialSource = .claudeCode(configDir: nil),
    enabled: Bool = true,
    uuid: String? = nil,
    terminalName: String? = nil,
    warpColor: WarpTabColor? = nil,
    tokenSetAt: Date? = nil
) -> AccountProfile {
    AccountProfile(
        name: name,
        colorHex: colorHex,
        source: source,
        isEnabled: enabled,
        accountUUID: uuid,
        terminalName: terminalName,
        warpColor: warpColor,
        terminalTokenSetAt: tokenSetAt
    )
}

/// Shaped like a `claude setup-token` token (prefix + at least 40 characters).
private let plausibleToken = "sk-ant-oat01-" + String(repeating: "a", count: 40)

private func expectStoreError(_ expected: ProfileStoreError, _ body: () async throws -> Void) async {
    do {
        try await body()
        Issue.record("Expected \(expected) to be thrown")
    } catch let error as ProfileStoreError {
        #expect(error == expected)
    } catch {
        Issue.record("Expected ProfileStoreError, got \(error)")
    }
}

/// `.claude.json` payload naming the account signed in to `~/.claude`.
private func globalConfig(accountUUID: String) -> Data {
    Data(#"{"numStartups": 3, "oauthAccount": {"accountUuid": "\#(accountUUID)", "emailAddress": "me@example.com"}}"#.utf8)
}

@Suite("ProfileStore terminal accounts")
@MainActor
struct ProfileStoreTerminalTests {

    /// Bounded poll (3 s) for work the store hands to a background queue.
    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<60 where !condition() {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: - Enable / disable

    @Test("the integration is off by default and nothing is generated")
    func offByDefault() {
        let h = ProfileHarness()
        #expect(h.store.terminalIntegrationEnabled == false)
        #expect(h.terminalIntegration.regenerateCallCount == 0)
        #expect(h.terminalIntegration.removeCallCount == 0)
        #expect(h.store.terminalIntegrationError == nil)
    }

    @Test("enabling persists the flag and regenerates; disabling removes the generated files")
    func enableAndDisable() {
        let h = ProfileHarness(profiles: [terminalProfile(name: "Work")])

        h.store.setTerminalIntegrationEnabled(true)
        #expect(h.store.terminalIntegrationEnabled)
        #expect(h.defaults.bool(forKey: ProfileStore.terminalIntegrationEnabledKey))
        #expect(h.terminalIntegration.regenerateCallCount == 1)
        #expect(h.terminalIntegration.lastEntries == h.store.terminalEntries)
        #expect(h.terminalIntegration.removeCallCount == 0)

        // Same value again: no extra write.
        h.store.setTerminalIntegrationEnabled(true)
        #expect(h.terminalIntegration.regenerateCallCount == 1)

        h.store.setTerminalIntegrationEnabled(false)
        #expect(h.store.terminalIntegrationEnabled == false)
        #expect(h.defaults.object(forKey: ProfileStore.terminalIntegrationEnabledKey) as? Bool == false)
        #expect(h.terminalIntegration.removeCallCount == 1)
        #expect(h.terminalIntegration.regenerateCallCount == 1)

        h.store.setTerminalIntegrationEnabled(false)
        #expect(h.terminalIntegration.removeCallCount == 1)
    }

    @Test("a new store reads the persisted flag")
    func flagSurvivesRelaunch() {
        let h = ProfileHarness(profiles: [terminalProfile(name: "Work")])
        h.store.setTerminalIntegrationEnabled(true)

        let relaunched = ProfileStore(
            persistence: h.persistence,
            vault: h.vault,
            credentialStore: h.credentialStore,
            refresher: h.refresher,
            sharedFileService: h.sharedFile,
            identityClient: h.identity,
            realHome: ProfileHarness.home,
            usageStoreFactory: { profile in h.bag.makeStore(for: profile, sharedFile: h.sharedFile) },
            terminalTokenStore: h.terminalTokens,
            terminalIntegration: h.terminalIntegration,
            settingsDefaults: h.defaults
        )
        #expect(relaunched.terminalIntegrationEnabled)
    }

    @Test("a generation failure is recorded, and cleared by the next successful one")
    func regenerateErrorRecorded() {
        let h = ProfileHarness(profiles: [terminalProfile(name: "Work")])
        h.terminalIntegration.regenerateError = TerminalTokenStoreError.writeFailed("disk full")

        h.store.setTerminalIntegrationEnabled(true)
        #expect(h.store.terminalIntegrationError == String(describing: TerminalTokenStoreError.writeFailed("disk full")))

        h.terminalIntegration.regenerateError = nil
        h.store.regenerateTerminalIntegration()
        #expect(h.store.terminalIntegrationError == nil)
        #expect(h.terminalIntegration.regenerateCallCount == 2)
    }

    // MARK: - Regeneration on catalog changes

    @Test("every catalog change regenerates while the integration is on")
    func mutationsRegenerateWhenEnabled() async throws {
        let a = terminalProfile(name: "Work")
        let b = terminalProfile(name: "Perso", colorHex: "#60A5FA", source: .managed)
        let h = ProfileHarness(profiles: [a, b], activeID: a.id)
        h.store.setTerminalIntegrationEnabled(true)
        let mock = h.terminalIntegration
        var expected = mock.regenerateCallCount

        h.store.rename(a.id, to: "Office")
        expected += 1
        #expect(mock.regenerateCallCount == expected)
        #expect(mock.lastEntries?.first?.profileName == "Office")
        // The command follows the profile name until one is set explicitly.
        #expect(mock.lastEntries?.first?.name == "office")

        h.store.setColor(a.id, hex: "#F87171")
        expected += 1
        #expect(mock.regenerateCallCount == expected)
        #expect(mock.lastEntries?.first?.warpColor == .red)

        h.store.setWarpColor(a.id, .cyan)
        expected += 1
        #expect(mock.regenerateCallCount == expected)
        #expect(mock.lastEntries?.first?.warpColor == .cyan)

        try h.store.setTerminalName(a.id, "work")
        expected += 1
        #expect(mock.regenerateCallCount == expected)
        #expect(mock.lastEntries?.first?.name == "work")

        h.store.setEnabled(b.id, false)
        expected += 1
        #expect(mock.regenerateCallCount == expected)

        try await h.store.setTerminalToken(b.id, token: plausibleToken)
        expected += 1
        #expect(mock.regenerateCallCount == expected)

        h.store.removeTerminalToken(b.id)
        expected += 1
        #expect(mock.regenerateCallCount == expected)

        h.credentialStore.stub(configDir: ProfileHarness.workDir, credentials: OAuthCredentials(accessToken: "at", refreshToken: "rt"))
        let added = try await h.store.addLinkedProfile(name: "Lab", configDir: ProfileHarness.workDir)
        expected += 1
        #expect(mock.regenerateCallCount == expected)
        #expect(mock.lastEntries?.map(\.name) == ["work", "perso", "lab"])

        try h.store.remove(added.id)
        expected += 1
        #expect(mock.regenerateCallCount == expected)
        #expect(mock.lastEntries?.map(\.name) == ["work", "perso"])
        #expect(mock.removeCallCount == 0)
    }

    @Test("nothing is generated or removed while the integration is off")
    func mutationsNeverRegenerateWhenDisabled() async throws {
        let a = terminalProfile(name: "Work")
        let b = terminalProfile(name: "Perso", source: .managed)
        let h = ProfileHarness(profiles: [a, b], activeID: a.id)

        h.store.rename(a.id, to: "Office")
        h.store.setColor(a.id, hex: "#F87171")
        h.store.setWarpColor(a.id, .cyan)
        try h.store.setTerminalName(a.id, "work")
        h.store.setEnabled(b.id, false)
        try await h.store.setTerminalToken(b.id, token: plausibleToken)
        h.store.removeTerminalToken(b.id)
        h.store.regenerateTerminalIntegration()
        h.store.bootstrap(configure: { _ in }, thresholds: .default)
        h.store.stopAll()
        try h.store.remove(b.id)

        #expect(h.terminalIntegration.regenerateCallCount == 0)
        #expect(h.terminalIntegration.removeCallCount == 0)
        // The setters still apply: only the file generation is gated.
        #expect(h.store.profile(for: a.id)?.terminalName == "work")
        #expect(h.store.profile(for: a.id)?.warpColor == .cyan)
    }

    @Test("bootstrap regenerates once when the integration was left on")
    func bootstrapRegeneratesWhenEnabled() {
        let a = terminalProfile(name: "Work")
        let h = ProfileHarness(profiles: [a], activeID: a.id, terminalIntegrationEnabled: true)
        #expect(h.store.terminalIntegrationEnabled)
        #expect(h.terminalIntegration.regenerateCallCount == 0)

        h.store.bootstrap(configure: { _ in }, thresholds: .default)
        h.store.stopAll()

        #expect(h.terminalIntegration.regenerateCallCount == 1)
        #expect(h.terminalIntegration.lastEntries?.map(\.name) == ["work"])
    }

    // MARK: - terminalEntries

    @Test("terminalEntries lists every profile in catalog order with unique names, colours and keychain services")
    func terminalEntriesShape() {
        let a = terminalProfile(name: "Work", colorHex: "#32CE6A", uuid: "acc-a")
        let b = terminalProfile(name: "Work", colorHex: "#F472B6", source: .managed, enabled: false, uuid: "acc-b")
        let c = terminalProfile(name: "Perso", colorHex: "#60A5FA", source: .managed, terminalName: "me", warpColor: .cyan)
        let h = ProfileHarness(profiles: [a, b, c], activeID: a.id)

        let entries = h.store.terminalEntries

        #expect(entries.map(\.name) == ["work", "work-2", "me"])
        #expect(entries.map(\.profileID) == [a.id, b.id, c.id])
        #expect(entries.map(\.profileName) == ["Work", "Work", "Perso"])
        #expect(entries.map(\.accountUUID) == ["acc-a", "acc-b", nil])
        #expect(entries.map(\.warpColor) == [.green, .magenta, .cyan])
        #expect(entries.map(\.keychainService) == [a.id, b.id, c.id].map { "TokenEater terminal token: " + $0.uuidString })
        #expect(h.store.terminalName(for: b.id) == "work-2")
        #expect(h.store.terminalName(for: c.id) == "me")
        #expect(h.store.terminalName(for: UUID()) == nil)
    }

    // MARK: - setTerminalName

    @Test("setTerminalName trims, lowercases and persists the name")
    func setTerminalNameNormalises() throws {
        let a = terminalProfile(name: "Work")
        let h = ProfileHarness(profiles: [a], activeID: a.id)

        try h.store.setTerminalName(a.id, "  Work-Main \n")

        #expect(h.store.profile(for: a.id)?.terminalName == "work-main")
        #expect(h.persistence.profiles.first?.terminalName == "work-main")
        #expect(h.store.terminalName(for: a.id) == "work-main")
        // Its own current name is not "taken".
        try h.store.setTerminalName(a.id, "work-main")
        #expect(h.store.profile(for: a.id)?.terminalName == "work-main")
    }

    @Test("setTerminalName rejects invalid names and leaves the profile unchanged")
    func setTerminalNameInvalid() async {
        let a = terminalProfile(name: "Work", terminalName: "work")
        let h = ProfileHarness(profiles: [a], activeID: a.id)

        for bad in ["", "   ", "-work", "my work", "work_2", "wörk", String(repeating: "a", count: 32)] {
            await expectStoreError(.terminalNameInvalid) { try h.store.setTerminalName(a.id, bad) }
        }
        #expect(h.store.lastError == .terminalNameInvalid)
        #expect(h.store.profile(for: a.id)?.terminalName == "work")
        #expect(h.persistence.saveProfilesCallCount == 0)
    }

    @Test("setTerminalName rejects a name another profile already uses, explicit or suggested")
    func setTerminalNameTaken() async {
        let a = terminalProfile(name: "Work")
        let b = terminalProfile(name: "Lincyou", source: .managed)
        let c = terminalProfile(name: "Perso", source: .managed, terminalName: "gpt")
        let h = ProfileHarness(profiles: [a, b, c], activeID: a.id)

        await expectStoreError(.terminalNameTaken(existingName: "Lincyou")) {
            try h.store.setTerminalName(a.id, "LINCYOU")
        }
        await expectStoreError(.terminalNameTaken(existingName: "Perso")) {
            try h.store.setTerminalName(a.id, "gpt")
        }
        await expectStoreError(.notFound) { try h.store.setTerminalName(UUID(), "free") }
        #expect(h.store.profile(for: a.id)?.terminalName == nil)
    }

    // MARK: - setWarpColor

    @Test("setWarpColor overrides the colour derived from the profile colour and persists it")
    func setWarpColorPersists() {
        let a = terminalProfile(name: "Work", colorHex: "#32CE6A")
        let h = ProfileHarness(profiles: [a], activeID: a.id)
        #expect(h.store.profile(for: a.id)?.effectiveWarpColor == .green)

        h.store.setWarpColor(a.id, .yellow)

        #expect(h.store.profile(for: a.id)?.warpColor == .yellow)
        #expect(h.store.profile(for: a.id)?.effectiveWarpColor == .yellow)
        #expect(h.persistence.profiles.first?.warpColor == .yellow)
        #expect(h.store.terminalEntries.first?.warpColor == .yellow)
    }

    // MARK: - Terminal token

    @Test("setTerminalToken rejects an implausible token without reaching the Keychain")
    func setTerminalTokenImplausible() async {
        let a = terminalProfile(name: "Work")
        let h = ProfileHarness(profiles: [a], activeID: a.id)

        for bad in ["", "hello", "sk-ant-oat01-short", "sk-ant-api03-" + String(repeating: "a", count: 40),
                    "sk-ant-oat01-" + String(repeating: "a", count: 20) + " " + String(repeating: "b", count: 20)] {
            await expectStoreError(.terminalTokenInvalid) { try await h.store.setTerminalToken(a.id, token: bad) }
        }
        #expect(h.terminalTokens.saveCallCount == 0)
        #expect(h.store.profile(for: a.id)?.terminalTokenSetAt == nil)
        #expect(h.store.lastError == .terminalTokenInvalid)
    }

    @Test("a Keychain failure surfaces as terminalTokenSaveFailed and records nothing")
    func setTerminalTokenStoreFailure() async {
        let a = terminalProfile(name: "Work")
        let h = ProfileHarness(profiles: [a], activeID: a.id)
        let failure = TerminalTokenStoreError.writeFailed("User interaction is not allowed.")
        h.terminalTokens.saveError = failure

        await expectStoreError(.terminalTokenSaveFailed(String(describing: failure))) {
            try await h.store.setTerminalToken(a.id, token: plausibleToken)
        }
        #expect(h.terminalTokens.saveCallCount == 1)
        #expect(h.terminalTokens.tokens.isEmpty)
        #expect(h.store.profile(for: a.id)?.terminalTokenSetAt == nil)

        // A store that disagrees on the shape maps to the invalid-token error.
        h.terminalTokens.saveError = TerminalTokenStoreError.implausibleToken
        await expectStoreError(.terminalTokenInvalid) {
            try await h.store.setTerminalToken(a.id, token: plausibleToken)
        }
        await expectStoreError(.notFound) { try await h.store.setTerminalToken(UUID(), token: plausibleToken) }
    }

    @Test("setTerminalToken saves the trimmed token under the profile and records the date")
    func setTerminalTokenSuccess() async throws {
        let a = terminalProfile(name: "Work")
        let h = ProfileHarness(profiles: [a], activeID: a.id)
        let before = Date()

        try await h.store.setTerminalToken(a.id, token: "  \(plausibleToken)\n")

        let after = Date()
        #expect(h.terminalTokens.tokens[a.id] == plausibleToken)
        #expect(h.terminalTokens.lastSavedProfileName == "Work")
        let profile = try #require(h.store.profile(for: a.id))
        let setAt = try #require(profile.terminalTokenSetAt)
        #expect(setAt >= before && setAt <= after)
        #expect(profile.terminalTokenExpiresAt == setAt.addingTimeInterval(AccountProfile.terminalTokenLifetime))
        #expect(h.persistence.profiles.first?.terminalTokenSetAt == setAt)
    }

    @Test("removeTerminalToken clears the date at once and deletes the Keychain item")
    func removeTerminalToken() async throws {
        let a = terminalProfile(name: "Work")
        let h = ProfileHarness(profiles: [a], activeID: a.id)
        try await h.store.setTerminalToken(a.id, token: plausibleToken)

        h.store.removeTerminalToken(a.id)

        #expect(h.store.profile(for: a.id)?.terminalTokenSetAt == nil)
        #expect(h.persistence.profiles.first?.terminalTokenSetAt == nil)
        try await eventually { h.terminalTokens.deleteCallCount == 1 }
        #expect(h.terminalTokens.deleteCallCount == 1)
        #expect(h.terminalTokens.tokens[a.id] == nil)

        // Unknown id: nothing to delete.
        h.store.removeTerminalToken(UUID())
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.terminalTokens.deleteCallCount == 1)
    }

    @Test("removing a profile deletes its terminal token")
    func removeProfileDeletesToken() async throws {
        let a = terminalProfile(name: "Work")
        let b = terminalProfile(name: "Perso", source: .managed)
        let h = ProfileHarness(profiles: [a, b], activeID: a.id)
        try await h.store.setTerminalToken(b.id, token: plausibleToken)
        try await h.store.setTerminalToken(a.id, token: plausibleToken)

        try h.store.remove(b.id)

        try await eventually { h.terminalTokens.deleteCallCount == 1 }
        #expect(h.terminalTokens.tokens[b.id] == nil)
        #expect(h.terminalTokens.tokens[a.id] == plausibleToken)
    }

    @Test("verifyTerminalTokens clears the date of tokens missing from the Keychain")
    func verifyTerminalTokensClearsMissing() async throws {
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        let present = terminalProfile(name: "Present", tokenSetAt: stamp)
        let missing = terminalProfile(name: "Missing", source: .managed, tokenSetAt: stamp)
        let none = terminalProfile(name: "None", source: .managed)
        let h = ProfileHarness(profiles: [present, missing, none], activeID: present.id)
        h.terminalTokens.tokens[present.id] = plausibleToken

        await h.store.verifyTerminalTokens()

        #expect(h.store.profile(for: present.id)?.terminalTokenSetAt == stamp)
        #expect(h.store.profile(for: missing.id)?.terminalTokenSetAt == nil)
        #expect(h.store.profile(for: none.id)?.terminalTokenSetAt == nil)
        #expect(h.persistence.profiles.first { $0.id == missing.id }?.terminalTokenSetAt == nil)
        #expect(h.persistence.profiles.first { $0.id == present.id }?.terminalTokenSetAt == stamp)
    }

    // MARK: - Live ~/.claude account

    @Test("liveClaudeCodeAccountUUID reads oauthAccount.accountUuid from <home>/.claude.json")
    func liveAccountParsing() async {
        let h = ProfileHarness()
        #expect(h.store.liveClaudeCodeAccountUUID == nil)

        let expectedPath = ProfileHarness.home + "/.claude.json"
        h.store.globalConfigReader = { path in
            path == expectedPath ? globalConfig(accountUUID: "acc-live") : nil
        }
        await h.store.refreshLiveClaudeCodeAccount()
        #expect(h.store.liveClaudeCodeAccountUUID == "acc-live")

        // Signed out (no oauthAccount), unreadable JSON, empty uuid, no file.
        for payload in [#"{"numStartups": 3}"#, "not json", #"{"oauthAccount": {"accountUuid": ""}}"#] {
            h.store.globalConfigReader = { _ in Data(payload.utf8) }
            await h.store.refreshLiveClaudeCodeAccount()
            #expect(h.store.liveClaudeCodeAccountUUID == nil)
        }
        h.store.globalConfigReader = { _ in globalConfig(accountUUID: "acc-other") }
        await h.store.refreshLiveClaudeCodeAccount()
        #expect(h.store.liveClaudeCodeAccountUUID == "acc-other")
        h.store.globalConfigReader = { _ in nil }
        await h.store.refreshLiveClaudeCodeAccount()
        #expect(h.store.liveClaudeCodeAccountUUID == nil)
    }

    @Test("bootstrap reads the live ~/.claude account")
    func bootstrapReadsLiveAccount() async throws {
        let h = ProfileHarness()
        h.store.globalConfigReader = { _ in globalConfig(accountUUID: "acc-boot") }

        h.store.bootstrap(configure: { _ in }, thresholds: .default)
        h.store.stopAll()

        try await eventually { h.store.liveClaudeCodeAccountUUID != nil }
        #expect(h.store.liveClaudeCodeAccountUUID == "acc-boot")
    }
}
