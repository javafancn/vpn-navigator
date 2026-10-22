import XCTest
@testable import VPNNavigatorCore

final class RouteExplanationTests: XCTestCase {
    func testCustomRulesOverrideCountryAndFullMode() throws {
        let country = try RuleSet(text: "11.0.0.0/8")
        let custom = try CustomRuleSet([.init(cidr: "11.1.0.0/16", action: .vpn), .init(cidr: "9.9.9.9", action: .direct)])
        XCTAssertEqual(try RouteExplanation.decide(ip: "11.1.1.1", mode: .chinaDirect, country: country, custom: custom).path, .vpn)
        XCTAssertEqual(try RouteExplanation.decide(ip: "11.2.1.1", mode: .chinaDirect, country: country, custom: custom).path, .direct)
        XCTAssertEqual(try RouteExplanation.decide(ip: "9.9.9.9", mode: .fullVPN, country: nil, custom: custom).path, .direct)
        XCTAssertEqual(try RouteExplanation.decide(ip: "9.9.9.9", mode: .original, country: country, custom: custom).path, .system)
    }
    func testEndpointLANAndSystemReservedAddressesTakePrecedence() throws {
        let custom = try CustomRuleSet([.init(cidr: "9.9.9.9", action: .vpn), .init(cidr: "10.66.0.0/16", action: .vpn)])
        XCTAssertEqual(try RouteExplanation.decide(ip: "9.9.9.9", mode: .fullVPN, country: nil, custom: custom, endpoint: "9.9.9.9").path, .direct)
        XCTAssertEqual(try RouteExplanation.decide(ip: "10.66.1.1", mode: .fullVPN, country: nil, custom: custom, local: [IPv4CIDR("10.66.1.0/24")]).path, .direct)
        XCTAssertEqual(try RouteExplanation.decide(ip: "127.0.0.1", mode: .fullVPN, country: nil, custom: .empty).path, .system)
    }
    func testMissingRulesAndExcludedCountryAreExplicit() throws {
        XCTAssertEqual(try RouteExplanation.decide(ip: "11.1.1.1", mode: .chinaDirect, country: nil, custom: .empty).path, .unknown)
        let country = try RuleSet(text: "11.0.0.0/8")
        let result = try RouteExplanation.decide(ip: "11.2.1.1", mode: .chinaDirect, country: country, custom: .empty, local: [IPv4CIDR("11.1.0.0/16")])
        XCTAssertEqual(result.path, .vpn); XCTAssertTrue(result.reason.contains("冲突"))
    }
    func testRequestBindsProfileAttemptModeAndRevision() throws {
        let id = UUID(), attempt = UUID(), rev = UUID()
        func report(_ state: TunnelState = .connected, profile: UUID? = nil, token: UUID? = nil, revision: UUID? = nil, mode: RoutingMode = .fullVPN) -> SessionReport {
            SessionReport(state: state, message: "", activeProfileID: profile ?? id, receivedBytes: nil, sentBytes: nil,
                          attemptID: token ?? attempt, routingMode: mode, routingRevision: revision ?? rev)
        }
        let request = try RouteLookupRequest(report: report(), ip: "9.9.9.9")
        XCTAssertEqual(try RouteLookupRequest.decoded(request.json), request)
        XCTAssertFalse(request.matches(report(.failed))); XCTAssertFalse(request.matches(report(profile: UUID())))
        XCTAssertFalse(request.matches(report(token: UUID()))); XCTAssertFalse(request.matches(report(revision: UUID())))
        XCTAssertFalse(request.matches(report(mode: .chinaDirect)))
        XCTAssertThrowsError(try RouteLookupRequest(report: report(), ip: "9.9.9.9; delete"))
        XCTAssertThrowsError(try RouteLookupRequest.decoded(String(repeating: "x", count: 2049)))
    }
    func testOriginalAllowsNilRevisionButManagedAndUnknownReportsDoNot() throws {
        let original = SessionReport(state: .connected, message: "", activeProfileID: UUID(), receivedBytes: nil, sentBytes: nil, attemptID: UUID(), routingMode: .original)
        XCTAssertNoThrow(try RouteLookupRequest(report: original, ip: "127.0.0.1"))
        let legacy = SessionReport(state: .connected, message: "", activeProfileID: UUID(), receivedBytes: nil, sentBytes: nil, attemptID: UUID(), routingMode: .fullVPN)
        XCTAssertThrowsError(try RouteLookupRequest(report: legacy, ip: "9.9.9.9"))
    }
    func testChecklistDoesNotMistakeConnectedOwnershipJournalsForRecoveryFailure() {
        let connected = SessionReport(state: .connected, message: "", activeProfileID: UUID(), receivedBytes: nil, sentBytes: nil, networkRecoveryRequired: true)
        XCTAssertFalse(TroubleshootingChecklist.session(connected).contains { $0.severity == .failure })
        let failed = SessionReport(state: .failed, message: "", activeProfileID: nil, receivedBytes: nil, sentBytes: nil, networkRecoveryRequired: true)
        XCTAssertTrue(TroubleshootingChecklist.session(failed).contains { $0.id == "session" && $0.severity == .failure })
        XCTAssertTrue(TroubleshootingChecklist.session(nil).contains { $0.id == "helper" && $0.severity == .failure })
    }
    func testTargetFailuresAreWarningsAndCountryIsOnlyRequiredForRuleMode() {
        XCTAssertEqual(TroubleshootingChecklist.tcp(false).severity, .warning)
        XCTAssertEqual(TroubleshootingChecklist.dns(false).severity, .warning)
        XCTAssertEqual(TroubleshootingChecklist.rules(mode: .chinaDirect, count: 0).severity, .failure)
        XCTAssertEqual(TroubleshootingChecklist.rules(mode: .fullVPN, count: 0).severity, .info)
    }
    func testRecentFailureIsBoundedToCurrentSessionAndContainsNoRawOutput() {
        let start = DiagnosticEvent(.starting, date: Date().addingTimeInterval(-4))
        let failure = DiagnosticEvent(.authentication, date: Date().addingTimeInterval(-3))
        let stop = DiagnosticEvent(.stopped, date: Date().addingTimeInterval(-2))
        XCTAssertNotNil(TroubleshootingChecklist.recentFailure([start, failure, stop]))
        XCTAssertNil(TroubleshootingChecklist.recentFailure([start, failure, DiagnosticEvent(.connected)]))
        XCTAssertNil(TroubleshootingChecklist.recentFailure([DiagnosticEvent(.authentication, date: Date().addingTimeInterval(-90_000))]))
    }
}
