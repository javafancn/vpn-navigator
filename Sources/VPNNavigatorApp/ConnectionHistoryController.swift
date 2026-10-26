import Foundation
import Combine
import VPNNavigatorCore

@MainActor
final class ConnectionHistoryController: ObservableObject {
    @Published private(set) var state = ConnectionHistoryState()
    @Published private(set) var busy = false
    @Published private(set) var actionProblem: String?
    private let store: ConnectionHistoryStore
    private weak var model: AppModel?
    private var subscription: AnyCancellable?
    private var started = false
    private var loading = false
    private struct Pending {
        let input: ConnectionHistoryInput
        let date: Date
        let uptime: Double
    }
    private var pending: [Pending] = []
    private var drain: Task<Void, Never>?
    init(model: AppModel, directory: URL) {
        self.model = model; store = .init(directory: directory)
        subscription = objectWillChange.sink { [weak model] _ in model?.objectWillChange.send() }
    }
    func start() async {
        guard !started, !loading, !ProcessInfo.processInfo.arguments.contains("--vpnnav-ui-demo-snapshot") else { return }
        loading = true; state = await store.open(); loading = false; started = true; schedule()
    }
    func observe(_ input: ConnectionHistoryInput, at date: Date = Date(), uptime: Double = ProcessInfo.processInfo.systemUptime) {
        guard !ProcessInfo.processInfo.arguments.contains("--vpnnav-ui-demo-snapshot") else { return }
        let value = Pending(input: input, date: date, uptime: uptime)
        // Keep polling bounded during a slow disk. A dropped interval is not
        // silently represented as continuous verified observation.
        if pending.count >= 64 { pending = [Pending(input: .unverified, date: date, uptime: uptime)] }
        pending.append(value); schedule()
    }
    private func schedule() {
        guard started, drain == nil, !pending.isEmpty else { return }
        drain = Task { [weak self] in
            guard let self else { return }
            while !self.pending.isEmpty {
                let next = self.pending.removeFirst()
                self.state = await self.store.consume(next.input, date: next.date, uptime: next.uptime)
            }
            self.drain = nil
        }
    }
    func waitForPending() async {
        await start()
        while let task = drain { await task.value }
    }
    func configure(_ preferences: ConnectionHistoryPreferences) async {
        guard !busy else { return }; busy = true; actionProblem = nil; defer { busy = false }
        await waitForPending()
        do { state = try await store.configure(preferences) }
        catch { actionProblem = error.localizedDescription }
    }
    func clearAndPause() async {
        guard !busy else { return }; busy = true; actionProblem = nil; defer { busy = false }
        await waitForPending()
        do { state = try await store.clearAndPause() }
        catch { actionProblem = error.localizedDescription }
    }
    func clearForMaintenance() async throws {
        await waitForPending(); state = try await store.clearAndPause()
    }
    func showSnapshot(profiles: [VPNProfile]) {
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true", ProcessInfo.processInfo.arguments.contains("--vpnnav-ui-demo-snapshot"), let profile = profiles.first else { return }
        let now = Date(), attempt = UUID(); var tracker = ConnectionHistoryTracker(now: now)
        tracker.consume(.begin(profileID: profile.id, attemptID: attempt), at: now.addingTimeInterval(-90), uptime: 10)
        tracker.consume(.report(.init(.init(state: .connected, message: "", activeProfileID: profile.id, receivedBytes: 0, sentBytes: 0, attemptID: attempt, networkRecoveryRequired: false, routingMode: .original))), at: now.addingTimeInterval(-80), uptime: 20)
        for i in 1...8 {
            tracker.consume(.report(.init(.init(state: .connected, message: "", activeProfileID: profile.id, receivedBytes: UInt64(i * 1_000_000), sentBytes: UInt64(i * 100_000), attemptID: attempt, networkRecoveryRequired: false, routingMode: .original))), at: now.addingTimeInterval(-80 + Double(i * 10)), uptime: 20 + Double(i * 10))
        }
        state = .init(records: tracker.records, preferences: tracker.preferences, quality: tracker.quality)
    }
}
