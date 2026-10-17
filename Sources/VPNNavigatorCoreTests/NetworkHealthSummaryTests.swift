import XCTest
@testable import VPNNavigatorCore

final class NetworkHealthSummaryTests: XCTestCase {
    func testReportsOnlyCountsNotSensitiveDnsDomains() {
        let summary = NetworkHealthSummary(
            ipv6Table: "Internet6:\nDestination Gateway Flags Netif\ndefault fe80::1 UGSc en0",
            defaultIPv4Route: "   route to: default\n  interface: en0",
            dnsSummary: """
            resolver #1
              domain : internal.customer.example
              nameserver[0] : 10.0.0.1
            resolver #2
              nameserver[0] : 8.8.8.8
            """
        )
        XCTAssertEqual(summary.ipv6Safety, .physicalBypass)
        XCTAssertEqual(summary.ipv4DefaultInterface, "en0")
        XCTAssertEqual(summary.resolverCount, 2)
        XCTAssertEqual(summary.nameserverCount, 2)
    }
}
