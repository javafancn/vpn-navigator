import Foundation
import Darwin
import VPNNavigatorCore

/// Root-private Unix management interface. The read loop owns its descriptor
/// until shutdown completes, preventing close/read races and descriptor reuse.
final class ManagementSocket {
    private let ioLock = NSRecursiveLock()
    private var authentication = ManagementAuthentication()
    private var descriptor: Int32 = -1
    private var readerRunning = false
    private var closed = false
    private let queue = DispatchQueue(label: "VPNNavigator.Management")
    var onChallenge: ((AuthenticationChallenge) -> Void)?
    var onState: ((TunnelSnapshot) -> Void)?
    var onTraffic: ((TunnelTraffic) -> Void)?
    var onExit: (() -> Void)?
    var onUnsupportedChallenge: (() -> Void)?
    var onAuthenticationFailure: (() -> Void)?

    func setCredentials(username: String, password: String) {
        ioLock.lock(); defer { ioLock.unlock() }
        authentication.setCredentials(username: username, password: password)
    }
    func open(path: String) throws {
        ioLock.lock(); defer { ioLock.unlock() }
        guard !closed, !readerRunning, descriptor < 0, path.utf8.count < 100 else { throw ManagementError.badPath }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ManagementError.socket }
        var noSigPipe: Int32 = 1
        var writeTimeout = timeval(tv_sec: 2, tv_usec: 0)
        guard withUnsafePointer(to: &noSigPipe, { Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size)) }) == 0,
              withUnsafePointer(to: &writeTimeout, { Darwin.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, $0, socklen_t(MemoryLayout<timeval>.size)) }) == 0 else {
            Darwin.close(fd); throw ManagementError.socket
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
        do {
            try send("state on"); try send("bytecount 3"); try send("hold release")
        } catch { close(); throw error }
        readerRunning = true
        queue.async { self.readLoop(fd: fd) }
    }
    func send(_ command: String) throws {
        ioLock.lock(); defer { ioLock.unlock() }
        guard !closed, descriptor >= 0, command.utf8.count < 16_384,
              !command.unicodeScalars.contains(where: { CharacterSet.controlCharacters.union(.newlines).contains($0) }) else {
            throw ManagementError.socket
        }
        let data = Array((command + "\n").utf8)
        var position = 0
        while position < data.count {
            let written = data.withUnsafeBytes { input in
                Darwin.write(descriptor, input.baseAddress!.advanced(by: position), data.count - position)
            }
            if written < 0 && errno == EINTR { continue }
            guard written > 0 else { throw ManagementError.socket }
            position += written
        }
    }
    func close() {
        ioLock.lock(); defer { ioLock.unlock() }
        closed = true
        authentication = ManagementAuthentication()
        if descriptor >= 0 {
            Darwin.shutdown(descriptor, SHUT_RDWR)
            // Only the reader closes an active descriptor. shutdown wakes it.
            if !readerRunning { Darwin.close(descriptor); descriptor = -1 }
        }
    }
    func respond(id: String, response: String) throws {
        ioLock.lock(); defer { ioLock.unlock() }
        guard !closed else { throw ChallengeResponseError.stale }
        let commands = try authentication.respond(id: id, response: response)
        do { for command in commands { try send(command) } }
        catch { close(); throw error }
    }
    private func consume(_ line: String) -> Bool {
        ioLock.lock(); defer { ioLock.unlock() }
        guard !closed else { return false }
        if let snapshot = ManagementParser.parseState(line) {
            onState?(authentication.transition(snapshot))
        } else if let traffic = ManagementParser.parseByteCount(line) {
            onTraffic?(traffic)
        } else if let event = authentication.receive(line) {
            switch event {
            case .commands(let commands):
                do { for command in commands { try send(command) } }
                catch { onUnsupportedChallenge?(); close(); return false }
            case .challenge(let challenge): onChallenge?(challenge)
            case .failed: onAuthenticationFailure?(); close(); return false
            case .unsupported: onUnsupportedChallenge?(); close(); return false
            }
        }
        return !closed
    }
    private func readLoop(fd: Int32) {
        defer {
            ioLock.lock()
            closed = true; authentication = ManagementAuthentication()
            Darwin.close(fd); descriptor = -1; readerRunning = false
            ioLock.unlock()
            onExit?()
        }
        var buffer = Data(), chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            let size = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if size < 0 && errno == EINTR { continue }
            if size <= 0 { return }
            buffer.append(contentsOf: chunk.prefix(size))
            guard buffer.count < 65_536 else { onUnsupportedChallenge?(); return }
            while let newline = buffer.firstIndex(of: 10) {
                guard var line = String(data: buffer[..<newline], encoding: .utf8) else { onUnsupportedChallenge?(); return }
                if line.hasSuffix("\r") { line.removeLast() }
                buffer.removeSubrange(...newline)
                guard consume(line) else { return }
            }
        }
    }
}
enum ManagementError: Error { case badPath, socket, unavailable }
