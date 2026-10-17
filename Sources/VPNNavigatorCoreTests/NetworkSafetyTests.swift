import XCTest
@testable import VPNNavigatorCore

final class NetworkSafetyTests: XCTestCase {
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
