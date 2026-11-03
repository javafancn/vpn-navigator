import Foundation
import VPNNavigatorCore

/// Reuses only connections with the CURRENT authenticated requirement. Each
/// request has its own once-only completion and cancellable deadline. All
/// callbacks finish outside the lock, including invalidation/replacement.
final class HelperTransport: @unchecked Sendable {
    private final class Session {
        let id = UUID()
        let connection: NSXPCConnection
        let requirement: String
        var requests: [UUID: HelperReply] = [:]
        init(requirement: String) {
            self.requirement = requirement
            connection = NSXPCConnection(machServiceName: HelperIdentity.machService, options: .privileged)
        }
    }
    private let lock = NSLock()
    private var session: Session?

    func ask(requirement: String, timeout: TimeInterval,
             call: @escaping (VPNNavigatorHelperAPI, @escaping (String) -> Void) -> Void) async -> String {
        await withCheckedContinuation { continuation in
            let requestID = UUID()
            let reply = HelperReply { [weak self] value in
                self?.finished(requestID)
                continuation.resume(returning: value)
            }
            lock.lock()
            var old: Session?
            if session?.requirement != requirement { old = session; session = nil }
            let created = session == nil
            let current = session ?? Session(requirement: requirement)
            session = current
            current.requests[requestID] = reply
            if created {
                let id = current.id
                current.connection.setCodeSigningRequirement(requirement)
                current.connection.remoteObjectInterface = NSXPCInterface(with: VPNNavigatorHelperAPI.self)
                current.connection.interruptionHandler = { [weak self] in
                    DispatchQueue.global(qos: .utility).async { [weak self] in self?.invalidate(id: id, reason: "ERROR: Helper interrupted") }
                }
                current.connection.invalidationHandler = { [weak self] in
                    DispatchQueue.global(qos: .utility).async { [weak self] in self?.invalidate(id: id, reason: "ERROR: Helper unavailable or not authorized") }
                }
                // Publish a resumed connection before another caller can
                // acquire it or invalidate it during an authorization change.
                current.connection.resume()
            }
            lock.unlock()
            if let old { close(old, reason: "ERROR: Helper authorization changed") }
            reply.arm(timeout: timeout)
            let sessionID = current.id
            guard let proxy = current.connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
                self?.invalidate(id: sessionID, reason: "ERROR: " + error.localizedDescription)
            }) as? VPNNavigatorHelperAPI else {
                invalidate(id: current.id, reason: "ERROR: Invalid privileged service interface"); return
            }
            call(proxy) { reply.finish($0) }
        }
    }
    func closeIfIdle(id: UUID? = nil) {
        lock.lock()
        let old = session?.requests.isEmpty == true && (id == nil || session?.id == id) ? session : nil
        if old != nil { session = nil }
        lock.unlock()
        if let old { close(old, reason: "ERROR: Helper connection closed") }
    }
    func invalidate() { invalidate(id: nil, reason: "ERROR: Helper authorization is unavailable") }
    private func invalidate(id: UUID?, reason: String) {
        lock.lock()
        let old = id == nil || session?.id == id ? session : nil
        if old != nil { session = nil }
        lock.unlock()
        if let old { close(old, reason: reason) }
    }
    private func close(_ old: Session, reason: String) {
        old.connection.invalidationHandler = nil; old.connection.interruptionHandler = nil
        old.connection.invalidate()
        for reply in old.requests.values { reply.finish(reason) }
    }
    private func finished(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        session?.requests.removeValue(forKey: id)
        // Keep the authenticated channel while the app is alive. Closing it
        // between idle status polls races the helper's five-second idle exit.
        // Quit/maintenance explicitly close it; a crash invalidates it via XPC.
    }
}

private final class HelperReply: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var timeout: DispatchSourceTimer?
    private let done: (String) -> Void
    init(_ done: @escaping (String) -> Void) { self.done = done }
    func arm(timeout seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler { [weak self] in self?.finish("ERROR: Privileged helper did not respond before the operation deadline") }
        timeout = timer; timer.resume()
    }
    func finish(_ value: String) {
        lock.lock()
        let first = !finished; finished = true
        timeout?.cancel(); timeout = nil
        lock.unlock()
        if first { done(value) }
    }
}
