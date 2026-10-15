import XCTest
@testable import VPNNavigatorCore

final class IPv6CIDRTests: XCTestCase {
    func testCanonicalizationAndMembership() throws {
        let cidr = try IPv6CIDR("240e:abcd:1234::1/32")
        XCTAssertEqual(cidr.description, "240e:abcd::/32")
        XCTAssertTrue(cidr.contains("240e:ffff::1"))
        XCTAssertFalse(cidr.contains("240f::1"))
        XCTAssertEqual(cidr, try IPv6CIDR("240e:abcd::/32"))
    }
    func testOverlapAndBoundaryMasks() throws {
        XCTAssertTrue((try IPv6CIDR("240e::/20")).overlaps(try IPv6CIDR("240e:1000::/32")))
        XCTAssertFalse((try IPv6CIDR("240e::/20")).overlaps(try IPv6CIDR("240f::/20")))
        XCTAssertTrue((try IPv6CIDR("::/0")).contains("2606:4700::1111"))
        XCTAssertFalse((try IPv6CIDR("::1/128")).contains("::2"))
    }
    func testInvalidAndUnsafeInput() throws {
        for candidate in ["zzzz::/24", "2001:db8::/129", "fe80::1%en0/64", "2001:db8::", ""] {
            XCTAssertThrowsError(try IPv6CIDR(candidate))
        }
        for special in ["fc00::/7", "fe80::/10", "ff00::/8",
                        "2001:db8::/32", "2000::/3"] {
            XCTAssertThrowsError(try IPv6RuleSet(text: special))
        }
    }
    func testIPv6CountryRuleSetIsDataOnly() throws {
        let rules = try IPv6RuleSet(text: "# sample\n240e::/20\n2409:8000::/20")
        XCTAssertTrue(rules.contains("240e:1234::5"))
        XCTAssertFalse(rules.contains("2606:4700::1111"))
        XCTAssertEqual(rules.routes.count, 2)
        XCTAssertThrowsError(try IPv6RuleSet(text: ""))
    }
}
