#if DEBUG
import Foundation
import VPNNavigatorCore

enum CoreOptimizationSelfTest {
    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("optimized-core-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ruleRoot = root.appendingPathComponent("Rules")
        let rules = try RuleSet(text: (0..<100).map { "11.0.\($0).0/24" }.joined(separator: "\n"))
        try await RoutingRuleUpdate.commit(root: ruleRoot, ipv4: rules, ipv6: nil) { _ in "NO_ACTIVE_SPLIT" }
        for _ in 0..<20 {
            guard try await RoutingRuleUpdate.cached(root: ruleRoot).ipv4?.routes == rules.routes else { throw Failure.check }
        }
        let file = ruleRoot.appendingPathComponent("routing-rules.json"), original = try Data(contentsOf: file)
        try ProfileFileIO.write(Data("malformed".utf8), to: file)
        do { _ = try await RoutingRuleUpdate.cached(root: ruleRoot); throw Failure.check }
        catch Failure.check { throw Failure.check } catch { }
        try ProfileFileIO.write(original, to: file)
        guard try await RoutingRuleUpdate.cached(root: ruleRoot).ipv4?.routes == rules.routes else { throw Failure.check }

        let now = Date(), profile = UUID()
        var tracker = ConnectionHistoryTracker(now: now)
        for i in 0..<220 {
            let date = now.addingTimeInterval(Double((i * 37) % 220) - 300), attempt = UUID()
            tracker.consume(.begin(profileID: profile, attemptID: attempt), at: date, uptime: Double(i * 3))
            tracker.consume(.report(.init(.init(state: .connected, message: "", activeProfileID: profile,
                receivedBytes: 10, sentBytes: 10, attemptID: attempt, networkRecoveryRequired: false, routingMode: .original))),
                at: date, uptime: Double(i * 3 + 1))
            tracker.consume(.report(.init(.init(state: .disconnected, message: "", activeProfileID: nil,
                receivedBytes: nil, sentBytes: nil, attemptID: attempt, networkRecoveryRequired: false))),
                at: date, uptime: Double(i * 3 + 2))
        }
        let records = tracker.records
        guard records.count == 200, zip(records, records.dropFirst()).allSatisfy({ $0.lastObservedAt >= $1.lastObservedAt }),
              ConnectionHistoryTracker(archive: tracker.archive, now: now).records == records else { throw Failure.check }
        let history = ConnectionHistoryStore(directory: root.appendingPathComponent("History"))
        let before = await history.open(now: now)
        let after = await history.consume(.unverified, date: now, uptime: 1)
        guard before == after else { throw Failure.check }
        print("PASS: parsed rule cache reuses valid snapshots, rejects changed malformed input and recovers after replacement; 220 out-of-order sessions retain the newest 200 in order without repeated sorting; unchanged history states compare equal.")
    }
    enum Failure: Error { case check }
}
#endif
