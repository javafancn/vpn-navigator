import XCTest
@testable import VPNNavigatorCore

final class RuleEngineTests: XCTestCase {
    func testCIDRNormalization() throws {
        let route = try IPv4CIDR("223.5.5.7/24")
        XCTAssertEqual(route.description, "223.5.5.0/24")
        XCTAssertEqual(route.netmask, "255.255.255.0")
    }
    func testCountryLookup() throws {
        let rules = try RuleSet(text: "# test\n223.5.5.0/24\n1.0.1.0/24")
        XCTAssertTrue(rules.contains(ip: "223.5.5.5"))
        XCTAssertFalse(rules.contains(ip: "8.8.8.8"))
    }
    func testRejectBadFeed() throws {
        XCTAssertThrowsError(try RuleSet(text: "0.0.0.0/0"))
        XCTAssertThrowsError(try RuleSet(text: "192.168.1.0/24"))
        XCTAssertThrowsError(try RuleSet(text: "10.0.0.0/8"))
    }
    func testDiff() throws {
        let a = try RuleSet(text: "1.0.1.0/24")
        let b = try RuleSet(text: "223.5.5.0/24")
        XCTAssertEqual(b.diff(from: a).added.count, 1)
        XCTAssertEqual(b.diff(from: a).removed.count, 1)
    }
    func testRejectSuddenRuleShrink() throws {
        let old = try RuleSet(text: (1...120).map { "11.\($0).0.0/16" }.joined(separator: "\n"))
        let next = try RuleSet(text: (1...70).map { "11.\($0).0.0/16" }.joined(separator: "\n"))
        XCTAssertThrowsError(try RuleUpdater.validateChange(previous: old, next: next))
    }
    func testCompiler() throws {
        let rules = try RuleSet(text: "223.5.5.0/24")
        let result = try ProfileCompiler.render(original: "client\nremote vpn.example 1194",
                                                mode: .chinaDirect, rules: rules)
        XCTAssertTrue(result.contains("route 223.5.5.0 255.255.255.0 net_gateway"))
        XCTAssertTrue(result.contains("redirect-gateway def1"))
        XCTAssertThrowsError(try ProfileCompiler.render(original: result, mode: .fullVPN, rules: rules))
    }
}
