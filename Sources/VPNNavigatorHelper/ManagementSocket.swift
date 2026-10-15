import Foundation
import Darwin
import VPNNavigatorCore

/// Root-private Unix management interface. Never expose the management socket
/// outside its root-owned 0700 runtime directory.
final class ManagementSocket {
    private var descriptor: Int32 = -1
    private let queue = DispatchQueue(label: "VPNNavigator.Management")
    private var buffer = Data()
    private var credentials: (username: String, password: String)?
    var onState: ((TunnelSnapshot) -> Void)?
    var onTraffic: ((TunnelTraffic) -> Void)?
    var onExit: (() -> Void)?
    var onUnsupportedChallenge: (() -> Void)?
    var onAuthenticationFailure: (() -> Void)?

    func setCredentials(username: String, password: String) {
        credentials = (username, password)
    }

    func open(path: String) throws {
        guard path.utf8.count < 100 else { throw ManagementError.badPath }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ManagementError.socket }
        var noSigPipe: Int32 = 1
        _ = withUnsafePointer(to: &noSigPipe) {
            Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, $0,
                              socklen_t(MemoryLayout<Int32>.size))
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { data in
            for (index, byte) in bytes.enumerated() { data[index] = byte }
        }
        let rc: Int32 = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { Darwin.close(fd); throw ManagementError.unavailable }
        descriptor = fd
        try send("state on")
        try send("bytecount 3")
        try send("hold release")
        queue.async { [weak self] in self?.readLoop() }
    }

    func send(_ command: String) throws {
        guard descriptor >= 0, !command.contains("\n"), !command.contains("\r") else {
            throw ManagementError.socket
        }
        let data = Array((command + "\n").utf8)
        var position = 0
        while position < data.count {
            let written = data.withUnsafeBytes { input in
                Darwin.write(descriptor, input.baseAddress!.advanced(by: position), data.count - position)
            }
            guard written > 0 else { throw ManagementError.socket }
            position += written
        }
    }

    func close() {
        if descriptor >= 0 {
            Darwin.shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
            descriptor = -1
        }
        credentials = nil
    }

    private func readLoop() {
        var chunk = [UInt8](repeating: 0, count: 8192)
        while descriptor >= 0 {
            let size = chunk.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if size <= 0 { break }
            buffer.append(contentsOf: chunk.prefix(size))
            guard buffer.count < 1_048_576 else { break }
            while let newline = buffer.firstIndex(of: 10) {
                let line = String(decoding: buffer[..<newline], as: UTF8.self)
                buffer.removeSubrange(...newline)
                if let snapshot = ManagementParser.parseState(line) {
                    onState?(snapshot)
                } else if let traffic = ManagementParser.parseByteCount(line) {
                    onTraffic?(traffic)
                } else if line.hasPrefix(">PASSWORD:Verification Failed:") {
                    onAuthenticationFailure?()
                    close()
                    break
                } else if line.hasPrefix(">PASSWORD:Need ") {
                    // Bare auth-user-pass supported; all other challenges (including
                    // encrypted key / proxy auth) require an explicit future adapter.
                    if ManagementParser.parsePasswordChallenge(line), let credentials {
                        do {
                            try send("username \"Auth\" \"\(ManagementEscaping.escape(credentials.username))\"")
                            try send("password \"Auth\" \"\(ManagementEscaping.escape(credentials.password))\"")
                        } catch {
                            onUnsupportedChallenge?()
                            close()
                            break
                        }
                    } else {
                        onUnsupportedChallenge?()
                        close()
                        break
                    }
                }
            }
        }
        close()
        onExit?()
    }
}
enum ManagementError: Error { case badPath, socket, unavailable }
