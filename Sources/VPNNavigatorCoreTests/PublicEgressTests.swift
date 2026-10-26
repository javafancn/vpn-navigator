import XCTest
@testable import VPNNavigatorCore

final class PublicEgressTests: XCTestCase {
    private let profile = UUID(), attempt = UUID(), revision = UUID()
    private func makeReport(mode: RoutingMode = .fullVPN, revision: UUID? = nil, received: UInt64 = 0, attempt: UUID? = nil) -> SessionReport {
        .init(state: .connected, message: "not part of context", activeProfileID: profile, receivedBytes: received, sentBytes: 0,
            attemptID: attempt ?? self.attempt, networkRecoveryRequired: false, routingMode: mode,
            routingRevision: mode == .original ? nil : revision ?? self.revision, ipStack: .dual)
    }
    private var response: EgressHTTPResult { .init(address: "8.8.8.8", remoteAddress: "1.1.1.1", usedProxy: false, cacheHit: false, milliseconds: 100) }
    private func route(_ report: SessionReport, ip: String = "1.1.1.1", path: ExplainedPath = .vpn,
                       expected: String? = "utun4", observed: String = "utun4", matches: Bool? = true) throws -> RouteLookupResult {
        let request = try RouteLookupRequest(report: report, ip: ip)
        return .init(request: request, decision: .init(ip: ip, path: path, reason: "synthetic"), expectedInterface: expected,
            observedInterface: observed, observedGateway: "", matchesExpected: matches)
    }
    func testEndpointsAreFixedHTTPSWithoutIdentityOrQuery() {
        XCTAssertEqual(EgressFamily.ipv4.endpoint.host, "api.ipify.org"); XCTAssertEqual(EgressFamily.ipv6.endpoint.host, "api6.ipify.org")
        for family in EgressFamily.allCases {
            XCTAssertEqual(family.endpoint.scheme, "https"); XCTAssertNil(family.endpoint.user); XCTAssertNil(family.endpoint.password)
            XCTAssertNil(family.endpoint.query); XCTAssertNil(family.endpoint.fragment)
        }
    }
    func testPlainAddressParsingCanonicalizationAndLineEnding() throws {
        XCTAssertEqual(try PublicEgressAddress.parse(Data("8.8.8.8\r\n".utf8), family: .ipv4), "8.8.8.8")
        XCTAssertEqual(try PublicEgressAddress.parse(Data(" 2606:4700:4700:0000:0000:0000:0000:1111\n".utf8), family: .ipv6), "2606:4700:4700::1111")
    }
    func testJSONHTMLMultipleAddressesAndHiddenCharactersAreRejected() {
        for body in ["", "{\"ip\":\"8.8.8.8\"}", "<html>8.8.8.8</html>", "8.8.8.8\n1.1.1.1", "8.8.8.8\0", "8.8.8.8\u{200B}", "http://8.8.8.8/"] {
            XCTAssertThrowsError(try PublicEgressAddress.parse(Data(body.utf8), family: .ipv4))
        }
    }
    func testSizeAndFamilyMismatchAreExplicit() {
        XCTAssertThrowsError(try PublicEgressAddress.parse(Data(repeating: 32, count: 129), family: .ipv4)) { XCTAssertEqual($0 as? EgressProbeFailure, .tooLarge) }
        XCTAssertThrowsError(try PublicEgressAddress.parse(Data("8.8.8.8".utf8), family: .ipv6)) { XCTAssertEqual($0 as? EgressProbeFailure, .wrongFamily) }
    }
    func testPrivateSpecialAndDocumentationIPv4AreNotPublicResults() {
        for ip in ["0.0.0.0", "10.1.2.3", "100.64.0.1", "127.0.0.1", "169.254.1.1", "172.16.1.1", "192.168.1.1", "198.18.0.1", "192.0.2.1", "198.51.100.1", "203.0.113.1", "224.0.0.1", "255.255.255.255"] {
            XCTAssertFalse(PublicEgressAddress.isPublic(ip), ip)
        }
    }
    func testIPv6PublicScopeExcludesMappedScopedAndDocumentation() {
        for ip in ["::", "::1", "::ffff:8.8.8.8", "fe80::1", "fe80::1%en0", "fd12::1", "ff02::1", "2001:db8::1", "3fff::1"] { XCTAssertFalse(PublicEgressAddress.isPublic(ip), ip) }
        XCTAssertTrue(PublicEgressAddress.isPublic("2606:4700::1111"))
    }
    func testContextIgnoresCountersAndMessages() {
        XCTAssertEqual(EgressSessionContext(makeReport(received: 0)), EgressSessionContext(makeReport(received: 10_000)))
    }
    func testChangedAttemptModeRevisionAndHelperLossInvalidateResults() throws {
        let initial = makeReport(), before = EgressSessionContext(initial)
        for after in [EgressSessionContext(makeReport(attempt: UUID())), EgressSessionContext(makeReport(mode: .chinaDirect)), EgressSessionContext(makeReport(revision: UUID())), EgressSessionContext(nil)] {
            XCTAssertEqual(EgressPathAssessment.evaluate(family: .ipv4, response: response, before: before, after: after, route: try route(initial)), .stale)
        }
    }
    func testVPNPathRequiresActualMatchingInterface() throws {
        let report = makeReport(), context = EgressSessionContext(report)
        XCTAssertEqual(EgressPathAssessment.evaluate(family: .ipv4, response: response, before: context, after: context, route: try route(report)), .vpnRoute)
        XCTAssertEqual(EgressPathAssessment.evaluate(family: .ipv4, response: response, before: context, after: context, route: try route(report, observed: "en0", matches: false)), .mismatch)
    }
    func testProxyCacheAndMissingMetricsCannotProveVPNPath() throws {
        let report = makeReport(), context = EgressSessionContext(report), evidence = try route(report)
        for result in [EgressHTTPResult(address: "8.8.8.8", remoteAddress: "1.1.1.1", usedProxy: true, cacheHit: false, milliseconds: 1),
                       .init(address: "8.8.8.8", remoteAddress: "1.1.1.1", usedProxy: false, cacheHit: true, milliseconds: 1),
                       .init(address: "8.8.8.8", remoteAddress: nil, usedProxy: nil, cacheHit: nil, milliseconds: 1)] {
            XCTAssertEqual(EgressPathAssessment.evaluate(family: .ipv4, response: result, before: context, after: context, route: evidence), .unknown)
        }
    }
    func testTransportFamilyMismatchAndLoopbackPeerAreUnknown() throws {
        let report = makeReport(), context = EgressSessionContext(report)
        for peer in ["2606:4700::1111", "127.0.0.1"] {
            let result = EgressHTTPResult(address: "8.8.8.8", remoteAddress: peer, usedProxy: false, cacheHit: false, milliseconds: 1)
            XCTAssertEqual(EgressPathAssessment.evaluate(family: .ipv4, response: result, before: context, after: context, route: try route(report)), .unknown)
        }
    }
    func testRouteEvidenceMustReferToConnectedPeerAndSameSession() throws {
        let report = makeReport(), context = EgressSessionContext(report)
        for evidence in [try route(report, ip: "9.9.9.9"), try route(self.makeReport(attempt: UUID()))] {
            XCTAssertEqual(EgressPathAssessment.evaluate(family: .ipv4, response: response, before: context, after: context, route: evidence), .unknown)
        }
    }
    func testDirectRouteIsAnExplicitPolicyResult() throws {
        let report = makeReport(), context = EgressSessionContext(report)
        XCTAssertEqual(EgressPathAssessment.evaluate(family: .ipv4, response: response, before: context, after: context,
            route: try route(report, path: .direct, expected: "en0", observed: "en0")), .directRoute)
    }
    func testOriginalModeOnlyReportsSystemObservation() throws {
        let report = makeReport(mode: .original), context = EgressSessionContext(report)
        XCTAssertEqual(EgressPathAssessment.evaluate(family: .ipv4, response: response, before: context, after: context,
            route: try route(report, path: .system, expected: nil, observed: "en0", matches: nil)), .systemRoute)
    }
    func testBlockedFamilyWithSuccessfulResponseNeedsInvestigation() throws {
        let report = makeReport(), context = EgressSessionContext(report)
        XCTAssertEqual(EgressPathAssessment.evaluate(family: .ipv4, response: response, before: context, after: context,
            route: try route(report, path: .blocked, expected: nil, observed: "en0", matches: nil)), .mismatch)
    }
    func testKnownDisconnectedAndUnknownHelperAreDifferent() {
        let report = SessionReport(state: .disconnected, message: "", activeProfileID: nil, receivedBytes: nil, sentBytes: nil, networkRecoveryRequired: false)
        let context = EgressSessionContext(report)
        XCTAssertEqual(EgressPathAssessment.evaluate(family: .ipv4, response: response, before: context, after: context, route: nil), .standalone)
        XCTAssertEqual(EgressPathAssessment.evaluate(family: .ipv4, response: response, before: .init(nil), after: .init(nil), route: nil), .unknown)
    }
    func testUnsafeOrImplausibleInterfaceCannotBeVerified() throws {
        let report = makeReport(), context = EgressSessionContext(report)
        XCTAssertFalse(EgressPathAssessment.safeInterface("utun4\npassword")); XCTAssertFalse(EgressPathAssessment.safeInterface(String(repeating: "a", count: 33)))
        for iface in ["en0", "bad interface"] {
            XCTAssertEqual(EgressPathAssessment.evaluate(family: .ipv4, response: response, before: context, after: context,
                route: try route(report, expected: iface, observed: iface)), .unknown)
        }
    }
    func testRecoveryAndIncompleteConnectedStateCannotClaimVPN() {
        let incomplete = SessionReport(state: .connected, message: "", activeProfileID: profile, receivedBytes: nil, sentBytes: nil,
            attemptID: attempt, networkRecoveryRequired: false, routingMode: .fullVPN)
        XCTAssertFalse(EgressSessionContext(incomplete).verifiedConnection)
        let recovery = SessionReport(state: .connected, message: "", activeProfileID: profile, receivedBytes: nil, sentBytes: nil,
            attemptID: attempt, networkRecoveryRequired: true, routingMode: .original)
        XCTAssertFalse(EgressSessionContext(recovery).verifiedConnection)
    }
    func testIPv6RouteEvidenceUsesIPv6Peer() throws {
        let report = makeReport(), context = EgressSessionContext(report), peer = "2606:4700::1111"
        let result = EgressHTTPResult(address: "2606:4700:4700::1001", remoteAddress: peer, usedProxy: false, cacheHit: false, milliseconds: 10)
        XCTAssertEqual(EgressPathAssessment.evaluate(family: .ipv6, response: result, before: context, after: context, route: try route(report, ip: peer)), .vpnRoute)
    }
}
