import Foundation
import Darwin
import VPNNavigatorCore

/// A single-owner OpenVPN Unix management socket, used only inside the root daemon.
/// The socket is created by OpenVPN in a 0700 root-owned runtime directory.
final class ManagementSocket {
    private var descriptor: Int32 = -1
    private let queue = DispatchQueue(label: "VPNNavigator.Management")
    private var buffer = Data()
    var onState: ((TunnelSnapshot) -> Void)?
    var onExit: (() -> Void)?

    func open(path: String) throws {
        guard path.utf8.count < 100 else { throw ManagementError.badPath }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ManagementError.socket }
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
        try send("hold release")
        queue.async { [weak self] in self?.readLoop() }
    }
    func send(_ command: String) throws {
        guard descriptor >= 0, !command.contains("\n"), !command.contains("\r") else {
            throw ManagementError.socket
        }
        let bytes = Array((command + "\n").utf8)
        let sent = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, bytes.count) }
        guard sent == bytes.count else { throw ManagementError.socket }
    }
    func close() {
        if descriptor >= 0 {
            Darwin.shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
            descriptor = -1
        }
    }
    private func readLoop() {
        var chunk = [UInt8](repeating: 0, count: 8192)
        while descriptor >= 0 {
            let size = Darwin.read(descriptor, &chunk, chunk.count)
            if size <= 0 { break }
            buffer.append(contentsOf: chunk.prefix(size))
            guard buffer.count < 1_048_576 else { break }
            while let newline = buffer.firstIndex(of: 10) {
                let line = String(decoding: buffer[..<newline], as: UTF8.self)
                buffer.removeSubrange(...newline)
                if let snapshot = ManagementParser.parseState(line) {
                    onState?(snapshot)
                }
            }
        }
        close()
        onExit?()
    }
}
enum ManagementError: Error { case badPath, socket, unavailable }
