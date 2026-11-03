import Foundation
import Network
import VPNNavigatorCore

/// One connected UDP socket per fixed resolver, confined to the proxy queue.
/// Questions have distinct randomized IDs; late IDs are quarantined for two
/// seconds. Domestic/VPN policy selection stays with DNSResolution.
final class DNSUDPTransport {
    private struct Pending {
        let ticket: UUID
        let data: Data
        let originalID: (UInt8, UInt8)
        let question: DNSQuestion
        let done: (Data?) -> Void
        var sent = false
    }
    private let queue: DispatchQueue
    private let server: SplitDNSProxy.Upstream
    private var connection: NWConnection?
    private var ready = false
    private var stopped = false
    private var pending: [UInt16: Pending] = [:]
    private var tickets: [UUID: UInt16] = [:]
    private var retired: [UInt16: TimeInterval] = [:]
    private var lastPrune: TimeInterval = 0
    init(queue: DispatchQueue, server: SplitDNSProxy.Upstream) { self.queue = queue; self.server = server }

    func submit(_ data: Data, question: DNSQuestion, done: @escaping (Data?) -> Void) -> UUID {
        let ticket = UUID(), now = ProcessInfo.processInfo.systemUptime
        if now - lastPrune >= 1 { retired = retired.filter { $0.value > now }; lastPrune = now }
        var selected: UInt16?
        if !stopped, pending.count < 256 {
            for _ in 0..<64 {
                let value = UInt16.random(in: 0...UInt16.max)
                if pending[value] == nil && (retired[value] ?? 0) <= now { selected = value; break }
            }
        }
        guard let id = selected else { queue.async { done(nil) }; return ticket }
        var wire = data; wire[0] = UInt8(id >> 8); wire[1] = UInt8(id & 255)
        pending[id] = Pending(ticket: ticket, data: wire, originalID: (data[0], data[1]), question: question, done: done)
        tickets[ticket] = id
        ensureConnection()
        if ready { send(id) }
        return ticket
    }
    func cancel(_ ticket: UUID) {
        guard let id = tickets.removeValue(forKey: ticket) else { return }
        pending.removeValue(forKey: id)
        retired[id] = ProcessInfo.processInfo.systemUptime + 2
    }
    func stop() { stopped = true; reset() }
    private func reset() {
        connection?.stateUpdateHandler = nil; connection?.cancel(); connection = nil; ready = false
        let jobs = Array(pending.values)
        for id in pending.keys { retired[id] = ProcessInfo.processInfo.systemUptime + 2 }
        pending.removeAll(); tickets.removeAll()
        for job in jobs { job.done(nil) }
    }
    private func ensureConnection() {
        guard connection == nil, !stopped else { return }
        let value = NWConnection(host: .init(server.address), port: .init(rawValue: server.port)!, using: .udp)
        connection = value
        value.stateUpdateHandler = { [weak self, weak value] state in
            guard let self, let value, self.connection === value else { return }
            switch state {
            case .ready:
                self.ready = true
                for id in Array(self.pending.keys) { self.send(id) }
                self.receive(value)
            case .failed, .cancelled: self.reset()
            default: break
            }
        }
        value.start(queue: queue)
    }
    private func send(_ id: UInt16) {
        guard let value = connection, var job = pending[id], !job.sent else { return }
        job.sent = true; pending[id] = job
        value.send(content: job.data, completion: .contentProcessed { [weak self, weak value] error in
            guard let self, let value, self.connection === value, error != nil,
                  self.pending[id]?.ticket == job.ticket else { return }
            self.finish(id, packet: nil)
        })
    }
    private func receive(_ value: NWConnection) {
        value.receiveMessage { [weak self, weak value] data, _, _, error in
            guard let self, let value, self.connection === value else { return }
            if error != nil { self.reset(); return }
            if let data, data.count >= 12 {
                let id = UInt16(data[0]) << 8 | UInt16(data[1])
                if let job = self.pending[id], job.question.accepts(data, request: job.data) { self.finish(id, packet: data) }
            }
            self.receive(value)
        }
    }
    private func finish(_ id: UInt16, packet: Data?) {
        guard let job = pending.removeValue(forKey: id) else { return }
        tickets.removeValue(forKey: job.ticket)
        retired[id] = ProcessInfo.processInfo.systemUptime + 2
        var restored = packet
        if restored != nil { restored![0] = job.originalID.0; restored![1] = job.originalID.1 }
        job.done(restored)
    }
}
