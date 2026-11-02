import Foundation
import Darwin

// Only the two production error cases referenced by the cache. The actual
// cache source is compiled unchanged; file operations use real private files.
enum LocalInstallError: Error { case unsafe, altered }
@main struct ValidationCacheRegression {
    static func require(_ value: Bool, _ reason: String) { precondition(value, reason) }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vpnnav-validation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("payload"), pending = root.appendingPathComponent("pending")
        try Data("good".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let cache = ValidatedFileCache<String>()
        var validations = 0
        func load(force: Bool = false) throws -> String {
            try cache.value(paths: [root, file, pending], force: force) {
                validations += 1
                guard !FileManager.default.fileExists(atPath: pending.path) else { throw LocalInstallError.unsafe }
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                      try String(contentsOf: file) == "good" else { throw LocalInstallError.altered }
                return "approved"
            }
        }
        _ = try load()
        for _ in 0..<100 { _ = try load() }
        require(validations == 1, "Unchanged inputs repeatedly validated")
        _ = try load(force: true)
        require(validations == 2, "Critical operation did not force validation")
        var original = stat(); require(lstat(file.path, &original) == 0, "stat failed")
        usleep(2000)
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data("evil".utf8)); try handle.close()
        var times = [original.st_atimespec, original.st_mtimespec]
        require(utimensat(AT_FDCWD, file.path, &times, 0) == 0, "mtime restore failed")
        for _ in 0..<2 {
            do { _ = try load(); fatalError("Modified bytes with restored mtime reused approval") }
            catch LocalInstallError.altered {}
        }
        require(validations == 4, "Failed validation was cached")
        try Data("good".utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        _ = try load()
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: file.path)
        do { _ = try load(); fatalError("Writable payload reused approval") } catch LocalInstallError.altered {}
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        _ = try load()
        try Data().write(to: pending)
        do { _ = try load(); fatalError("Pending installation reused approval") } catch LocalInstallError.unsafe {}
        try FileManager.default.removeItem(at: pending); _ = try load()
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: pending)
        do { _ = try load(); fatalError("Symlink reused approval") } catch {}
        try FileManager.default.removeItem(at: file)
        try Data("good".utf8).write(to: file)
        let unstable = ValidatedFileCache<Int>()
        do {
            _ = try unstable.value(paths: [file]) {
                try Data("changed".utf8).write(to: file, options: .atomic)
                return 1
            }
            fatalError("Input replacement during validation accepted")
        } catch LocalInstallError.altered {}
        let concurrent = ValidatedFileCache<Int>()
        var calls = 0
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            let result = try! concurrent.value(paths: [file]) { calls += 1; return 42 }
            require(result == 42, "Concurrent validation changed value")
        }
        require(calls == 1, "Concurrent misses rehashed repeatedly")
        let forced = ValidatedFileCache<Int>()
        _ = try forced.value(paths: [file]) { 1 }
        do {
            _ = try forced.value(paths: [file], force: true) { throw LocalInstallError.altered }
            fatalError("Forced validation error ignored")
        } catch LocalInstallError.altered {}
        let afterFailure = try forced.value(paths: [file]) { 2 }
        require(afterFailure == 2, "Forced failure retained earlier approval")
        print("PASS: unchanged-file reuse, forced validation, changed bytes/restored mtime, permissions, atomic replacement, pending install, symlink, concurrent loads and uncached failures")
    }
}
