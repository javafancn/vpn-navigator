import Foundation
import VPNNavigatorCore

struct FixturePath { let next: SmartNetworkState; var gate: DispatchSemaphore? }
struct FixtureTarget { let id: UUID }
@MainActor final class FixtureModel {
    var selectedID: UUID?
    var connected = false, connecting = false
    var sessionState = TunnelState.disconnected
    var connections = 0, permissions = 0
    func refreshConnectionStatus() async { }
    func smartConnectionContext(sleeping: Bool) -> SmartConnectionContext {
        .init(state: sessionState, helperReady: true, sleeping: sleeping)
    }
    func connectSelected(automatically: Bool, automationPermit: (() async -> Bool)?) async {
        for _ in 0..<3 {
            guard await automationPermit?() == true else { return }
            permissions += 1; await Task.yield()
        }
        connections += 1; connected = true; sessionState = .connected
    }
}
@MainActor final class SmartHarness {
    var preferences = SmartConnectionPreferences()
    var stopped = false, sleeping = false, initializedNetwork = true, startupWaitedForNetwork = false
    var path: FixturePath?
    var network = SmartNetworkState(online: true, kind: .wifi, identity: "old")
    var networkGeneration = UUID(), generation = UUID()
    let networkQueue = DispatchQueue(label: "review.network-boundary")
    var pending: Task<Void, Never>?
    var pendingTrigger: SmartTrigger?
    var status = ""
    let targetID = UUID()
    let modelOwner = FixtureModel()
    var model: FixtureModel? { modelOwner }
    func target(automatic: Bool) -> FixtureTarget? { FixtureTarget(id: targetID) }
    func update(_ edit: (inout SmartConnectionPreferences) -> Void) { edit(&preferences); cancelPending() }
    func deliver(_ notice: VPNStatusNotice) async { }
    nonisolated private static func readNetwork(path: FixturePath, preferences: SmartConnectionPreferences) -> SmartNetworkState {
        if let gate = path.gate { _ = gate.wait(timeout: .now() + 3) }
        return path.next
    }
    // PRODUCTION_METHODS
    func permit(trigger: SmartTrigger) -> () async -> Bool {
        let token = generation, id = targetID
        return { [weak self] in
            // AUTOMATION_PERMIT
        }
    }
    func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<400 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        fatalError("Controlled async operation did not complete")
    }
    static func run() async throws {
        let stale = SmartHarness(); stale.preferences.enabled = true; stale.preferences.onLaunch = true
        let gate = DispatchSemaphore(value: 0)
        stale.path = .init(next: .init(online: false), gate: gate)
        var completed = false
        let token = stale.generation
        let request = Task { let result = await stale.permit(trigger: .launch)(); completed = true; return result }
        try await Task.sleep(nanoseconds: 30_000_000)
        precondition(!completed, "Permission read the stale snapshot before the boundary returned")
        gate.signal()
        let allowed = await request.value
        precondition(!allowed && !stale.network.online && stale.generation == token, "Fresh permission rescheduled or allowed offline state")

        let stable = SmartHarness(); stable.preferences.enabled = true; stable.preferences.onLaunch = true
        stable.path = .init(next: .init(online: true, kind: .wifi, identity: "new"))
        let before = stable.generation
        let accepted = await stable.permit(trigger: .launch)()
        precondition(accepted && stable.generation == before && stable.network.identity == "new", "Permission cancelled itself on a changed network identity")
        let cancelledGate = DispatchSemaphore(value: 0)
        stable.path = .init(next: .init(online: true, kind: .wifi), gate: cancelledGate)
        let cancelledPermit = stable.permit(trigger: .launch)
        let cancelled = Task { await cancelledPermit() }
        try await Task.sleep(nanoseconds: 30_000_000)
        stable.cancelPending(); cancelledGate.signal()
        let cancelledAllowed = await cancelled.value
        precondition(!cancelledAllowed, "Cancellation during network validation was ignored")

        let wake = SmartHarness(); wake.preferences.enabled = true; wake.preferences.onWake = true
        wake.preferences.onNetworkRestore = false
        wake.path = .init(next: .init(online: false))
        wake.refreshNetwork(); wake.schedule(.wake)
        let wakeToken = wake.generation
        try await wake.waitUntil { !wake.network.online }
        precondition(wake.pendingTrigger == .wake && wake.generation == wakeToken, "Late offline event cancelled wake")
        // Remain offline beyond the old 2.5s delay, then restore only Wi-Fi.
        try await Task.sleep(nanoseconds: 2_800_000_000)
        precondition(wake.pendingTrigger == .wake && wake.modelOwner.connections == 0)
        let online = SmartNetworkState(online: true, kind: .wifi, identity: "restored")
        wake.path = .init(next: online); wake.applyNetwork(online)
        precondition(wake.generation == wakeToken, "Network restored replaced the wake trigger")
        try await wake.waitUntil { wake.modelOwner.connections == 1 }
        precondition(wake.modelOwner.permissions == 3 && wake.pendingTrigger == nil, "Fresh permission boundaries or pending cleanup failed")
        let stopped = SmartHarness(); stopped.preferences.enabled = true; stopped.preferences.onWake = true
        stopped.path = .init(next: .init(online: false)); stopped.schedule(.wake); stopped.cancelPending()
        stopped.path = .init(next: online); stopped.applyNetwork(online)
        try await Task.sleep(nanoseconds: 30_000_000)
        precondition(stopped.modelOwner.connections == 0 && stopped.pendingTrigger == nil)
        print("PASS: production permission awaits the new snapshot, does not cancel itself, respects manual cancellation, and retains wake through delayed Wi-Fi with network-restored automation disabled; injected OS/model only.")
    }
}
@main struct SmartConnectionRaceRegression {
    static func main() async throws { try await SmartHarness.run() }
}
