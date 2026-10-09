import Testing
import Foundation

@Suite("ClaudeConfigDirDetector")
struct ClaudeConfigDirDetectorTests {

    /// Builds a throwaway home directory. Caller removes it.
    private func makeHome() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccdd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func mkdir(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    private func touch(_ path: String) throws {
        try mkdir((path as NSString).deletingLastPathComponent)
        try Data("{}".utf8).write(to: URL(fileURLWithPath: path))
    }

    @Test("lists ~/.claude, ~/.claude-* and ~/.config/claude* directories that carry a marker")
    func detectsCandidates() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }

        try mkdir(home + "/.claude/projects")                    // default dir, sessions folder
        try touch(home + "/.claude.json")                         // home-level file, must not be listed
        try touch(home + "/.claude-work/.credentials.json")       // custom dir, file fallback store
        try touch(home + "/.config/claude-x/.claude.json")        // XDG-style custom dir
        try mkdir(home + "/.config/claude/projects")              // bare ~/.config/claude
        try mkdir(home + "/.claude-empty")                        // right prefix, no marker
        try touch(home + "/.notes/.claude.json")                  // marker, unrelated name
        try touch(home + "/.claude-file")                         // right prefix, but a file
        try mkdir(home + "/.config/other/projects")               // wrong prefix under .config

        let found = ClaudeConfigDirDetector.candidates(home: home)
        #expect(found == [
            home + "/.claude",
            home + "/.claude-work",
            home + "/.config/claude",
            home + "/.config/claude-x",
        ])
    }

    @Test("a trailing slash on the home path does not leak into the results")
    func trailingSlash() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try mkdir(home + "/.claude-work/projects")

        #expect(ClaudeConfigDirDetector.candidates(home: home + "/") == [home + "/.claude-work"])
    }

    @Test("an empty or missing home yields nothing")
    func emptyHome() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }

        #expect(ClaudeConfigDirDetector.candidates(home: home).isEmpty)
        #expect(ClaudeConfigDirDetector.candidates(home: home + "/does-not-exist").isEmpty)
    }

    @Test("looksLikeConfigDir accepts any single marker")
    func markers() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }

        try touch(home + "/a/.claude.json")
        try touch(home + "/b/.credentials.json")
        try mkdir(home + "/c/projects")
        try mkdir(home + "/d")

        #expect(ClaudeConfigDirDetector.looksLikeConfigDir(home + "/a"))
        #expect(ClaudeConfigDirDetector.looksLikeConfigDir(home + "/b/"))
        #expect(ClaudeConfigDirDetector.looksLikeConfigDir(home + "/c"))
        #expect(ClaudeConfigDirDetector.looksLikeConfigDir(home + "/d") == false)
    }

    @Test("suggested profile names strip the dot and the claude prefix")
    func suggestedNames() {
        #expect(ClaudeConfigDirDetector.suggestedName(forConfigDir: "/Users/me/.claude") == "Claude Code")
        #expect(ClaudeConfigDirDetector.suggestedName(forConfigDir: "/Users/me/.claude/") == "Claude Code")
        #expect(ClaudeConfigDirDetector.suggestedName(forConfigDir: "/Users/me/.claude-work") == "Work")
        #expect(ClaudeConfigDirDetector.suggestedName(forConfigDir: "/Users/me/.claude_personal") == "Personal")
        #expect(ClaudeConfigDirDetector.suggestedName(forConfigDir: "/Users/me/.config/claude-x") == "X")
        #expect(ClaudeConfigDirDetector.suggestedName(forConfigDir: "/Users/me/.config/claude") == "Claude Code")
        #expect(ClaudeConfigDirDetector.suggestedName(forConfigDir: "/Users/me/Accounts/acme") == "Acme")
        #expect(ClaudeConfigDirDetector.suggestedName(forConfigDir: "/Users/me/.claude-") == "Claude Code")
    }
}
