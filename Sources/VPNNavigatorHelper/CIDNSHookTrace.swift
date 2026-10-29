#if VPNNAV_LOCAL_TEST
import Foundation
import Darwin

/// Only a root-created synthetic fixture marker enables this private trace.
/// PUSH, certificate, authentication and credential lines are never recorded.
enum CIDNSHookTrace {
    static func record(_ line: String) {
        var info = stat()
        let marker = "/var/run/vpn-navigator/ci-managed-trace"
        guard lstat(marker, &info) == 0, info.st_uid == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_mode & 0o077 == 0,
              info.st_nlink == 1, info.st_size < 128,
              (try? String(contentsOfFile: marker, encoding: .utf8)) == "vpnnav-public-synthetic-dns-fixture\n" else { return }
        guard !line.contains("PUSH"), !line.contains("PASSWORD"),
              line.contains("macos-dns-updown.sh") || line.contains("dns up command") ||
              line.contains("dns down command") || line.contains("VPNNAV DNS adapter") ||
              line.contains("invalid OpenVPN DNS") || line.contains("DNS application failed") else { return }
        let fd = open("/var/run/vpn-navigator/ci-managed-dns.log", O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        guard fstat(fd, &info) == 0, info.st_uid == 0, info.st_nlink == 1, info.st_size < 250_000,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_mode & 0o077 == 0 else { return }
        let data = Data((String(line.prefix(2048)) + "\n").utf8)
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }
}
#endif
