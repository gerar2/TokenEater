import Testing
import Foundation

@Suite("Terminal accounts model")
struct TerminalAccountsModelTests {

    // MARK: - WarpTabColor

    @Test("Profile palette presets map to the expected Warp colours")
    func presetMapping() {
        let expected: [String: WarpTabColor] = [
            "#32CE6A": .green, "#60A5FA": .blue, "#A78BFA": .magenta, "#FFB347": .yellow,
            "#F87171": .red, "#2DD4BF": .cyan, "#F472B6": .magenta, "#FACC15": .yellow,
        ]
        for preset in ProfilePalette.presets {
            #expect(WarpTabColor.default(forProfileHex: preset) == expected[preset], "preset \(preset)")
        }
        #expect(WarpTabColor.default(forProfileHex: "32ce6a") == .green)
    }

    @Test("Other colours map to the nearest hue, greys by brightness")
    func nearestHue() {
        #expect(WarpTabColor.default(forProfileHex: "#FF0000") == .red)
        #expect(WarpTabColor.default(forProfileHex: "#00FF00") == .green)
        #expect(WarpTabColor.default(forProfileHex: "#0000FF") == .blue)
        #expect(WarpTabColor.default(forProfileHex: "#00FFFF") == .cyan)
        #expect(WarpTabColor.default(forProfileHex: "#FF00FF") == .magenta)
        #expect(WarpTabColor.default(forProfileHex: "#111111") == .black)
        #expect(WarpTabColor.default(forProfileHex: "#EEEEEE") == .white)
        #expect(WarpTabColor.default(forProfileHex: "not-a-colour") == .white)
    }

    // MARK: - TerminalName

    @Test("Suggested names are lowercase slugs without accents or symbols")
    func suggestions() {
        #expect(TerminalName.suggested(from: "4gentic Dev") == "4gentic-dev")
        #expect(TerminalName.suggested(from: "LincYou") == "lincyou")
        #expect(TerminalName.suggested(from: "Cuenta pa' compartir GPT") == "cuenta-pa-compartir-gpt")
        #expect(TerminalName.suggested(from: "Ñandú  Trabajo!!") == "nandu-trabajo")
        #expect(TerminalName.suggested(from: "  --  ") == "account")
        #expect(TerminalName.suggested(from: "🙂") == "account")
        let long = TerminalName.suggested(from: String(repeating: "abc ", count: 20))
        #expect(long.count <= TerminalName.maxLength)
        #expect(TerminalName.isValid(long))
    }

    @Test("Validity follows ^[a-z0-9][a-z0-9-]{0,30}$")
    func validity() {
        #expect(TerminalName.isValid("gpt"))
        #expect(TerminalName.isValid("4gentic-dev"))
        #expect(TerminalName.isValid("a"))
        #expect(!TerminalName.isValid(""))
        #expect(!TerminalName.isValid("-gpt"))
        #expect(!TerminalName.isValid("GPT"))
        #expect(!TerminalName.isValid("my account"))
        #expect(!TerminalName.isValid("gpt_2"))
        #expect(!TerminalName.isValid(String(repeating: "a", count: 32)))
    }

    @Test("Uniquing appends -2, -3 and stays within the length limit")
    func uniquing() {
        #expect(TerminalName.uniqued("gpt", taken: []) == "gpt")
        #expect(TerminalName.uniqued("gpt", taken: ["gpt"]) == "gpt-2")
        #expect(TerminalName.uniqued("gpt", taken: ["gpt", "gpt-2"]) == "gpt-3")
        let long = String(repeating: "a", count: 31)
        let uniqued = TerminalName.uniqued(long, taken: [long])
        #expect(uniqued.count <= TerminalName.maxLength)
        #expect(uniqued.hasSuffix("-2"))
        #expect(TerminalName.isValid(uniqued))
    }

    // MARK: - Token format, Keychain naming

    @Test("Only setup-token shaped tokens are plausible")
    func tokenFormat() {
        let token = "sk-ant-oat01-" + String(repeating: "x", count: 40)
        #expect(TerminalTokenFormat.isPlausible(token))
        #expect(TerminalTokenFormat.isPlausible("  \(token)\n"))
        #expect(!TerminalTokenFormat.isPlausible("sk-ant-oat01-short"))
        #expect(!TerminalTokenFormat.isPlausible("sk-ant-api03-" + String(repeating: "x", count: 40)))
        #expect(!TerminalTokenFormat.isPlausible("sk-ant-oat01-" + String(repeating: "x", count: 20) + " " + String(repeating: "y", count: 20)))
    }

    @Test("The Keychain service is keyed by profile id")
    func keychainService() {
        let id = UUID()
        #expect(TerminalTokenKeychain.service(for: id) == "TokenEater terminal token: \(id.uuidString)")
    }

    // MARK: - AccountProfile fields

    @Test("Profiles without the terminal fields decode with defaults; invalid names are dropped")
    func decodingDefaults() throws {
        let json = ##"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"4gentic Dev","colorHex":"#60A5FA","source":{"kind":"managed"},"terminalName":"Bad Name"}"##
        let profile = try JSONDecoder().decode(AccountProfile.self, from: Data(json.utf8))
        #expect(profile.terminalName == nil)
        #expect(profile.warpColor == nil)
        #expect(profile.terminalTokenSetAt == nil)
        #expect(profile.effectiveTerminalName == "4gentic-dev")
        #expect(profile.effectiveWarpColor == .blue)
        #expect(profile.terminalTokenExpiresAt == nil)
    }

    @Test("Terminal fields round-trip and drive the effective values")
    func roundTrip() throws {
        let setAt = Date(timeIntervalSince1970: 1_800_000_000)
        let profile = AccountProfile(name: "GPT", colorHex: "#F472B6", source: .managed,
                                     terminalName: "gpt", warpColor: .cyan, terminalTokenSetAt: setAt)
        let decoded = try JSONDecoder().decode(AccountProfile.self, from: JSONEncoder().encode(profile))
        #expect(decoded.terminalName == "gpt")
        #expect(decoded.warpColor == .cyan)
        #expect(decoded.terminalTokenSetAt == setAt)
        #expect(decoded.effectiveWarpColor == .cyan)
        #expect(decoded.terminalTokenExpiresAt == setAt.addingTimeInterval(365 * 24 * 3600))
    }
}
