import Foundation
import Darwin

/// Bounded ordinary-user reads and private, atomic profile publication.
public enum ProfileFileIO {
    public static func read(_ url: URL, maximumBytes: Int = 2_000_000, followSymlinks: Bool = false) throws -> Data {
        guard (1...16_000_000).contains(maximumBytes) else { throw Failure.tooLarge }
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | (followSymlinks ? 0 : O_NOFOLLOW))
        guard descriptor >= 0 else { throw Failure.unreadable }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw Failure.notRegular }
        guard info.st_size >= 0, info.st_size <= off_t(maximumBytes) else { throw Failure.tooLarge }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while result.count <= maximumBytes {
            let requested = min(buffer.count, maximumBytes + 1 - result.count)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, requested) }
            if count < 0 { if errno == EINTR { continue }; throw Failure.unreadable }
            if count == 0 { return result }
            result.append(contentsOf: buffer.prefix(count))
        }
        throw Failure.tooLarge
    }
    public static func write(_ data: Data, to url: URL, beforeCommit: (() throws -> Void)? = nil) throws {
        try beforeCommit?()
        guard data.count <= 16_000_000 else { throw Failure.tooLarge }
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else { throw Failure.unsafeDestination }
        let directory = open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw Failure.cannotWrite }
        defer { close(directory) }
        func checkDestination() throws {
            var info = stat()
            if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw Failure.unsafeDestination }
            } else if errno != ENOENT { throw Failure.cannotWrite }
        }
        try checkDestination()
        let temporary = ".vpnnav-export-" + UUID().uuidString
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw Failure.cannotWrite }
        defer { close(descriptor); unlinkat(directory, temporary, 0) }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else { throw Failure.cannotWrite }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try beforeCommit?()
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw Failure.cannotWrite }
                guard count > 0 else { throw Failure.cannotWrite }
                offset += count
            }
        }
        var info = stat()
        guard fsync(descriptor) == 0, fstat(descriptor, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_mode & 0o077 == 0,
              info.st_uid == getuid() else { throw Failure.cannotWrite }
        try beforeCommit?()
        try checkDestination()
        guard renameat(directory, temporary, directory, name) == 0 else { throw Failure.cannotWrite }
        _ = fsync(directory)
    }
    public enum Failure: Error, LocalizedError {
        case unreadable, notRegular, tooLarge, unsafeDestination, cannotWrite
        public var errorDescription: String? {
            switch self {
            case .unreadable: return "无法读取所选文件，请检查访问权限。"
            case .notRegular: return "所选项目不是普通文件。"
            case .tooLarge: return "文件超过支持的大小限制。"
            case .unsafeDestination: return "保存位置是链接或特殊文件，请选择普通文件位置。"
            case .cannotWrite: return "无法安全保存文件，请选择可写且支持私有文件权限的位置。"
            }
        }
    }
}
