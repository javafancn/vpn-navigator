import Darwin

/// The helper owns the listening endpoint before OpenVPN is spawned. With
/// --management-client the child exits itself if its controller disappears.
final class ManagementListener {
    private var descriptor: Int32 = -1
    private var ownsPath = false
    private let path: String

    init(path: String) throws {
        self.path = path
        guard path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count < 100 else { throw ManagementError.badPath }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ManagementError.socket }
        var bound = false, retained = false
        defer {
            if !retained { Darwin.close(fd); if bound { Darwin.unlink(path) } }
        }
        let flags = Darwin.fcntl(fd, F_GETFL)
        guard flags >= 0, Darwin.fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0,
              Darwin.fcntl(fd, F_SETFD, FD_CLOEXEC) >= 0 else { throw ManagementError.socket }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (offset, byte) in bytes.enumerated() { buffer[offset] = byte }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw ManagementError.unavailable }
        bound = true
        guard Darwin.chmod(path, mode_t(0o600)) == 0, Darwin.listen(fd, 1) == 0 else { throw ManagementError.socket }
        descriptor = fd; ownsPath = true; retained = true
    }
    func accept() throws -> Int32? {
        guard descriptor >= 0 else { throw ManagementError.socket }
        let peer = Darwin.accept(descriptor, nil, nil)
        if peer < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return nil }
            throw ManagementError.socket
        }
        var user: uid_t = 0, group: gid_t = 0
        let flags = Darwin.fcntl(peer, F_GETFL)
        guard Darwin.getpeereid(peer, &user, &group) == 0, user == 0,
              flags >= 0, Darwin.fcntl(peer, F_SETFL, flags & ~O_NONBLOCK) >= 0,
              Darwin.fcntl(peer, F_SETFD, FD_CLOEXEC) >= 0 else {
            Darwin.close(peer); throw ManagementError.socket
        }
        Darwin.close(descriptor); descriptor = -1
        return peer
    }
    func close() {
        if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
        if ownsPath { Darwin.unlink(path); ownsPath = false }
    }
    deinit { close() }
}
