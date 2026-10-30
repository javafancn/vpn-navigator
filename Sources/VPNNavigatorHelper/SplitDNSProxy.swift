import Foundation
import Network
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
    private var clients: [UUID: NWConnection] = [:]
    private var exchanges: [UUID: DNSExchange] = [:]
    private var stopped = false
    private(set) var port: UInt16 = 0
    init(domains: ChinaDNSDomains, domestic: [Upstream], vpn: [Upstream]) {
        self.domains = domains; self.domestic = domestic; self.vpn = vpn
    }
    func start() throws {
        guard !vpn.isEmpty, listeners.isEmpty else { throw DNSJournalError.unavailable }
        do {
            let tcp = try listen(tcp: true, port: .any)
            guard let bound = tcp.port else { throw DNSJournalError.unavailable }
            port = bound.rawValue
            _ = try listen(tcp: false, port: bound)
        } catch { stop(); throw error }
    }
    private func listen(tcp: Bool, port: NWEndpoint.Port) throws -> NWListener {
        let params = tcp ? NWParameters.tcp : NWParameters.udp
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
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection, tcp: tcp) }
        listeners.append(listener); listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 3) == .success, succeeded else { throw DNSJournalError.unavailable }
        return listener
    }
    func stop() {
        queue.sync {
            stopped = true
            listeners.forEach { $0.cancel() }; listeners.removeAll()
            clients.values.forEach { $0.cancel() }; clients.removeAll()
            let pending = Array(exchanges.values); exchanges.removeAll()
            pending.forEach { $0.cancel() }
        }
    }
    func verify() throws {
        guard queue.sync(execute: { !stopped && listeners.count == 2 && listeners.allSatisfy { $0.state == .ready } }) else {
            throw DNSJournalError.unavailable
        }
    }
    private func accept(_ connection: NWConnection, tcp: Bool) {
        guard !stopped, clients.count < 64 else { connection.cancel(); return }
        let id = UUID(); clients[id] = connection
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in self?.close(id) }
        if tcp { readTCP(connection, id: id) } else { readUDP(connection, id: id) }
    }
    private func readUDP(_ connection: NWConnection, id: UUID) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, self.clients[id] != nil, let data, error == nil else { self?.close(id); return }
            // mDNSResponder can multiplex A/AAAA and parallel names on one
            // source port. Keep receiving while each transaction is pending.
            self.readUDP(connection, id: id)
            self.query(data, tcp: false) { [weak self] response in
                guard let self, self.clients[id] != nil, !response.isEmpty else { return }
                connection.send(content: response, completion: .contentProcessed { [weak self] error in
                    if error != nil { self?.close(id) }
                })
            }
        }
    }
    private func close(_ id: UUID) { clients.removeValue(forKey: id)?.cancel() }
    private func readTCP(_ connection: NWConnection, id: UUID) {
        read(connection, count: 2) { [weak self] prefix in
            guard let self, let prefix, self.clients[id] != nil else { self?.close(id); return }
            let length = Int(prefix[0]) << 8 | Int(prefix[1])
            guard length >= 17 else { self.close(id); return }
            self.read(connection, count: length) { [weak self] data in
                guard let self, let data else { self?.close(id); return }
                self.query(data, tcp: true) { [weak self] response in
                    guard let self, self.clients[id] != nil else { return }
                    let framed = Data([UInt8(response.count >> 8), UInt8(response.count & 255)]) + response
                    connection.send(content: framed, completion: .contentProcessed { [weak self] error in
                        guard let self else { return }
                        if error != nil { self.close(id) } else { self.readTCP(connection, id: id) }
                    })
                }
            }
        }
    }
    private func read(_ connection: NWConnection, count: Int, buffer: Data = Data(), done: @escaping (Data?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: count - buffer.count) { [weak self] data, _, complete, error in
            var next = buffer; if let data { next.append(data) }
            if next.count == count { done(next) }
            else if complete || error != nil || data?.isEmpty != false { done(nil) }
            else { self?.read(connection, count: count, buffer: next, done: done) }
        }
    }
    private func query(_ data: Data, tcp: Bool, done: @escaping (Data) -> Void) {
        guard !stopped, let question = DNSQuestion(data) else { done(Data()); return }
        guard exchanges.count < 128 else { done(question.failure(for: data)); return }
        let servers = (domains.contains(question.name) ? domestic : []) + vpn
        attempt(data, question: question, servers: servers, tcp: tcp, done: done)
    }
    private func attempt(_ data: Data, question: DNSQuestion, servers: [Upstream], tcp: Bool, done: @escaping (Data) -> Void) {
        guard !stopped else { return }
        guard let server = servers.first else { done(question.failure(for: data)); return }
        let id = UUID()
        let exchange = DNSExchange(queue: queue, server: server, tcp: tcp, data: data, question: question) { [weak self] result in
            guard let self else { return }; self.exchanges.removeValue(forKey: id)
            guard !self.stopped else { return }
            if var result { result[0] = data[0]; result[1] = data[1]; done(result) }
            else { self.attempt(data, question: question, servers: Array(servers.dropFirst()), tcp: tcp, done: done) }
        }
        exchanges[id] = exchange; exchange.start()
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
