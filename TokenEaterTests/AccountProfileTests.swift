import Testing
import Foundation

@Suite("AccountProfile")
struct AccountProfileTests {

    @Test("round-trips a linked profile through JSON")
    func linkedRoundTrip() throws {
        let profile = AccountProfile(
            name: "Work",
            colorHex: "#60A5FA",
            source: .claudeCode(configDir: "/Users/me/.claude-work"),
            renewalPolicy: .tokenEater,
            isEnabled: false,
            accountEmail: "me@work.test",
            accountUUID: "acc-1",
            planTypeRaw: "max"
        )
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(AccountProfile.self, from: data)
        #expect(decoded.id == profile.id)
        #expect(decoded.name == "Work")
        #expect(decoded.colorHex == "#60A5FA")
        #expect(decoded.source == .claudeCode(configDir: "/Users/me/.claude-work"))
        #expect(decoded.renewalPolicy == .tokenEater)
        #expect(decoded.isEnabled == false)
        #expect(decoded.accountEmail == "me@work.test")
        #expect(decoded.accountUUID == "acc-1")
        #expect(decoded.planType == .max)
    }

    @Test("round-trips a managed profile and forces the tokenEater policy")
    func managedRoundTrip() throws {
        let profile = AccountProfile(name: "Personal", source: .managed, renewalPolicy: .claudeCode)
        let decoded = try JSONDecoder().decode(AccountProfile.self, from: JSONEncoder().encode(profile))
        #expect(decoded.source == .managed)
        #expect(decoded.isLinked == false)
        #expect(decoded.configDir == nil)
        #expect(decoded.effectiveRenewalPolicy == .tokenEater)
    }

    @Test("decodes tolerantly when optional fields are missing")
    func tolerantDecoding() throws {
        let json = """
        {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Claude Code","source":{"kind":"claudeCode"}}
        """
        let decoded = try JSONDecoder().decode(AccountProfile.self, from: Data(json.utf8))
        #expect(decoded.name == "Claude Code")
        #expect(decoded.source == .claudeCode(configDir: nil))
        #expect(decoded.isDefaultClaudeCodeProfile)
        #expect(decoded.renewalPolicy == .claudeCode)
        #expect(decoded.isEnabled == true)
        #expect(decoded.colorHex == ProfilePalette.presets[0])
    }

    @Test("an unknown source kind fails that profile only when decoded lossily")
    func unknownSourceIsDropped() throws {
        let json = """
        [{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"A","source":{"kind":"claudeCode"}},
         {"id":"7F9619FF-8B86-D011-B42D-00C04FC964FF","name":"B","source":{"kind":"quantum"}}]
        """
        let wrapped = try JSONDecoder().decode([Lossy<AccountProfile>].self, from: Data(json.utf8))
        let profiles = wrapped.compactMap(\.value)
        #expect(profiles.count == 1)
        #expect(profiles.first?.name == "A")
    }

    @Test("resolvedConfigDir expands the default and normalises custom dirs")
    func resolvedConfigDir() {
        let home = "/Users/me"
        #expect(AccountProfile(name: "d", source: .claudeCode(configDir: nil)).resolvedConfigDir(realHome: home) == "/Users/me/.claude")
        #expect(AccountProfile(name: "w", source: .claudeCode(configDir: "~/.claude-work/")).resolvedConfigDir(realHome: home) == "/Users/me/.claude-work")
        #expect(AccountProfile(name: "m", source: .managed).resolvedConfigDir(realHome: home) == "/Users/me/.claude")
    }

    @Test("palette hands out unused presets first, then cycles")
    func palette() {
        #expect(ProfilePalette.next(after: []) == ProfilePalette.presets[0])
        #expect(ProfilePalette.next(after: [ProfilePalette.presets[0]]) == ProfilePalette.presets[1])
        #expect(ProfilePalette.next(after: [ProfilePalette.presets[0].lowercased()]) == ProfilePalette.presets[1])
        let all = ProfilePalette.presets
        #expect(ProfilePalette.next(after: all) == ProfilePalette.presets[0])
    }
}
