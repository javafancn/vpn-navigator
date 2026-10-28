import XCTest
@testable import VPNNavigatorCore

final class NetworkSafetyTests: XCTestCase {
    private let scoped = """
        Internet6:
        Destination Gateway Flags Netif Expire
        default fe80::%utun7 UGcIg utun7
        default fe80::%utun8 UGcIg utun8
        ::1 ::1 UHL lo0
        """
    private let localInterfaces = """
        lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
            inet6 ::1 prefixlen 128
        en1: flags=8863<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> mtu 1500
            inet 192.168.20.2 netmask 0xffffff00
            inet6 fe80::1%en1 prefixlen 64
        utun7: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1380
            inet6 fe80::7%utun7 prefixlen 64
        utun8: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1380
            inet6 fe80::8%utun8 prefixlen 64
        """
    func testScopedDefaultsNeedBothRouteAndAddressEvidence() {
        XCTAssertEqual(IPv6RouteSafety.evaluate(scoped), .tunnelOnly)
        XCTAssertEqual(IPv6RouteSafety.evaluate(scoped, interfaces: localInterfaces), .linkLocalOnly)
    }
    func testGlobalOrULASourcePreventsScopedRouteExemption() {
        for source in ["2001:db8::2", "fd12::2", "::ffff:192.0.2.1", "::"] {
            let interfaces = localInterfaces + "\n    inet6 " + source + " prefixlen 64\n"
            XCTAssertEqual(IPv6RouteSafety.evaluate(scoped, interfaces: interfaces), .tunnelOnly)
        }
    }
    func testPhysicalDefaultNeverUsesLinkLocalExemption() {
        for flags in ["UGc", "UGcI"] {
            let physical = scoped + "\ndefault fe80::1%en1 " + flags + " en1\n"
            XCTAssertEqual(IPv6RouteSafety.evaluate(physical, interfaces: localInterfaces), .physicalBypass)
        }
    }
    func testUnscopedTunnelAndWrongScopeRemainBlocked() {
        for text in [scoped.replacingOccurrences(of: "UGcIg", with: "UGcg"),
                     scoped.replacingOccurrences(of: "UGcIg", with: "UGcig"),
                     scoped.replacingOccurrences(of: "fe80::%utun7", with: "fe80::1%utun9"),
                     scoped.replacingOccurrences(of: "fe80::%utun7", with: "2001:db8::1")] {
            XCTAssertEqual(IPv6RouteSafety.evaluate(text, interfaces: localInterfaces), .tunnelOnly)
        }
    }
    func testIncompleteOrMalformedInterfaceEvidenceCannotRelaxChecks() {
        for interfaces in ["", "ifconfig: failed", localInterfaces.replacingOccurrences(of: "utun8:", with: "utun9:"),
                           localInterfaces.replacingOccurrences(of: "fe80::8%utun8", with: "not-an-address"),
                           localInterfaces.replacingOccurrences(of: "fe80::8%utun8", with: "fe80::8%utun9")] {
            XCTAssertEqual(IPv6RouteSafety.evaluate(scoped, interfaces: interfaces), .tunnelOnly)
        }
    }
    func testMalformedDefaultIsNotTreatedAsNoRoute() {
        for text in [scoped + "\ndefault fe80::1 UGSc\n", scoped.replacingOccurrences(of: "UGcIg", with: "???")] {
            XCTAssertEqual(IPv6RouteSafety.evaluate(text, interfaces: localInterfaces), .unknown)
        }
    }
    func testNewAddressOrPhysicalRouteInvalidatesPreviouslyBenignSnapshot() {
        XCTAssertEqual(IPv6RouteSafety.evaluate(scoped, interfaces: localInterfaces), .linkLocalOnly)
        XCTAssertEqual(IPv6RouteSafety.evaluate(scoped, interfaces: localInterfaces + "\n    inet6 fd12::2 prefixlen 64\n"), .tunnelOnly)
        XCTAssertEqual(IPv6RouteSafety.evaluate(scoped + "\ndefault fe80::1%en1 UGc en1\n", interfaces: localInterfaces), .physicalBypass)
    }
    func testIPv6NoDefaultIsNotABypass() {
        let output = """
        Internet6:
        Destination                             Gateway Flags Netif Expire
        ::1                                     ::1       UHL   lo0
        fe80::/64                               link#5    U     en0
        """
        XCTAssertEqual(IPv6RouteSafety.evaluate(output), .noDefaultRoute)
    }
    func testIPv6PhysicalDefaultIsRejectedEvenWithTunnelDefault() {
        let output = """
        Internet6:
        Destination                             Gateway Flags Netif Expire
        default                                 fe80::abcd%en0 UGSc en0
        default                                 link#16 UGSc utun4
        """
        XCTAssertEqual(IPv6RouteSafety.evaluate(output), .physicalBypass)
    }
    func testTunnelDefaultAndUnparseableOutput() {
        let output = """
        Internet6:
        Destination Gateway Flags Netif Expire
        default link#16 UGSc utun4
        """
        XCTAssertEqual(IPv6RouteSafety.evaluate(output), .tunnelOnly)
        XCTAssertEqual(IPv6RouteSafety.evaluate("route command failed"), .unknown)
        XCTAssertEqual(IPv6RouteSafety.evaluate("Internet6:\nDestination Gateway Flags Netif\ndefault fe80::1 UGSc"), .unknown)
    }
    func testCIDROverlapCases() throws {
        let a = try IPv4CIDR("192.168.0.0/16")
        XCTAssertTrue(a.overlaps(try IPv4CIDR("192.168.1.0/24")))
        XCTAssertFalse(a.overlaps(try IPv4CIDR("192.167.1.0/24")))
        XCTAssertTrue((try IPv4CIDR("0.0.0.0/0")).overlaps(a))
        XCTAssertTrue((try IPv4CIDR("223.5.5.5/32")).overlaps(try IPv4CIDR("223.5.5.0/24")))
    }
}
