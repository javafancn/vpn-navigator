import Foundation
import VPNNavigatorCore

/// Keep endpoint/default routes installed throughout the transition. A failed
/// transaction retains its journal; the owner stops the child before rollback.
enum RouteTransitionExecutor {
    static func apply(_ change: ManagedRouteTransition, executor: RouteExecutor,
                      updateProtection: () throws -> Void, verify: () throws -> Void) throws {
        if change.tightensDirectAccess { try updateProtection() }
        try executor.refreshDirectRoutes(added: change.added, removed: change.removed)
        try verify()
        if !change.tightensDirectAccess { try updateProtection() }
    }
}

enum DualStackTransitionExecutor {
    static func apply(from old: DualStackRoutePlan, to next: DualStackRoutePlan, executor: RouteExecutor,
                      updateProtection: (Bool) throws -> Void, verify: () throws -> Void) throws {
        guard old.endpoint4 == next.endpoint4, old.endpoint6 == next.endpoint6,
              old.defaults4 == next.defaults4, old.defaults6 == next.defaults6 else { throw RoutingModeSwitchError.unavailable }
        let before4 = Set(old.direct4), after4 = Set(next.direct4), before6 = Set(old.direct6), after6 = Set(next.direct6)
        let removed4 = before4.subtracting(after4).sorted { $0.prefix < $1.prefix }
        let removed6 = before6.subtracting(after6).sorted { $0.prefix < $1.prefix }
        let tightens = !removed4.isEmpty || !removed6.isEmpty
        if tightens { try updateProtection(true) }
        try executor.refreshDirectRoutes(added: after4.subtracting(before4).sorted { $0.prefix < $1.prefix }, removed: removed4)
        try executor.refreshIPv6(added: after6.subtracting(before6).sorted { $0.prefix < $1.prefix }, removed: removed6)
        try verify()
        if !tightens { try updateProtection(false) }
    }
}
