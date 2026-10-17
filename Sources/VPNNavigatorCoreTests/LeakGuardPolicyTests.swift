import XCTest
@testable import VPNNavigatorCore

final class LeakGuardPolicyTests: XCTestCase {
    func testPolicyBlocksAllOtherInterfacesAndIPv6() throws {
        let policy = try LeakGuardPolicy(physical: "en0", endpoint: "8.8.8.8", port: 1194,
            transport: .udp, local: [IPv4CIDR("192.168.1.0/24")], country: [])
        let before = try policy.rules(tunnel: nil)
        XCTAssertFalse(before.contains("on utun"))
        let after = try policy.rules(tunnel: "utun4")
        XCTAssertTrue(after.contains("pass out quick on utun4 inet"))
        XCTAssertTrue(after.contains("block drop out quick inet from any to any"))
        XCTAssertTrue(after.contains("block drop out quick inet6 from any to any"))
        XCTAssertFalse(after.contains("pass out quick on en0 all"))
        XCTAssertFalse(after.contains("pass out quick on utun4 inet6"))
        XCTAssertTrue(after.contains("on utun4 inet from any to any keep state (if-bound)"))
        XCTAssertTrue(after.contains("on lo0 all no state"))
        XCTAssertThrowsError(try policy.rules(tunnel: "utun4\npass all"))
    }
    func testGuardRefusesBroadAndPrivateCountryExceptions() throws {
        for prefix in ["0.0.0.0/0", "128.0.0.0/1", "192.168.0.0/16"] {
            XCTAssertThrowsError(try LeakGuardPolicy(physical: "en0", endpoint: "8.8.8.8", port: 443,
                transport: .tcp, local: [IPv4CIDR("192.168.1.0/24")], country: [IPv4CIDR(prefix)]))
        }
    }
    func testHostMustEvaluateOwnedAnchorBeforeOtherRules() {
        XCTAssertTrue(LeakGuardPolicy.compatibleRootRules("anchor \"com.apple/*\" all\n"))
        XCTAssertTrue(LeakGuardPolicy.compatibleRootRules("scrub-anchor \"com.apple/*\" all fragment reassemble\nanchor \"com.apple/*\" all"))
        XCTAssertFalse(LeakGuardPolicy.compatibleRootRules("pass out quick all\nanchor \"com.apple/*\" all"))
        XCTAssertFalse(LeakGuardPolicy.compatibleRootRules(""))
        XCTAssertFalse(LeakGuardPolicy.compatibleRootRules("anchor \"other/*\" all"))
    }
    func testEnableTokenCannotBecomeAnArgument() {
        XCTAssertEqual(LeakGuardPolicy.enableToken("pf enabled\nToken : 123456789\n"), "123456789")
        XCTAssertNil(LeakGuardPolicy.enableToken("Token : -d"))
        XCTAssertNil(LeakGuardPolicy.enableToken("Token : 123\" -d"))
        XCTAssertNil(LeakGuardPolicy.enableToken("Token : 99999999999999999999999999"))
    }
    func testEndpointIsPinnedWithoutChangingInlineCertificateData() throws {
        let profile = "client\ndev tun\nproto tcp-client\nremote vpn.example 443\nremote backup.example 444\nremote-random\n<ca>\nremote certificate data\n</ca>"
        let endpoint = try GuardEndpoint.parse(profile)
        XCTAssertEqual(endpoint.host, "vpn.example")
        let pinned = try endpoint.pinnedProfile(profile, address: "8.8.8.8")
        XCTAssertFalse(pinned.contains("backup.example"))
        XCTAssertTrue(pinned.contains("remote 8.8.8.8 443"))
        XCTAssertTrue(pinned.contains("proto tcp4-client"))
        XCTAssertTrue(pinned.contains("remote certificate data"))
        XCTAssertNoThrow(try ProfileSafety.validate(pinned))
    }
}
