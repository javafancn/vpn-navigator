import XCTest
@testable import VPNNavigatorCore

final class RouteObservationTests: XCTestCase {
    func testOwnedGatewayRoute() throws {
        let route = RouteTarget(try IPv4CIDR("223.5.5.0/24"), .viaGateway("192.168.1.1"))
        let output = """
             route to: 223.5.5.0
          destination: 223.5.5.0
                 mask: 255.255.255.0
              gateway: 192.168.1.1
            interface: en0
        """
        XCTAssertTrue(ObservedIPv4Route(commandOutput: output).isExactly(route))
        XCTAssertFalse(ObservedIPv4Route(commandOutput: output)
            .isExactly(RouteTarget(try IPv4CIDR("223.5.5.0/24"), .viaGateway("192.168.3.1"))))
    }
    func testFallbackDefaultMustNotPass() throws {
        let requested = RouteTarget(try IPv4CIDR("223.5.5.0/24"), .viaGateway("192.168.1.1"))
        let fallback = "route to: 223.5.5.0\nmask: 0.0.0.0\ngateway: 192.168.1.1\ninterface: en0"
        XCTAssertFalse(ObservedIPv4Route(commandOutput: fallback).isExactly(requested))
        XCTAssertFalse(ObservedIPv4Route(commandOutput: "gateway: 192.168.1.1\ninterface: en0")
            .isExactly(requested))
    }
    func testHexNetmask() throws {
        let route = RouteTarget(try IPv4CIDR("1.2.3.0/24"), .interface("utun4"))
        let output = "destination: 1.2.3.0\nmask: 0xffffff00\ngateway: link#5\ninterface: utun4"
        XCTAssertTrue(ObservedIPv4Route(commandOutput: output).isExactly(route))
    }
}
