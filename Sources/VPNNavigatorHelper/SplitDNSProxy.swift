import Foundation
import Network
import Darwin
import VPNNavigatorCore

/// Session-owned loopback UDP/TCP relay. No cache or query logging; macOS
/// retains its TTL cache. All IO runs independently of route application.
/// Unlisted names and domestic failures use only VPN upstreams.
final class SplitDNSProxy {
    struct Upstream { let address: String; var port: UInt16 = 53 }
    private let queue = DispatchQueue(label: "VPNNavigator.SplitDNS")
    private let domains: ChinaDNSDomains
    private let domestic: [Upstream]
    private let vpn: [Upstream]
    private var listeners: [NWListener] = []
    private var udpDescriptor: Int32 = -1
    private var udpSource: DispatchSourceRead?
    private final class Client {
        let connection: NWConnection
        var pending = 0
        var readingFrame = true
        var lastUsed = ProcessInfo.processInfo.systemUptime
        var mayEvict: Bool { pending == 0 && !readingFrame }
        init(_ connection: NWConnection) { self.connection = connection }
    }
    private var clients: [UUID: Client] = [:]
    private var idleTimer: DispatchSourceTimer?
    private var requests: [UUID: DNSResolution] = [:]
    private var stopped = false
    private(set) var port: UInt16 = 0
    init(domains: ChinaDNSDomains, domestic: [Upstream], vpn: [Upstream]) {
        self.domains = domains; self.domestic = domestic; self.vpn = vpn
    }
    func start() throws {
        guard !vpn.isEmpty, listeners.isEmpty else { throw DNSJournalError.unavailable }
        do {
            let tcp = try listenTCP(port: .any)
            guard let bound = tcp.port else { throw DNSJournalError.unavailable }
            port = bound.rawValue
            try listenUDP(port: bound.rawValue)
            queue.sync {
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + 1, repeating: .seconds(1))
                timer.setEventHandler { [weak self] in
                    guard let self else { return }
                    let now = ProcessInfo.processInfo.systemUptime
                    let expired = self.clients.filter { $0.value.pending == 0 && now - $0.value.lastUsed >= 10 }.map(\.key)
                    expired.forEach { self.close($0) }
                }
                idleTimer = timer; timer.resume()
            }
        } catch { stop(); throw error }
    }
    private func listenUDP(port: UInt16) throws {
        let descriptor = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { throw DNSJournalError.unavailable }
        var capacity: Int32 = 262_144
        let buffered = withUnsafePointer(to: &capacity) {
            setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, $0, socklen_t(MemoryLayout<Int32>.size)) == 0 &&
            setsockopt(descriptor, SOL_SOCKET, SO_SNDBUF, $0, socklen_t(MemoryLayout<Int32>.size)) == 0
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = UInt32(0x7f000001).bigEndian
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard buffered, bound == 0, fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
              fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            Darwin.close(descriptor); throw DNSJournalError.unavailable
        }
        queue.sync {
            udpDescriptor = descriptor
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self] in self?.readUDPDatagrams() }
            source.setCancelHandler { Darwin.close(descriptor) }
            udpSource = source; source.resume()
        }
    }
    private func stopUDP() {
        udpDescriptor = -1
        udpSource?.cancel(); udpSource = nil
    }
    private func readUDPDatagrams() {
        let descriptor = udpDescriptor
        guard descriptor >= 0, !stopped else { return }
        var buffer = [UInt8](repeating: 0, count: 65_535)
        // Bound work per queue turn so upstream completions and TCP clients
        // keep progressing during a UDP burst. UDP has no per-source slots;
        // the existing 128 in-flight query budget bounds upstream resources.
        for _ in 0..<32 {
            var peer = sockaddr_in(), length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = buffer.withUnsafeMutableBytes { bytes in
                withUnsafeMutablePointer(to: &peer) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.recvfrom(descriptor, bytes.baseAddress, bytes.count, 0, $0, &length)
                    }
                }
            }
            if count < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK { stopUDP() }
                return
            }
            guard length == MemoryLayout<sockaddr_in>.size, peer.sin_family == AF_INET,
                  UInt32(bigEndian: peer.sin_addr.s_addr) >> 24 == 127 else { continue }
            let data = Data(buffer.prefix(count))
            query(data, tcp: false) { [weak self] response in
                guard let self, !self.stopped, self.udpDescriptor == descriptor, !response.isEmpty else { return }
                var destination = peer
                _ = response.withUnsafeBytes { bytes in
                    withUnsafePointer(to: &destination) { pointer in
                        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            Darwin.sendto(descriptor, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            }
        }
        // Drain a large burst on later turns even if no further packet
        // arrives to trigger another readiness notification.
        queue.async { [weak self] in self?.readUDPDatagrams() }
    }
    private func listenTCP(port: NWEndpoint.Port) throws -> NWListener {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        let listener = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        var succeeded = false
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: succeeded = true; ready.signal()
            case .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listeners.append(listener); listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 3) == .success, succeeded else { throw DNSJournalError.unavailable }
        return listener
    }
    func stop() {
        queue.sync {
            stopped = true
            stopUDP()
            idleTimer?.cancel(); idleTimer = nil
            listeners.forEach { $0.cancel() }; listeners.removeAll()
            let openClients = Array(clients.values); clients.removeAll()
            openClients.forEach { $0.connection.cancel() }
            let pending = Array(requests.values); requests.removeAll()
            pending.forEach { $0.cancel() }
        }
    }
    func verify() throws {
        guard queue.sync(execute: { !stopped && udpDescriptor >= 0 && udpSource != nil && listeners.count == 1 && listeners.allSatisfy { $0.state == .ready } }) else {
            throw DNSJournalError.unavailable
        }
    }
    private func accept(_ connection: NWConnection) {
        guard !stopped else { connection.cancel(); return }
        // Reclaim only idle TCP clients. New/partial frames and requests
        // awaiting upstream or send completion cannot be evicted.
        if clients.count >= 64, let oldest = clients.filter({ $0.value.mayEvict })
            .min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key { close(oldest) }
        guard clients.count < 128 else { connection.cancel(); return }
        let id = UUID(); clients[id] = Client(connection)
        connection.stateUpdateHandler = { [weak self] state in
            switch state { case .failed, .cancelled: self?.close(id); default: break }
        }
        connection.start(queue: queue)
        readTCP(connection, id: id)
    }
    private func close(_ id: UUID) { clients.removeValue(forKey: id)?.connection.cancel() }
    private func readTCP(_ connection: NWConnection, id: UUID) {
        read(connection, id: id, count: 2) { [weak self] prefix in
            guard let self, let prefix, self.clients[id] != nil else { self?.close(id); return }
            let length = Int(prefix[0]) << 8 | Int(prefix[1])
            guard length >= 17 else { self.close(id); return }
            self.read(connection, id: id, count: length) { [weak self] data in
                guard let self, let data else { self?.close(id); return }
                self.respond(data, connection: connection, id: id, tcp: true)
            }
        }
    }
    private func respond(_ data: Data, connection: NWConnection, id: UUID, tcp: Bool) {
        guard let client = clients[id] else { return }
        client.readingFrame = false; client.pending += 1
        client.lastUsed = ProcessInfo.processInfo.systemUptime
        query(data, tcp: tcp) { [weak self] response in
            guard let self, self.clients[id] === client else { return }
            guard !response.isEmpty else {
                client.pending -= 1
                if tcp { self.close(id) }
                return
            }
            let content = tcp ? Data([UInt8(response.count >> 8), UInt8(response.count & 255)]) + response : response
            connection.send(content: content, completion: .contentProcessed { [weak self] error in
                guard let self, self.clients[id] === client else { return }
                client.pending -= 1; client.lastUsed = ProcessInfo.processInfo.systemUptime
                if error != nil { self.close(id) }
                else if tcp { self.readTCP(connection, id: id) }
            })
        }
    }
    private func read(_ connection: NWConnection, id: UUID, count: Int, buffer: Data = Data(), done: @escaping (Data?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: count - buffer.count) { [weak self] data, _, complete, error in
            guard let self, let client = self.clients[id] else { done(nil); return }
            if let data, !data.isEmpty {
                client.readingFrame = true; client.lastUsed = ProcessInfo.processInfo.systemUptime
            }
            var next = buffer; if let data { next.append(data) }
            if next.count == count { done(next) }
            else if complete || error != nil || data?.isEmpty != false { done(nil) }
            else { self.read(connection, id: id, count: count, buffer: next, done: done) }
        }
    }
    private func query(_ data: Data, tcp: Bool, done: @escaping (Data) -> Void) {
        guard !stopped, let question = DNSQuestion(data) else { done(Data()); return }
        guard requests.count < 128 else { done(question.failure(for: data)); return }
        // Hedge only within the same policy group. A domestic timeout must
        // finish its group before VPN fallback; an unlisted query never has
        // a domestic group. Fast healthy resolvers still receive one request.
        let groups = (domains.contains(question.name) && !domestic.isEmpty ? [domestic] : []) + [vpn]
        let id = UUID()
        let request = DNSResolution(queue: queue, groups: groups, tcp: tcp, data: data, question: question) { [weak self] result in
            guard let self else { return }; self.requests.removeValue(forKey: id)
            guard !self.stopped else { return }
            if var result { result[0] = data[0]; result[1] = data[1]; done(result) }
            else { done(question.failure(for: data)) }
        }
        requests[id] = request; request.start()
    }
}

/// At most two live upstream sockets per request; the second starts after
/// 250 ms or an immediate first failure. First valid success cancels losers.
/// This avoids a repeated two-second stall on a blackholed primary resolver
/// without broadcasting healthy queries or racing across privacy boundaries.
private final class DNSResolution {
    private let queue: DispatchQueue
    private var groups: [[SplitDNSProxy.Upstream]]
    private var remaining: [SplitDNSProxy.Upstream] = []
    private let tcp: Bool
    private let data: Data
    private let question: DNSQuestion
    private var active: [UUID: DNSExchange] = [:]
    private var hedge: DispatchWorkItem?
    private var completion: ((Data?) -> Void)?

    init(queue: DispatchQueue, groups: [[SplitDNSProxy.Upstream]], tcp: Bool,
         data: Data, question: DNSQuestion, done: @escaping (Data?) -> Void) {
        self.queue = queue; self.groups = groups; self.tcp = tcp
        self.data = data; self.question = question; completion = done
    }
    func start() { nextGroup() }
    func cancel() { completion = nil; clear() }
    private func clear() {
        hedge?.cancel(); hedge = nil
        active.values.forEach { $0.cancel() }; active.removeAll()
    }
    private func finish(_ response: Data?) {
        guard let done = completion else { return }; completion = nil
        clear(); done(response)
    }
    private func nextGroup() {
        guard completion != nil else { return }
        guard !groups.isEmpty else { finish(nil); return }
        remaining = groups.removeFirst()
        if remaining.isEmpty { nextGroup() } else { launch() }
    }
    private func launch() {
        guard completion != nil, active.count < 2, !remaining.isEmpty else { return }
        hedge?.cancel(); hedge = nil
        let server = remaining.removeFirst(), id = UUID()
        let exchange = DNSExchange(queue: queue, server: server, tcp: tcp, data: data, question: question) { [weak self] response in
            guard let self, self.completion != nil else { return }
            self.active.removeValue(forKey: id)
            if let response { self.finish(response) }
            else if !self.remaining.isEmpty { self.launch() }
            else if self.active.isEmpty { self.nextGroup() }
        }
        active[id] = exchange; exchange.start()
        if active.count < 2 && !remaining.isEmpty {
            let work = DispatchWorkItem { [weak self] in self?.launch() }
            hedge = work; queue.asyncAfter(deadline: .now() + .milliseconds(250), execute: work)
        }
    }
}

private final class DNSExchange {
    private let queue: DispatchQueue
    private let connection: NWConnection
    private let tcp: Bool
    private let data: Data
    private let question: DNSQuestion
    private var completion: ((Data?) -> Void)?
    init(queue: DispatchQueue, server: SplitDNSProxy.Upstream, tcp: Bool, data: Data, question: DNSQuestion,
         done: @escaping (Data?) -> Void) {
        self.queue = queue; self.tcp = tcp; self.question = question; completion = done
        var randomized = data
        let id = UInt16.random(in: 0...UInt16.max)
        randomized[0] = UInt8(id >> 8); randomized[1] = UInt8(id & 255)
        self.data = randomized
        connection = NWConnection(host: .init(server.address), port: .init(rawValue: server.port)!, using: tcp ? .tcp : .udp)
    }
    private func finish(_ response: Data?) {
        guard let done = completion else { return }; completion = nil
        connection.cancel(); done(response)
    }
    func cancel() { completion = nil; connection.cancel() }
    func start() {
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.finish(nil) }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let content = self.tcp ? Data([UInt8(self.data.count >> 8), UInt8(self.data.count & 255)]) + self.data : self.data
                self.connection.send(content: content, completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if error != nil { self.finish(nil) }
                    else if self.tcp { self.readTCP() }
                    else { self.connection.receiveMessage { [weak self] data, _, _, _ in self?.received(data) } }
                })
            case .failed: self.finish(nil)
            default: break
            }
        }
        connection.start(queue: queue)
    }
    private func readTCP() {
        read(count: 2) { [weak self] prefix in
            guard let self, let prefix else { self?.finish(nil); return }
            let count = Int(prefix[0]) << 8 | Int(prefix[1])
            guard count >= 17 else { self.finish(nil); return }
            self.read(count: count) { [weak self] data in self?.received(data) }
        }
    }
    private func read(count: Int, buffer: Data = Data(), done: @escaping (Data?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: count - buffer.count) { [weak self] data, _, complete, error in
            var next = buffer; if let data { next.append(data) }
            if next.count == count { done(next) }
            else if complete || error != nil || data?.isEmpty != false { done(nil) }
            else { self?.read(count: count, buffer: next, done: done) }
        }
    }
    private func received(_ packet: Data?) {
        guard let packet, question.accepts(packet, request: data), ![2, 5].contains(Int(packet[3] & 15)) else { finish(nil); return }
        // TC is returned intact; macOS retries through our TCP listener.
        finish(packet)
    }
}
