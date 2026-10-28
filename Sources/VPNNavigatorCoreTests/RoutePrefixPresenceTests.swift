import XCTest
@testable import VPNNavigatorCore

final class RoutePrefixPresenceTests: XCTestCase {
    private let header4 = "Routing tables\n\nInternet:\nDestination Gateway Flags Netif Expire\n"
    private let header6 = "Routing tables\n\nInternet6:\nDestination Gateway Flags Netif Expire\n"

    func testExactPrefixRatherThanCoveringRoute() throws {
        let table = header4 + "default 192.0.2.1 UGScg en0\n198.51.100/24 192.0.2.1 UGSc en0\n203.0.113.7 192.0.2.1 UGHS en0\n"
        XCTAssertEqual(RoutePrefixPresence.ipv4(try IPv4CIDR("198.51.100.0/24"), table: table), .present)
        XCTAssertEqual(RoutePrefixPresence.ipv4(try IPv4CIDR("203.0.113.7/32"), table: table), .present)
        XCTAssertEqual(RoutePrefixPresence.ipv4(try IPv4CIDR("198.51.100.0/25"), table: table), .absent)
        XCTAssertEqual(RoutePrefixPresence.ipv4(try IPv4CIDR("192.0.2.0/24"), table: table), .absent)
    }
    func testForeignGatewayAndScopedInterfaceStillProvePresence() throws {
        let table = header4 + "203.0.113/24 192.0.2.99 UGScI utun7\n"
        XCTAssertEqual(RoutePrefixPresence.ipv4(try IPv4CIDR("203.0.113.0/24"), table: table), .present)
    }
    func testMissingMalformedAndUnfamiliarTablesAreUnknown() throws {
        let target = try IPv4CIDR("203.0.113.0/24")
        for table in ["", "permission denied", "Internet:\n", header4 + "truncated\n",
                      header4 + "198.51.100.0 192.0.2.1 U en0\n"] {
            XCTAssertEqual(RoutePrefixPresence.ipv4(target, table: table), .unknown)
        }
    }
    func testAbbreviatedNaturalNetworkPrefixes() throws {
        let table = header4 + "10 link#1 UCS en0\n169.254 link#1 UCS en0\n"
        XCTAssertEqual(RoutePrefixPresence.ipv4(try IPv4CIDR("10.0.0.0/8"), table: table), .present)
        XCTAssertEqual(RoutePrefixPresence.ipv4(try IPv4CIDR("169.254.0.0/16"), table: table), .present)
    }
    func testIPv6PrefixesHostsAndScopes() throws {
        let table = header6 + "default fe80::1%en0 UGc en0\nfe80::%utun9/64 link#9 UcI utun9\n2001:db8:42::/48 link#9 Uc utun9\n2001:db8::7 link#9 UHL lo0\n"
        XCTAssertEqual(RoutePrefixPresence.ipv6(try IPv6CIDR("fe80::/64"), table: table), .present)
        XCTAssertEqual(RoutePrefixPresence.ipv6(try IPv6CIDR("2001:db8:42::/48"), table: table), .present)
        XCTAssertEqual(RoutePrefixPresence.ipv6(try IPv6CIDR("2001:db8::7/128"), table: table), .present)
        XCTAssertEqual(RoutePrefixPresence.ipv6(try IPv6CIDR("2001:db8:99::/48"), table: table), .absent)
        XCTAssertEqual(RoutePrefixPresence.ipv6(try IPv6CIDR("2001:db8::/32"), table: "unreadable"), .unknown)
    }
}
