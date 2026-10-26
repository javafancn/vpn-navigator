import Foundation
import Darwin

public struct ConnectionHistoryState: Sendable {
    public let records: [ConnectionHistoryRecord]
    public let preferences: ConnectionHistoryPreferences
    public let quality: ConnectionQualitySnapshot
    public let problem: String?
    public init(records: [ConnectionHistoryRecord] = [], preferences: ConnectionHistoryPreferences = .init(), quality: ConnectionQualitySnapshot = .init(), problem: String? = nil) {
        self.records = records; self.preferences = preferences; self.quality = quality; self.problem = problem
    }
}

/// A private, bounded local archive. Persistence errors never control the VPN.
/// Counter-only checkpoints are throttled to 30 seconds; transitions flush now.
public actor ConnectionHistoryStore {
    private let directory: URL
    private var file: URL { directory.appendingPathComponent("history.json") }
    private var tracker = ConnectionHistoryTracker()
    private var loaded = false
    private var blocked = false
    private var problem: String?
    private var dirty = false
    private var lastSave: Double?
    public init(directory: URL) {
        self.directory = directory.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(directory.lastPathComponent)
    }
    public func open(now: Date = Date(), uptime: Double = ProcessInfo.processInfo.systemUptime) -> ConnectionHistoryState {
        if !loaded {
            loaded = true
            do {
                try prepare()
                var archive = ConnectionHistoryArchive()
                if try exists() {
                    let data = try ProfileFileIO.read(file, maximumBytes: 2_000_000)
                    do { archive = try JSONDecoder().decode(ConnectionHistoryArchive.self, from: data); try archive.validate() }
                    catch { throw ConnectionHistoryFailure.invalidArchive }
                }
                tracker = ConnectionHistoryTracker(archive: archive, now: now)
                try write(tracker.archive); lastSave = uptime
            } catch {
                blocked = true; problem = (error as? ConnectionHistoryFailure)?.errorDescription ?? ConnectionHistoryFailure.storage.errorDescription
                var empty = ConnectionHistoryArchive(); empty.preferences.enabled = false
                tracker = .init(archive: empty, now: now)
            }
        }
        return state()
    }
    public func consume(_ input: ConnectionHistoryInput, date: Date, uptime: Double) -> ConnectionHistoryState {
        _ = open(now: date, uptime: uptime)
        let previous = tracker.archive
        tracker.consume(input, at: date, uptime: uptime)
        let next = tracker.archive
        if next != previous { dirty = true }
        let transition = next.records.map { $0.events.last?.id } != previous.records.map { $0.events.last?.id }
        if !blocked, dirty, transition || lastSave == nil || uptime < lastSave! || uptime - lastSave! >= 30 {
            do { try write(next); dirty = false; lastSave = uptime; problem = nil }
            catch { problem = ConnectionHistoryFailure.storage.errorDescription }
        }
        return state()
    }
    public func configure(_ preferences: ConnectionHistoryPreferences, now: Date = Date()) throws -> ConnectionHistoryState {
        _ = open(now: now)
        guard !blocked else { throw ConnectionHistoryFailure.invalidArchive }
        var next = tracker
        try next.configure(preferences, now: now)
        do { try write(next.archive) } catch { problem = ConnectionHistoryFailure.storage.errorDescription; throw ConnectionHistoryFailure.storage }
        tracker = next; dirty = false; lastSave = ProcessInfo.processInfo.systemUptime; problem = nil
        return state()
    }
    public func clearAndPause(now: Date = Date()) throws -> ConnectionHistoryState {
        _ = open(now: now)
        var next = tracker; next.clearAndPause(now: now)
        // User-authorized replacement can clear malformed ordinary files, but
        // never a link, special file or another user's file.
        do { try write(next.archive) } catch { problem = ConnectionHistoryFailure.storage.errorDescription; throw ConnectionHistoryFailure.storage }
        tracker = next; blocked = false; dirty = false; lastSave = ProcessInfo.processInfo.systemUptime; problem = nil
        return state()
    }
    private func state() -> ConnectionHistoryState { .init(records: tracker.records, preferences: tracker.preferences, quality: tracker.quality, problem: problem) }
    private func exists() throws -> Bool {
        var info = stat()
        if lstat(file.path, &info) != 0 { if errno == ENOENT { return false }; throw ConnectionHistoryFailure.storage }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == getuid() else { throw ConnectionHistoryFailure.storage }
        return true
    }
    private func prepare() throws {
        var parent = stat(), info = stat()
        guard lstat(directory.deletingLastPathComponent().path, &parent) == 0, parent.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), parent.st_uid == getuid() else { throw ConnectionHistoryFailure.storage }
        if lstat(directory.path, &info) != 0 {
            guard errno == ENOENT else { throw ConnectionHistoryFailure.storage }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            guard lstat(directory.path, &info) == 0 else { throw ConnectionHistoryFailure.storage }
        }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), info.st_uid == getuid() else { throw ConnectionHistoryFailure.storage }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    private func write(_ archive: ConnectionHistoryArchive) throws {
        try prepare(); _ = try exists(); try archive.validate()
        let bytes = try JSONEncoder().encode(archive)
        guard bytes.count <= 2_000_000 else { throw ConnectionHistoryFailure.storage }
        try ProfileFileIO.write(bytes, to: file)
    }
}
