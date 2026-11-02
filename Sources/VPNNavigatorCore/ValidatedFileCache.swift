import Foundation
import Darwin

/// Reuse expensive validation only while every protected input has the same
/// inode, ownership, mode, size and nanosecond timestamps. Never caches errors.
/// Callers must fully validate root-owned, non-user-writable inputs on a miss.
final class ValidatedFileCache<Value> {
    private struct Stamp: Equatable {
        let device: dev_t
        let inode: ino_t
        let mode: mode_t
        let owner: uid_t
        let group: gid_t
        let links: nlink_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanos: Int
        let changedSeconds: Int
        let changedNanos: Int
        let birthSeconds: Int
        let birthNanos: Int
        init(_ info: stat) {
            device = info.st_dev; inode = info.st_ino; mode = info.st_mode
            owner = info.st_uid; group = info.st_gid; links = info.st_nlink; size = info.st_size
            modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanos = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec; changedNanos = info.st_ctimespec.tv_nsec
            birthSeconds = info.st_birthtimespec.tv_sec; birthNanos = info.st_birthtimespec.tv_nsec
        }
    }
    private let lock = NSLock()
    private var cached: (paths: [URL], stamps: [Stamp?], value: Value)?

    func value(paths: [URL], force: Bool = false, validate: () throws -> Value) throws -> Value {
        lock.lock(); defer { lock.unlock() }
        let before: [Stamp?]
        do { before = try snapshot(paths) }
        catch { cached = nil; throw error }
        if !force, let cached, cached.paths == paths, cached.stamps == before { return cached.value }
        cached = nil
        let value = try validate()
        // A successful validation of changing inputs cannot authorize reuse.
        guard try snapshot(paths) == before else { throw LocalInstallError.altered }
        cached = (paths, before, value)
        return value
    }
    private func snapshot(_ paths: [URL]) throws -> [Stamp?] {
        try paths.map { path in
            var info = stat()
            if lstat(path.path, &info) == 0 { return Stamp(info) }
            if errno == ENOENT { return nil }
            throw LocalInstallError.unsafe
        }
    }
}
