import Foundation
import Darwin

/// A stable inode shared by all repository instances and processes. Never
/// unlink the lock file: replacing it would let two writers lock different
/// inodes for the same repository. The kernel releases ownership on process exit.
final class ProfileStoreTransactionLock {
    static let filename = "profiles.lock"
    private let descriptor: Int32
    init(root: URL) throws {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw ProfileStoreLockError.unsafe }
        defer { close(directory) }
        var directoryInfo = stat()
        guard fstat(directory, &directoryInfo) == 0, directoryInfo.st_uid == getuid(),
              directoryInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), fchmod(directory, mode_t(0o700)) == 0 else { throw ProfileStoreLockError.unsafe }
        let fd = openat(directory, Self.filename, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw ProfileStoreLockError.unsafe }
        var retained = false
        defer { if !retained { close(fd) } }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_uid == getuid(), info.st_nlink == 1, info.st_size == 0,
              fchmod(fd, mode_t(0o600)) == 0 else { throw ProfileStoreLockError.unsafe }
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if errno == EINTR { continue }
            guard errno == EWOULDBLOCK || errno == EAGAIN else { throw ProfileStoreLockError.unsafe }
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ProfileStoreLockError.busy }
            Thread.sleep(forTimeInterval: 0.01)
        }
        var current = stat()
        guard fstatat(directory, Self.filename, &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_dev == info.st_dev, current.st_ino == info.st_ino,
              current.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), current.st_nlink == 1 else { throw ProfileStoreLockError.unsafe }
        descriptor = fd; retained = true
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}

public enum ProfileStoreLockError: Error, LocalizedError {
    case unsafe, busy
    public var errorDescription: String? {
        switch self {
        case .unsafe: return L10n.text("配置库事务锁无法安全核验，请检查目录权限及链接，未执行配置操作。")
        case .busy: return L10n.text("另一个应用实例正在使用配置库，请等待其操作完成后重试。")
        }
    }
}
