import Foundation

/// Append-only, fsynced journal of route mutations. A begun-but-uncommitted
/// mutation is ambiguous after a crash: the OS operation may or may not have
/// happened, so automatically deleting the route would be unsafe.
public struct RouteLedgerEvent: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case begun, committed }
    public let phase: Phase
    public let mutation: RouteMutation

    public init(phase: Phase, mutation: RouteMutation) {
        self.phase = phase
        self.mutation = mutation
    }
}

public struct RouteLedgerReplay: Sendable {
    public let installed: [RouteTarget]
    public let uncertain: [RouteMutation]
    public let malformed: Bool
    public var permitsAutomaticRecovery: Bool { !malformed && uncertain.isEmpty }

    public init(data: Data) {
        let decoder = JSONDecoder()
        if let legacy = try? decoder.decode([RouteTarget].self, from: data) {
            installed = legacy
            uncertain = []
            malformed = false
            return
        }
        guard let text = String(data: data, encoding: .utf8) else {
            installed = []; uncertain = []; malformed = true
            return
        }
        var live = Set<RouteTarget>()
        var pending: [UUID: RouteMutation] = [:]
        var corrupt = false
        for row in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let bytes = Data(row.utf8)
            if let event = try? decoder.decode(RouteLedgerEvent.self, from: bytes) {
                switch event.phase {
                case .begun:
                    if pending[event.mutation.id] != nil { corrupt = true }
                    else { pending[event.mutation.id] = event.mutation }
                case .committed:
                    guard pending[event.mutation.id] == event.mutation else {
                        corrupt = true
                        continue
                    }
                    pending.removeValue(forKey: event.mutation.id)
                    if event.mutation.action == .add {
                        live.insert(event.mutation.route)
                    } else {
                        live.remove(event.mutation.route)
                    }
                }
            } else if let old = try? decoder.decode(RouteTarget.self, from: bytes) {
                // Old installer journals recorded only successful route adds.
                live.insert(old)
            } else if let legacy = try? decoder.decode([RouteTarget].self, from: bytes) {
                // Legacy JSON-array followed by a new operation log.
                legacy.forEach { live.insert($0) }
            } else {
                corrupt = true
            }
        }
        installed = live.sorted { $0.prefix < $1.prefix }
        uncertain = pending.values.sorted { $0.id.uuidString < $1.id.uuidString }
        malformed = corrupt
    }
}
