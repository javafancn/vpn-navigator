import XCTest
@testable import VPNNavigatorCore

final class APNICIPv6DelegationsTests: XCTestCase {
    func testParsesOnlyAssignedOrAllocatedMainlandIPv6() throws {
        let fixture = """
        2|apnic|20261015|2|20261015|+0000
        apnic|CN|ipv6|240e::|20|20261015|allocated
        apnic|CN|ipv6|2409:8000::|20|20261015|assigned
        apnic|JP|ipv6|2404::|32|20261015|allocated
        apnic|CN|ipv4|1.0.1.0|256|20261015|allocated
        """
        let rules = try APNICIPv6Delegations.parse(fixture)
        XCTAssertEqual(rules.routes.count, 2)
        XCTAssertTrue(rules.contains("240e:0abc::1"))
        XCTAssertFalse(rules.contains("2404::1"))
    }
    func testRejectsCorruptedCountryRecordAndMissingCN() throws {
        let malformed = """
        apnic|CN|ipv6|not-an-ip|32|20261015|allocated
        apnic|CN|ipv6|240e::|20|20261015|allocated
        """
        XCTAssertThrowsError(try APNICIPv6Delegations.parse(malformed))
        XCTAssertThrowsError(try APNICIPv6Delegations.parse(
            "apnic|JP|ipv6|2404::|32|20261015|allocated"))
    }
    func testRegisteredCountryNotAutomaticallyRouted() throws {
        let source = """
        apnic|CN|ipv6|240e::|20|20261015|allocated
        apnic|CN|ipv6|2409:8000::|20|20261015|allocated
        """
        let preview = try APNICIPv6Delegations.parse(source)
        XCTAssertTrue(preview.contains("240e::1"))
        // No OS route planner / privileged mutation API accepts IPv6RuleSet.
    }
}
