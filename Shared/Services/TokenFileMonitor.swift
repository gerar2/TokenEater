import Foundation
import Combine

/// Watches the directories that hold credential files and emits on
/// `tokenChanged` when one of the watched files gets a new modification date.
///
/// The watcher is a `DispatchSource` on each *directory* (kqueue/vnode), not
/// on the files: Claude Code and Claude Desktop replace their files (write to
/// a temp file, then rename), which would invalidate a file-level watcher on
/// every write. A directory event is then filtered by comparing the watched
/// file's modification date so unrelated entries in the same directory never
/// trigger a refresh.
final class TokenFileMonitor: TokenFileMonitorProtocol {
    typealias WatchedFile = (directory: String, filename: String)

    private let subject = PassthroughSubject<Void, Never>()
    private var sources: [DispatchSourceFileSystemObject] = []
    private var fileDescriptors: [Int32] = []
    private let debounceInterval: TimeInterval
    private var lastEmit: Date = .distantPast
    private let queue = DispatchQueue(label: "com.tokeneater.filemonitor", qos: .utility)
    /// Insertion-ordered so `watchedFiles` is stable for diagnostics / tests.
    private let watchedDirectories: [String]
    /// directory -> filenames. A directory is opened once even when several
    /// profiles (or the legacy entries) point at it.
    private let watchedFilenames: [String: [String]]
    private var lastModDates: [String: Date] = [:]

    var tokenChanged: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }

    /// Legacy single-account behaviour: the Claude Desktop `config.json` and
    /// the default `~/.claude/.credentials.json`.
    convenience init(debounceInterval: TimeInterval = 2.0) {
        self.init(debounceInterval: debounceInterval, watchedFiles: Self.legacyWatchedFiles())
    }

    /// Multi-profile: `ProfileStore.watchedCredentialFiles` supplies one entry
    /// per linked config directory on top of the legacy pair. Duplicate
    /// (directory, filename) pairs are collapsed; a directory listed with two
    /// filenames is opened once and both files are checked on each event.
    init(debounceInterval: TimeInterval = 2.0, watchedFiles: [WatchedFile]) {
        self.debounceInterval = debounceInterval
        var directories: [String] = []
        var filenames: [String: [String]] = [:]
        for entry in watchedFiles {
            let dir = Self.normalizeDirectory(entry.directory)
            guard !dir.isEmpty, !entry.filename.isEmpty else { continue }
            if filenames[dir] == nil {
                directories.append(dir)
                filenames[dir] = []
            }
            if filenames[dir]?.contains(entry.filename) == false {
                filenames[dir]?.append(entry.filename)
            }
        }
        watchedDirectories = directories
        watchedFilenames = filenames
    }

    /// The de-duplicated list actually watched, in insertion order.
    var watchedFiles: [WatchedFile] {
        watchedDirectories.flatMap { dir in
            (watchedFilenames[dir] ?? []).map { (directory: dir, filename: $0) }
        }
    }

    /// The two entries the app watched before multi-profile support. `realHome`
    /// must be the real home (`getpwuid`), never a sandbox container.
    static func legacyWatchedFiles(realHome: String = ClaudeKeychainServiceName.realHome) -> [WatchedFile] {
        [
            (directory: realHome + "/Library/Application Support/Claude", filename: "config.json"),
            (directory: realHome + "/.claude", filename: ".credentials.json"),
        ]
    }

    func startMonitoring() {
        stopMonitoring()
        for dir in watchedDirectories {
            let fd = open(dir, O_EVTONLY)
            guard fd >= 0 else { continue }
            fileDescriptors.append(fd)
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: .write, queue: queue
            )
            source.setEventHandler { [weak self] in self?.handleDirectoryChange(dir) }
            source.setCancelHandler { close(fd) }
            sources.append(source)
            source.resume()
            // Record initial modification dates so the first event compares
            // against the state at start, not against "unknown".
            for filename in watchedFilenames[dir] ?? [] {
                let path = dir + "/" + filename
                lastModDates[path] = modDate(path)
            }
        }
    }

    func stopMonitoring() {
        for source in sources { source.cancel() }
        sources.removeAll()
        fileDescriptors.removeAll()
    }

    private func handleDirectoryChange(_ dir: String) {
        var changed = false
        for filename in watchedFilenames[dir] ?? [] {
            let path = dir + "/" + filename
            guard let date = modDate(path), date != lastModDates[path] else { continue }
            lastModDates[path] = date
            changed = true
        }
        guard changed else { return }
        let now = Date()
        guard now.timeIntervalSince(lastEmit) >= debounceInterval else { return }
        lastEmit = now
        subject.send(())
    }

    private func modDate(_ path: String) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
    }

    /// Strips trailing slashes so "/a/b/" and "/a/b" collapse to one watcher.
    private static func normalizeDirectory(_ directory: String) -> String {
        var dir = directory
        while dir.count > 1, dir.hasSuffix("/") { dir.removeLast() }
        return dir
    }

    deinit { stopMonitoring() }
}
