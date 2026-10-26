import Foundation
import Network
import VPNNavigatorCore

/// Actual HTTP tests contact numeric loopback endpoints only. Production HTTPS
/// trust handling is unchanged, and this entry point never requests a VPN.
@MainActor
enum PublicEgressSelfTest {
    private enum Failure: Error { case check }
    private static func expectFailure(_ expected: EgressProbeFailure, _ operation: () async throws -> EgressHTTPResult) async throws {
        do { _ = try await operation(); throw Failure.check }
        catch let error as EgressProbeFailure { guard error == expected else { throw Failure.check } }
    }
    private static func wait(_ checker: PublicEgressModel) async throws {
        for _ in 0..<1000 { if !checker.running { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure.check
    }
    @MainActor private final class State {
        var report: SessionReport?
        var calls = 0
        var slow = false
        var failIPv6 = false
        var staleLookup = false
        func lookup(_ request: RouteLookupRequest) throws -> RouteLookupResult {
            if staleLookup, let old = report {
                report = .init(state: .connected, message: "", activeProfileID: old.activeProfileID, receivedBytes: 0, sentBytes: 0,
                    attemptID: UUID(), networkRecoveryRequired: false, routingMode: .fullVPN, routingRevision: UUID())
            }
            return .init(request: request, decision: .init(ip: request.ip, path: .vpn, reason: "synthetic"),
                expectedInterface: "utun4", observedInterface: "utun4", observedGateway: "", matchesExpected: true)
        }
    }
    static func run() async throws {
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" else { throw Failure.check }
        let server = try EgressHTTPFixture(body: "8.8.8.8\n"), port = try await server.listen()
        defer { server.close() }
        let result = try await PublicEgressHTTP.loopbackFixture(.ipv4, url: server.url(port))
        guard result.address == "8.8.8.8", result.milliseconds >= 0, !server.headers.lowercased().contains("cookie:"),
              !server.headers.lowercased().contains("authorization:") else { throw Failure.check }
        let server6 = try EgressHTTPFixture(address: "::1", body: "2606:4700::1111"), port6 = try await server6.listen()
        defer { server6.close() }
        guard try await PublicEgressHTTP.loopbackFixture(.ipv6, url: server6.url(port6)).address == "2606:4700::1111" else { throw Failure.check }
        for (body, expected) in [("<html>8.8.8.8</html>", EgressProbeFailure.invalidResponse), ("10.0.0.1", .nonPublicAddress), ("2606:4700::1111", .wrongFamily)] {
            let fixture = try EgressHTTPFixture(body: body), port = try await fixture.listen(); defer { fixture.close() }
            try await expectFailure(expected) { try await PublicEgressHTTP.loopbackFixture(.ipv4, url: fixture.url(port)) }
        }
        let large = try EgressHTTPFixture(body: String(repeating: "a", count: 129)), largePort = try await large.listen(); defer { large.close() }
        try await expectFailure(.tooLarge) { try await PublicEgressHTTP.loopbackFixture(.ipv4, url: large.url(largePort)) }
        let chunked = try EgressHTTPFixture(body: String(repeating: "a", count: 1024), includeLength: false), chunkPort = try await chunked.listen(); defer { chunked.close() }
        try await expectFailure(.tooLarge) { try await PublicEgressHTTP.loopbackFixture(.ipv4, url: chunked.url(chunkPort)) }
        let badStatus = try EgressHTTPFixture(body: "8.8.8.8", status: "503 Unavailable"), statusPort = try await badStatus.listen(); defer { badStatus.close() }
        try await expectFailure(.httpStatus) { try await PublicEgressHTTP.loopbackFixture(.ipv4, url: badStatus.url(statusPort)) }
        let redirectTarget = try EgressHTTPFixture(body: "8.8.8.8"), targetPort = try await redirectTarget.listen(); defer { redirectTarget.close() }
        let redirect = try EgressHTTPFixture(body: "", status: "302 Found", extraHeaders: "Location: \(redirectTarget.url(targetPort).absoluteString)\r\n"), redirectPort = try await redirect.listen(); defer { redirect.close() }
        try await expectFailure(.redirect) { try await PublicEgressHTTP.loopbackFixture(.ipv4, url: redirect.url(redirectPort)) }
        try await Task.sleep(nanoseconds: 100_000_000); guard redirectTarget.requests == 0 else { throw Failure.check }
        let authentication = try EgressHTTPFixture(body: "", status: "401 Unauthorized", extraHeaders: "WWW-Authenticate: Basic realm=\"CI-only\"\r\n"), authPort = try await authentication.listen(); defer { authentication.close() }
        try await expectFailure(.authentication) { try await PublicEgressHTTP.loopbackFixture(.ipv4, url: authentication.url(authPort)) }
        let slow = try EgressHTTPFixture(body: "8.8.8.8", delay: 2), slowPort = try await slow.listen(); defer { slow.close() }
        try await expectFailure(.timeout) { try await PublicEgressHTTP.loopbackFixture(.ipv4, url: slow.url(slowPort), timeout: 0.2) }
        let task = Task { try await PublicEgressHTTP.loopbackFixture(.ipv4, url: slow.url(slowPort)) }
        for _ in 0..<100 where slow.requests < 2 { try await Task.sleep(nanoseconds: 10_000_000) }
        task.cancel()
        do { _ = try await task.value; throw Failure.check } catch is CancellationError { }

        let suite = "VPNNavEgressCI-" + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { throw Failure.check }
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(backgroundServiceDefaults: defaults, profileStoreRoot: root.appendingPathComponent("profiles"), libraryDefaults: defaults, smartDefaults: defaults)
        defer { model.profileHealth.stop(); model.smartConnection.stop(); model.quickAccess.shutdown() }
        let profile = VPNProfile(name: "synthetic", sourceFilename: "synthetic.ovpn", relativePath: "unused")
        model.profiles = [profile]; model.selectedID = profile.id
        let state = State()
        state.report = .init(state: .connected, message: "DO_NOT_STORE", activeProfileID: profile.id, receivedBytes: 0, sentBytes: 0,
            attemptID: UUID(), networkRecoveryRequired: false, routingMode: .fullVPN, routingRevision: UUID())
        model.applyVerifiedSessionReport(state.report!)
        let service = PublicEgressService(snapshot: { state.report }, lookup: { try state.lookup($0) }, query: { family in
            let flags = await MainActor.run { state.calls += 1; return (state.slow, state.failIPv6) }
            if flags.0 { try await Task.sleep(nanoseconds: 2_000_000_000) }
            if family == .ipv6 && flags.1 { throw EgressProbeFailure.transport }
            return .init(address: family == .ipv4 ? "8.8.8.8" : "2606:4700:4700::1001",
                remoteAddress: family == .ipv4 ? "1.1.1.1" : "2606:4700::1111", usedProxy: false, cacheHit: false, milliseconds: 5)
        })
        let checker = PublicEgressModel(service: service)
        guard state.calls == 0 else { throw Failure.check } // construction never sends a query
        model.showingPublicEgress = true
        guard model.smartConnectionContext().occupied, model.quickAccessAction(for: profile.id) == .blocked else { throw Failure.check }
        state.failIPv6 = true; checker.start(model: model, families: [.ipv4, .ipv6]); try await wait(checker)
        guard checker.rows.count == 2, checker.rows.first?.assessment == .vpnRoute, checker.rows.last?.failure == .transport, model.connected else { throw Failure.check }
        state.failIPv6 = false; state.staleLookup = true
        checker.start(model: model, families: [.ipv4]); try await wait(checker)
        guard checker.rows.isEmpty, checker.status.contains("状态改变") else { throw Failure.check }
        state.staleLookup = false; state.slow = true
        checker.start(model: model, families: [.ipv4]); checker.cancel(clear: true)
        state.slow = false; checker.start(model: model, families: [.ipv4]); try await wait(checker)
        guard checker.rows.count == 1, checker.rows[0].response != nil else { throw Failure.check }
        state.slow = true; checker.start(model: model, families: [.ipv4, .ipv6], limitNanoseconds: 50_000_000); try await wait(checker)
        guard checker.rows.count == 2, checker.rows.allSatisfy({ $0.failure == .timeout }) else { throw Failure.check }
        checker.cancel(clear: true); guard checker.rows.isEmpty else { throw Failure.check }
        print("PASS public egress: real IPv4/IPv6 loopback HTTP, bounded streaming/status/family checks, no redirect follow or credential request, deadline/cancellation, manual-only model, partial results, stale session refusal and unchanged VPN state; no public requests")
    }
}

private final class EgressHTTPFixture: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "VPNNavigator.EgressHTTPFixture")
    private let lock = NSLock()
    private var clients: [NWConnection] = []
    private var replied = false
    private var count = 0
    private var receivedHeaders = ""
    private let address: String
    private let response: Data
    private let delay: Double
    var requests: Int { lock.lock(); defer { lock.unlock() }; return count }
    var headers: String { lock.lock(); defer { lock.unlock() }; return receivedHeaders }
    init(address: String = "127.0.0.1", body: String, status: String = "200 OK", extraHeaders: String = "", includeLength: Bool = true, delay: Double = 0) throws {
        self.address = address; self.delay = delay
        response = Data(("HTTP/1.1 \(status)\r\nContent-Type: text/plain\r\nConnection: close\r\n" +
            (includeLength ? "Content-Length: \(body.utf8.count)\r\n" : "") + extraHeaders + "\r\n" + body).utf8)
        let parameters = NWParameters.tcp; parameters.requiredLocalEndpoint = .hostPort(host: .init(address), port: .any)
        listener = try NWListener(using: parameters)
    }
    func url(_ port: UInt16) -> URL { URL(string: "http://\(address.contains(":") ? "[\(address)]" : address):\(port)/")! }
    func listen() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, !self.replied else { return }
                switch state {
                case .ready:
                    guard let port = self.listener.port else { return }; self.replied = true; continuation.resume(returning: port.rawValue)
                case .failed(let error): self.replied = true; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] client in
                guard let self else { client.cancel(); return }; self.clients.append(client); client.start(queue: self.queue); self.receive(client, bytes: Data())
            }
            listener.start(queue: queue)
        }
    }
    private func receive(_ client: NWConnection, bytes: Data) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak client] data, _, complete, error in
            guard let self, let client else { return }
            let combined = bytes + (data ?? Data())
            guard combined.count <= 4096, error == nil else { client.cancel(); return }
            guard combined.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if !complete { self.receive(client, bytes: combined) } else { client.cancel() }; return
            }
            self.lock.lock(); self.count += 1; self.receivedHeaders = String(decoding: combined, as: UTF8.self); self.lock.unlock()
            self.queue.asyncAfter(deadline: .now() + self.delay) {
                client.send(content: self.response, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                    self.queue.asyncAfter(deadline: .now() + 0.1) { client.cancel() }
                })
            }
        }
    }
    func close() { queue.async { [self] in clients.forEach { $0.cancel() }; listener.cancel() } }
}
