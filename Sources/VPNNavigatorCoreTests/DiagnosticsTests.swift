import XCTest
@testable import VPNNavigatorCore

final class DiagnosticsTests: XCTestCase {
    func testExpectedPath() throws {
        let rules = try RuleSet(text: "223.5.5.0/24\n1.0.1.0/24")
        XCTAssertEqual(IPDiagnostics.decide(ip: "223.5.5.5", mode: .chinaDirect, rules: rules)?.expected, .direct)
        XCTAssertEqual(IPDiagnostics.decide(ip: "8.8.8.8", mode: .chinaDirect, rules: rules)?.expected, .vpn)
        XCTAssertEqual(IPDiagnostics.decide(ip: "8.8.8.8", mode: .original, rules: rules)?.expected, .unchanged)
        XCTAssertNil(IPDiagnostics.decide(ip: "bad-ip", mode: .chinaDirect, rules: rules))
    }
}
