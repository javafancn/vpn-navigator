import XCTest
@testable import VPNNavigatorCore

final class SafetyAndPlanningTests: XCTestCase {
    private let inline = """
    client
    dev tun
    proto udp
    remote vpn.example.com 1194
    auth-user-pass
    <ca>
    -----BEGIN CERTIFICATE-----
    FAKE TEST DATA
    -----END CERTIFICATE-----
    </ca>
    """

    func testSafeProfileAndCredentialIndicator() throws {
        let validated = try ProfileSafety.validate(inline)
        XCTAssertEqual(validated.remoteHosts, ["vpn.example.com"])
        XCTAssertTrue(validated.requestsCredentials)
    }
    func testRejectUnsafeScriptsAndReferences() throws {
        for directive in ["script-security 3", "up /tmp/x", "plugin /tmp/evil.so",
                          "management 127.0.0.1 9999", "auth-user-pass /tmp/secrets",
                          "ca /tmp/my-ca.pem", "route-noexec", "redirect-gateway def1"] {
            XCTAssertThrowsError(try ProfileSafety.validate(inline + "\n" + directive))
        }
    }
    func testRejectMissingCAAndRemote() {
        XCTAssertThrowsError(try ProfileSafety.validate("client\nremote vpn.example"))
        XCTAssertThrowsError(try ProfileSafety.validate("client\n<ca>\nfoo\n</ca>"))
        XCTAssertThrowsError(try ProfileSafety.validate(inline + "\n<key>\nabc"))
    }
    func testPlanOrderAndLocalPreservation() throws {
        let rules = try RuleSet(text: "223.5.5.0/24\n1.0.1.0/24")
        let plan = try RoutePlanner.build(serverIPv4: "203.0.113.7",
            physicalGateway: "192.168.1.1", vpnInterface: "utun4",
            localPrefixes: [try IPv4CIDR("192.168.1.0/24")], china: rules)
        XCTAssertEqual(plan.installOrder.first?.prefix.description, "203.0.113.7/32")
        XCTAssertEqual(plan.installOrder.last?.prefix.description, "128.0.0.0/1")
        XCTAssertEqual(plan.direct.count, 2)
        XCTAssertEqual(plan.installOrder[1].arguments(adding: true),
                       ["-n", "add", "-net", "1.0.1.0/24", "192.168.1.1"])
        XCTAssertEqual(plan.removalOrder.first?.prefix.description, "128.0.0.0/1")
    }
    func testCommonDeclarativeOpenVPNRoutingAndDNS() throws {
        let config = inline + """
        
        redirect-gateway def1
        route 10.20.0.0 255.255.0.0 vpn_gateway
        dhcp-option DNS 10.8.0.1
        """
        XCTAssertNoThrow(try ProfileSafety.validate(config))
        XCTAssertThrowsError(try ProfileSafety.validate(inline + "\nredirect-gateway block-local"))
        XCTAssertThrowsError(try ProfileSafety.validate(inline + "\nroute-up /tmp/run.sh"))
    }
    func testRejectBadInterfaceAndGateway() throws {
        let rules = try RuleSet(text: "223.5.5.0/24")
        XCTAssertThrowsError(try RoutePlanner.build(serverIPv4: "8.8.8.8", physicalGateway: "bad", vpnInterface: "utun0", localPrefixes: [], china: rules))
        XCTAssertThrowsError(try RoutePlanner.build(serverIPv4: "8.8.8.8", physicalGateway: "192.168.1.1", vpnInterface: "en0", localPrefixes: [], china: rules))
    }
    func testManagementCredentialEscaping() {
        XCTAssertEqual(ManagementEscaping.escape("a\\b"), "a\\\\b")
        XCTAssertEqual(ManagementEscaping.escape("a\"b"), "a\\\"b")
        XCTAssertTrue(ManagementParser.parsePasswordChallenge(">PASSWORD:Need 'Auth' username/password"))
        XCTAssertFalse(ManagementParser.parsePasswordChallenge(">PASSWORD:Need 'Private Key' password"))
    }
    func testManagementConnectedLine() {
        let value = ManagementParser.parseState(">STATE:1690000000,CONNECTED,SUCCESS,10.8.0.2,203.0.113.7")
        XCTAssertEqual(value?.state, .connected)
        XCTAssertEqual(value?.remoteIPv4, "203.0.113.7")
        XCTAssertEqual(value?.localTunnelIPv4, "10.8.0.2")
    }
}
