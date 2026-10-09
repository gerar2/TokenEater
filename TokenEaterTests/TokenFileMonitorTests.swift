import Testing
import Foundation
import Combine

/// Thread-safe counter: the monitor emits on its own utility queue.
private final class EmissionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock(); defer { lock.unlock() }
        count += 1
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}

private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            Issue.record("Timed out after \(timeout)s waiting for the condition")
            return
        }
        try await Task.sleep(for: .milliseconds(20))
    }
}

@Suite("TokenFileMonitor")
struct TokenFileMonitorTests {

    @Test("the legacy init watches Claude Desktop config.json and ~/.claude/.credentials.json")
    func legacyEntries() {
        let files = TokenFileMonitor.legacyWatchedFiles(realHome: "/Users/tester")
        #expect(files.count == 2)
        #expect(files[0].directory == "/Users/tester/Library/Application Support/Claude")
        #expect(files[0].filename == "config.json")
        #expect(files[1].directory == "/Users/tester/.claude")
        #expect(files[1].filename == ".credentials.json")

        let monitor = TokenFileMonitor()
        #expect(monitor.watchedFiles.count == 2)
        #expect(monitor.watchedFiles.map(\.filename) == ["config.json", ".credentials.json"])
        #expect(monitor.watchedFiles[1].directory.hasSuffix("/.claude"))
    }

    @Test("watchedFiles de-duplicates directories and pairs while keeping insertion order")
    func deduplicatesEntries() {
        let monitor = TokenFileMonitor(watchedFiles: [
            (directory: "/a/.claude", filename: ".credentials.json"),
            (directory: "/a/.claude/", filename: ".credentials.json"),
            (directory: "/a/.claude", filename: "other.json"),
            (directory: "/b", filename: ".credentials.json"),
            (directory: "/b", filename: ".credentials.json"),
            (directory: "", filename: "ignored"),
            (directory: "/c", filename: ""),
        ])

        let files = monitor.watchedFiles.map { $0.directory + "/" + $0.filename }

        #expect(files == [
            "/a/.claude/.credentials.json",
            "/a/.claude/other.json",
            "/b/.credentials.json",
        ])
    }

    @Test("a watched file appearing emits once; a second change inside the debounce window is swallowed")
    func emitsOnceWithinDebounce() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenfilemonitor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let monitor = TokenFileMonitor(
            debounceInterval: 5,
            watchedFiles: [
                (directory: dir.path, filename: ".credentials.json"),
                (directory: dir.path, filename: "config.json"),
            ]
        )
        let counter = EmissionCounter()
        let subscription = monitor.tokenChanged.sink { counter.increment() }
        defer {
            subscription.cancel()
            monitor.stopMonitoring()
        }
        monitor.startMonitoring()

        // An unrelated entry changes the directory but not a watched file.
        try Data("x".utf8).write(to: dir.appendingPathComponent("unrelated.txt"))
        try await Task.sleep(for: .milliseconds(200))
        #expect(counter.value == 0)

        try Data("{}".utf8).write(to: dir.appendingPathComponent(".credentials.json"))
        try await waitUntil(timeout: 3) { counter.value >= 1 }
        #expect(counter.value == 1)

        // Inside the 5 s debounce window: detected, but not emitted again.
        try Data("{\"a\":1}".utf8).write(to: dir.appendingPathComponent("config.json"))
        try await Task.sleep(for: .milliseconds(300))
        #expect(counter.value == 1)
    }

    @Test("a missing directory is skipped without failing the others")
    func missingDirectoryIsSkipped() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenfilemonitor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let monitor = TokenFileMonitor(
            debounceInterval: 0.1,
            watchedFiles: [
                (directory: "/nonexistent/\(UUID().uuidString)", filename: ".credentials.json"),
                (directory: dir.path, filename: ".credentials.json"),
            ]
        )
        let counter = EmissionCounter()
        let subscription = monitor.tokenChanged.sink { counter.increment() }
        defer {
            subscription.cancel()
            monitor.stopMonitoring()
        }
        monitor.startMonitoring()

        try Data("{}".utf8).write(to: dir.appendingPathComponent(".credentials.json"))
        try await waitUntil(timeout: 3) { counter.value >= 1 }
        #expect(counter.value == 1)
    }
}
