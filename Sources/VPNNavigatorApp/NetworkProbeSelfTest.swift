import Foundation
import Network
import Darwin

/// Explicit CI entry point. Uses only loopback and the system localhost
/// resolver; does not invoke the root helper or change system networking.
enum NetworkProbeSelfTest {
    static func run() async throws {
        let server = try LoopbackProbeServer()
        let port = try await server.listen()
        defer { server.close() }
        let tcp = try await NetworkProbes.tcp("127.0.0.1", port: port)
        guard tcp.reachable else { throw ProbeError.commandFailed }
        let dns = try await NetworkProbes.dns("localhost")
        guard dns.contains("127.0.0.1") else { throw ProbeError.noDNSAnswer }
        let ping = try await NetworkProbes.ping("127.0.0.1")
        guard ping.received == 3, ping.loss == 0 else { throw ProbeError.noPingAnswer }
        let trace = try await NetworkProbes.trace("127.0.0.1")
        guard trace.contains("127.0.0.1") else { throw ProbeError.commandFailed }
        do {
            _ = try await BoundedProbeCommand.run("/sbin/ping", ["-n", "-c", "10", "127.0.0.1"], timeout: 1)
            throw ProbeError.commandFailed
        } catch ProbeError.timedOut { }
        let cancellation = Task { try await BoundedProbeCommand.run("/sbin/ping", ["-n", "-c", "10", "127.0.0.1"]) }
        cancellation.cancel()
        do { _ = try await cancellation.value; throw ProbeError.commandFailed }
        catch is CancellationError { }
    }
}

private final class LoopbackProbeServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "VPNNavigator.ProbeSelfTest")
    private var clients: [NWConnection] = []
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func listen() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            var replied = false
            listener.stateUpdateHandler = { [weak self] state in
                guard !replied else { return }
                switch state {
                case .ready:
                    guard let port = self?.listener.port else { return }
                    replied = true; continuation.resume(returning: port.rawValue)
                case .failed(let error): replied = true; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] client in
                guard let self else { client.cancel(); return }
                self.clients.append(client)
                client.start(queue: self.queue)
            }
            listener.start(queue: queue)
        }
    }
    func close() {
        queue.async { [self] in clients.forEach { $0.cancel() }; listener.cancel() }
    }
}
