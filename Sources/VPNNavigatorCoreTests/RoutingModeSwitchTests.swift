import Foundation
import XCTest
@testable import VPNNavigatorCore

final class RoutingModeSwitchTests: XCTestCase {
    private let country = (0..<100).map { "11.0.\($0).0/24" }.joined(separator: "\n")
    private var local: [IPv4CIDR] { [try! IPv4CIDR("192.168.1.0/24")] }
    private func full() throws -> RoutePlan {
        try RoutePlanner.build(serverIPv4: "203.0.113.7", physicalGateway: "192.168.1.1",
                               vpnInterface: "utun4", localPrefixes: local, china: nil)
    }
    func testFullStartsWithOnlyEndpointAndTwoDefaults() throws {
        let plan = try full()
        XCTAssertEqual(plan.installOrder.count, 3)
        XCTAssertEqual(plan.direct, [])
        XCTAssertEqual(plan.vpnDefaults.map(\.prefix.description), ["0.0.0.0/1", "128.0.0.0/1"])
        XCTAssertEqual(ManagedRoutingPolicy.openVPNArguments(mode: .fullVPN), ManagedRoutingPolicy.openVPNArguments(mode: .chinaDirect))
    }
    func testRoundTripChangesOnlyDirectRoutes() throws {
        let before = try full()
        let split = try ManagedRouteTransition(current: before, target: .chinaDirect, ruleText: country, local: local)
        XCTAssertEqual(split.added.count, 100); XCTAssertEqual(split.removed, [])
        XCTAssertFalse(split.tightensDirectAccess)
        let global = try ManagedRouteTransition(current: split.plan, target: .fullVPN, ruleText: "", local: local)
        XCTAssertEqual(global.removed, split.added); XCTAssertEqual(global.added, [])
        XCTAssertTrue(global.tightensDirectAccess)
        XCTAssertEqual(global.plan.endpoint, before.endpoint)
        XCTAssertEqual(global.plan.vpnDefaults, before.vpnDefaults)
    }
    func testRulesCannotReplaceLocalNetworkOrEndpoint() throws {
        let initial = try RoutePlanner.build(serverIPv4: "11.0.99.8", physicalGateway: "192.168.1.1",
            vpnInterface: "utun4", localPrefixes: local, china: nil)
        let change = try ManagedRouteTransition(current: initial, target: .chinaDirect,
            ruleText: country + "\n11.0.99.8/32", local: local + [try IPv4CIDR("11.0.2.0/24")])
        XCTAssertFalse(change.added.contains { $0.prefix.description == "11.0.2.0/24" })
        XCTAssertFalse(change.added.contains { $0.prefix == initial.endpoint.prefix })
        XCTAssertEqual(change.plan.endpoint, initial.endpoint)
    }
    func testBadRulesAndOriginalDoNotProduceTransition() throws {
        let plan = try full()
        XCTAssertThrowsError(try ManagedRouteTransition(current: plan, target: .chinaDirect, ruleText: "11.0.1.0/24", local: local))
        XCTAssertThrowsError(try ManagedRouteTransition(current: plan, target: .chinaDirect, ruleText: country + "\n0.0.0.0/0", local: local))
        XCTAssertThrowsError(try ManagedRouteTransition(current: plan, target: .original, ruleText: "", local: local))
        XCTAssertThrowsError(try ManagedRouteTransition(current: plan, target: .fullVPN, ruleText: String(repeating: "x", count: 2_000_001), local: local))
    }
    func testRepeatedPolicyHasNoRouteDelta() throws {
        let split = try ManagedRouteTransition(current: full(), target: .chinaDirect, ruleText: country, local: local)
        let repeated = try ManagedRouteTransition(current: split.plan, target: .chinaDirect, ruleText: country, local: local)
        XCTAssertEqual(repeated.added, []); XCTAssertEqual(repeated.removed, [])
    }
    func testSwitchRequestRejectsIdentityAndRevisionChangesIncludingABA() throws {
        let profile = UUID(), attempt = UUID(), revision = UUID()
        func report(_ p: UUID? = nil, _ a: UUID? = nil, _ r: UUID? = nil,
                    _ mode: RoutingMode = .fullVPN, _ state: TunnelState = .connected) -> SessionReport {
            SessionReport(state: state, message: "", activeProfileID: p ?? profile, receivedBytes: 12, sentBytes: 34,
                attemptID: a ?? attempt, routingMode: mode, routingRevision: r ?? revision)
        }
        let request = try RoutingModeSwitchRequest(report: report(), target: .chinaDirect)
        XCTAssertTrue(request.matches(report()))
        XCTAssertFalse(request.matches(report(UUID())))
        XCTAssertFalse(request.matches(report(profile, UUID())))
        XCTAssertFalse(request.matches(report(profile, attempt, UUID())))
        XCTAssertFalse(request.matches(report(profile, attempt, revision, .chinaDirect)))
        XCTAssertFalse(request.matches(report(profile, attempt, revision, .fullVPN, .stopping)))
        XCTAssertThrowsError(try RoutingModeSwitchRequest(report: report(), target: .original))
        XCTAssertThrowsError(try RoutingModeSwitchRequest(report: report(profile, attempt, revision, .original), target: .fullVPN))
    }
    func testLegacyReportDoesNotInventAnActualRouteMode() throws {
        let legacy = SessionReport(state: .connected, message: "Full VPN", activeProfileID: UUID(),
            receivedBytes: 0, sentBytes: 0, attemptID: UUID())
        let decoded = try JSONDecoder().decode(SessionReport.self, from: JSONEncoder().encode(legacy))
        XCTAssertNil(decoded.routingMode); XCTAssertNil(decoded.routingRevision)
        XCTAssertThrowsError(try RoutingModeSwitchRequest(report: decoded, target: .chinaDirect))
    }
}
