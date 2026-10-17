import XCTest
@testable import VPNNavigatorCore

final class LocalRoutesTests: XCTestCase {
    func testFindsOnlyPhysicalOnLinkIPv4Networks() throws {
        let table = """
        Routing tables

        Internet:
        Destination        Gateway           Flags         Netif Expire
        default            192.168.1.1       UGSc            en0
        10.8/16            link#18           UCS             utun4
        192.168.1/24       link#5            UCS              en0
        192.168.1.45       aa:bb:cc          UHLWI            en0
        172.16/12          link#5            UCS              en0
        223.5.5/24         192.168.1.1       UGSc             en0
        """
        let routes = LocalIPv4Networks.parse(netstat: table, physicalInterface: "en0")
        XCTAssertEqual(routes.map(\.description), ["172.16.0.0/12","192.168.1.0/24"])
    }
    func testOverlappingCountryRoutesAreNotInstalled() throws {
        let cn = try RuleSet(text: "223.5.5.0/24\n1.0.1.0/24\n8.8.8.0/24")
        let plan = try RoutePlanner.build(
            serverIPv4: "203.0.113.7", physicalGateway: "192.168.1.1",
            vpnInterface: "utun4",
            localPrefixes: [try IPv4CIDR("223.5.5.0/25")],
            china: cn
        )
        XCTAssertFalse(plan.direct.contains { $0.prefix.description == "223.5.5.0/24" })
        XCTAssertEqual(plan.direct.count, 2)
    }
}
