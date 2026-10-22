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
    public let installed6: [IPv6RouteTarget]
    public let uncertain6: [IPv6RouteMutation]
    public let uncertain: [RouteMutation]
    public let malformed: Bool
    public var permitsAutomaticRecovery: Bool { !malformed && uncertain.isEmpty && uncertain6.isEmpty }

    public init(data: Data) {
        let decoder = JSONDecoder()
        if let legacy = try? decoder.decode([RouteTarget].self, from: data) {
            installed6 = []; uncertain6 = []
            installed = legacy
            uncertain = []
            malformed = false
            return
        }
        guard let text = String(data: data, encoding: .utf8) else {
            installed6 = []; uncertain6 = []
            installed = []; uncertain = []; malformed = true
            return
        }
        var live: [RouteTarget] = []
        var pending: [UUID: RouteMutation] = [:]
        var live6: [IPv6RouteTarget] = [], pending6: [UUID: IPv6RouteMutation] = [:]
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
                        if !live.contains(event.mutation.route) { live.append(event.mutation.route) }
                    } else {
                        live.removeAll { $0 == event.mutation.route }
                    }
                }
            } else if let event = try? decoder.decode(IPv6RouteLedgerEvent.self, from: bytes) {
                let mutation = event.ipv6Mutation
                if event.phase == .begun {
                    if pending6[mutation.id] != nil { corrupt = true } else { pending6[mutation.id] = mutation }
                } else {
                    guard pending6[mutation.id] == mutation else { corrupt = true; continue }
                    pending6.removeValue(forKey: mutation.id)
                    if mutation.action == .add { if !live6.contains(mutation.route) { live6.append(mutation.route) } }
                    else { live6.removeAll { $0 == mutation.route } }
                }
            } else if let old = try? decoder.decode(RouteTarget.self, from: bytes) {
                // Old installer journals recorded only successful route adds.
                if !live.contains(old) { live.append(old) }
            } else if let legacy = try? decoder.decode([RouteTarget].self, from: bytes) {
                // Legacy JSON-array followed by a new operation log.
                legacy.forEach { if !live.contains($0) { live.append($0) } }
            } else {
                corrupt = true
            }
        }
        installed = live
        installed6 = live6; uncertain6 = pending6.values.sorted { $0.id.uuidString < $1.id.uuidString }
        uncertain = pending.values.sorted { $0.id.uuidString < $1.id.uuidString }
        malformed = corrupt
    }
}

public struct IPv6RouteMutation: Codable, Equatable, Sendable {
    public let id: UUID
    public let action: RouteMutation.Action
    public let route: IPv6RouteTarget
    public init(id: UUID = UUID(), action: RouteMutation.Action, route: IPv6RouteTarget) { self.id = id; self.action = action; self.route = route }
}
public struct IPv6RouteLedgerEvent: Codable, Sendable {
    public let phase: RouteLedgerEvent.Phase
    public let ipv6Mutation: IPv6RouteMutation
    public init(phase: RouteLedgerEvent.Phase, ipv6Mutation: IPv6RouteMutation) { self.phase = phase; self.ipv6Mutation = ipv6Mutation }
}
