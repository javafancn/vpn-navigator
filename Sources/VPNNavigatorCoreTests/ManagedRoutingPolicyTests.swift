import XCTest
@testable import VPNNavigatorCore

final class ManagedRoutingPolicyTests: XCTestCase {
    private let base = """
        client
        dev tun
        proto udp
        remote vpn.example.com 1194
        dhcp-option DNS 10.8.0.1
        <ca>
        TEST CERT
        </ca>
        """
    func testManagedModesRejectExplicitRouteOverrides() throws {
        for directive in [
            "route 10.0.0.0 255.0.0.0 vpn_gateway",
            "route-ipv6 2001:db8::/32",
            "redirect-gateway def1"
        ] {
            let profile = try ProfileSafety.validate(base + "\n" + directive)
            XCTAssertNoThrow(try ManagedRoutingPolicy.validate(profile, mode: .original))
            XCTAssertThrowsError(try ManagedRoutingPolicy.validate(profile, mode: .chinaDirect))
            XCTAssertThrowsError(try ManagedRoutingPolicy.validate(profile, mode: .fullVPN))
        }
    }

    func testEmbeddedCertificateCannotMasqueradeAsRoutingDirective() throws {
        let sample = base.replacingOccurrences(of: "TEST CERT", with:
            "route 10.0.0.0 255.0.0.0 vpn_gateway")
        let profile = try ProfileSafety.validate(sample)
        XCTAssertNoThrow(try ManagedRoutingPolicy.validate(profile, mode: .chinaDirect))
    }

    func testInlineCaAndDnsArePreserved() throws {
        let profile = try ProfileSafety.validate(base)
        XCTAssertNoThrow(try ManagedRoutingPolicy.validate(profile, mode: .chinaDirect))
        XCTAssertNoThrow(try ManagedRoutingPolicy.validate(profile, mode: .fullVPN))
        let options = ManagedRoutingPolicy.openVPNArguments(mode: .fullVPN)
        XCTAssertTrue(options.contains("route "))
        XCTAssertTrue(options.contains("route-ipv6"))
        XCTAssertFalse(options.contains("route-gateway"))
        XCTAssertTrue(options.contains("--route-noexec"))
        XCTAssertFalse(options.contains("--redirect-gateway"))
        XCTAssertEqual(ManagedRoutingPolicy.openVPNArguments(mode: .original), [])
    }

    func testChinaDirectOwnsRouteNoexec() {
        let options = ManagedRoutingPolicy.openVPNArguments(mode: .chinaDirect)
        XCTAssertTrue(options.contains("--route-noexec"))
        XCTAssertFalse(options.contains("--redirect-gateway"))
    }
}
