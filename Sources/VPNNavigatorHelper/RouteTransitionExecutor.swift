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
