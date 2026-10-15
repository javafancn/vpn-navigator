import XCTest
@testable import VPNNavigatorCore

final class FirewallRulePreviewTests: XCTestCase {
    private func preview(_ mode: FirewallRulePreview.Policy) throws -> FirewallRulePreview {
        try FirewallRulePreview(
            physicalInterface: "en0", tunnelInterface: "utun4",
            endpointIPv4: "8.8.8.8", endpointPort: 1194, transport: .udp,
            policy: mode, localNetworks: [try IPv4CIDR("192.168.1.0/24")])
    }

    func testExceptionsComeBeforePhysicalBlock() throws {
        let rendered = try preview(.fullVPN).renderedRules()
        let endpoint = try XCTUnwrap(rendered.range(of: "pass out quick on en0 inet proto udp"))
        let physicalBlock = try XCTUnwrap(rendered.range(of: "block drop out quick on en0 inet from any"))
        XCTAssertTrue(endpoint.lowerBound < physicalBlock.lowerBound)
        XCTAssertTrue(rendered.contains("block drop out quick on en0 inet6"))
        XCTAssertTrue(rendered.contains("192.168.1.0/24"))
        XCTAssertFalse(rendered.contains("pass out quick on en0 inet to any"))
    }

    func testCountryDirectTableAddsExceptions() throws {
        let rendered = try preview(.chinaDirect([
            try IPv4CIDR("223.5.5.0/24"), try IPv4CIDR("223.5.5.0/24")
        ])).renderedRules()
        XCTAssertTrue(rendered.contains("223.5.5.0/24"))
        XCTAssertEqual(rendered.components(separatedBy: "223.5.5.0/24").count, 2)
    }

    func testUntrustedInterfaceInputCannotInjectPF() {
        XCTAssertThrowsError(try FirewallRulePreview(
            physicalInterface: "en0; block all", tunnelInterface: "utun4",
            endpointIPv4: "8.8.8.8", endpointPort: 443, transport: .tcp,
            policy: .fullVPN, localNetworks: [try IPv4CIDR("192.168.1.0/24")]))
        XCTAssertThrowsError(try FirewallRulePreview(
            physicalInterface: "en0", tunnelInterface: "utun4",
            endpointIPv4: "8.8.8.8", endpointPort: 443, transport: .tcp,
            policy: .fullVPN, localNetworks: []))
    }
}
