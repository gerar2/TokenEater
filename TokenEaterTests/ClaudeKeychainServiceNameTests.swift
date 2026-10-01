import Testing
import Foundation
import CryptoKit

@Suite("ClaudeKeychainServiceName")
struct ClaudeKeychainServiceNameTests {
    private let home = "/Users/me"

    @Test("nil and the default directory map to the plain service name")
    func defaultDir() {
        #expect(ClaudeKeychainServiceName.service(forConfigDir: nil, realHome: home) == "Claude Code-credentials")
        #expect(ClaudeKeychainServiceName.service(forConfigDir: "/Users/me/.claude", realHome: home) == "Claude Code-credentials")
        #expect(ClaudeKeychainServiceName.service(forConfigDir: "~/.claude/", realHome: home) == "Claude Code-credentials")
        #expect(ClaudeKeychainServiceName.isDefaultDir("/Users/me/.claude", realHome: home))
        #expect(ClaudeKeychainServiceName.isDefaultDir("/Users/me/.claude-work", realHome: home) == false)
    }

    @Test("a custom directory gets the sha256 8-hex suffix of its normalised path")
    func customDir() {
        let dir = "/Users/me/.claude-work"
        let expected = SHA256.hash(data: Data(dir.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        #expect(ClaudeKeychainServiceName.service(forConfigDir: dir, realHome: home) == "Claude Code-credentials-\(expected)")
        #expect(expected.count == 8)
    }

    @Test("trailing slashes, ~ and dot components do not change the hash input")
    func normalisation() {
        #expect(ClaudeKeychainServiceName.normalize("~/.claude-work/", realHome: home) == "/Users/me/.claude-work")
        #expect(ClaudeKeychainServiceName.normalize("/Users/me//tmp/../.claude-work/./", realHome: home) == "/Users/me/.claude-work")
        #expect(ClaudeKeychainServiceName.normalize("~", realHome: home) == "/Users/me")
        let a = ClaudeKeychainServiceName.service(forConfigDir: "/Users/me/.claude-work/", realHome: home)
        let b = ClaudeKeychainServiceName.service(forConfigDir: "~/.claude-work", realHome: home)
        #expect(a == b)
    }

    @Test("matches the suffix observed from Claude Code 2.1.261")
    func knownVector() {
        // Observed: CLAUDE_CONFIG_DIR=<this path> -> "Claude Code-credentials-7719f642".
        let observed = "/private/tmp/claude-501/-Users-gerardo-tokeneater/068bb33a-3366-43e9-8ebe-95d7e26b1a67/scratchpad/cfg-test"
        #expect(ClaudeKeychainServiceName.hash8(observed) == "7719f642")
        #expect(ClaudeKeychainServiceName.service(forConfigDir: observed, realHome: "/Users/gerardo") == "Claude Code-credentials-7719f642")
    }
}
