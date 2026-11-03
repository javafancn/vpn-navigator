import Foundation
import VPNNavigatorCore

@objc protocol FixtureHelperAPI {
    func sessionSnapshot(reply: @escaping (String) -> Void)
}
final class FixtureAPI: NSObject, FixtureHelperAPI {
    func sessionSnapshot(reply: @escaping (String) -> Void) {
        let report = SessionReport(state: .disconnected, message: "", activeProfileID: nil,
            receivedBytes: nil, sentBytes: nil, networkRecoveryRequired: false)
        reply(String(decoding: try! JSONEncoder().encode(report), as: UTF8.self))
    }
}
final class FixtureXPCConnection {
    struct Options: OptionSet { let rawValue: Int; static let privileged = Options(rawValue: 1) }
    private static let lock = NSLock()
    private static var created = 0, active = 0
    static var counts: (Int, Int) { lock.lock(); defer { lock.unlock() }; return (created, active) }
    var interruptionHandler: (() -> Void)?
    var invalidationHandler: (() -> Void)?
    var remoteObjectInterface: NSXPCInterface?
    private var running = false
    init(machServiceName: String, options: Options) { }
    func setCodeSigningRequirement(_ requirement: String) { }
    func resume() {
        Self.lock.lock(); defer { Self.lock.unlock() }
        running = true; Self.created += 1; Self.active += 1
    }
    func invalidate() {
        Self.lock.lock()
        if running { Self.active -= 1; running = false }
        Self.lock.unlock()
        invalidationHandler?()
    }
    func remoteObjectProxyWithErrorHandler(_ handler: @escaping (Error) -> Void) -> Any { FixtureAPI() }
}
final class FixtureClient {
    let transport = HelperTransport()
    func ask(timeout: TimeInterval = 12, _ call: @escaping (FixtureHelperAPI, @escaping (String) -> Void) -> Void) async -> String {
        await transport.ask(requirement: "fixture-current-identity", timeout: timeout, call: call)
    }
    // SESSION_REPORT
}
@main struct HelperIdleLifetimeRegression {
    static func main() async throws {
        let client = FixtureClient()
        let report = await client.sessionReport()
        precondition(report?.state == .disconnected)
        precondition(FixtureXPCConnection.counts == (1, 1), "Idle status closed the app's channel")
        // Cross both the helper's 5s exit grace and the former 30s transport
        // timeout, without polling to artificially keep the connection alive.
        try await Task.sleep(nanoseconds: 31_000_000_000)
        precondition(FixtureXPCConnection.counts == (1, 1), "Open app lost its idle channel")
        for _ in 0..<50 {
            let response = await client.sessionReport()
            precondition(response?.state == .disconnected)
        }
        precondition(FixtureXPCConnection.counts == (1, 1), "Idle polling recreated connections")
        client.transport.closeIfIdle()
        precondition(FixtureXPCConnection.counts == (1, 0), "Explicit quit did not release the channel")
        print("PASS: production sessionReport/transport keep one authenticated channel beyond 31 idle seconds and 50 polls; explicit quit closes it; fake XPC only.")
    }
}
