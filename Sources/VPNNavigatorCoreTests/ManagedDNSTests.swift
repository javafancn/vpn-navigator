import XCTest
@testable import VPNNavigatorCore

final class ManagedDNSTests: XCTestCase {
    func testServerResolversAndSupportedFamilyFallback() throws {
        XCTAssertEqual(try ManagedDNSPolicy.servers(provided: ["223.5.5.5", "10.8.0.1", "223.5.5.5"], has4: true, has6: false), ["223.5.5.5", "10.8.0.1"])
        XCTAssertEqual(try ManagedDNSPolicy.servers(provided: [], has4: true, has6: false), ["1.1.1.1", "9.9.9.9"])
        XCTAssertEqual(try ManagedDNSPolicy.servers(provided: [], has4: false, has6: true), ["2606:4700:4700::1111", "2620:fe::fe"])
        XCTAssertThrowsError(try ManagedDNSPolicy.servers(provided: ["223.5.5.5"], has4: false, has6: true))
        for bad in ["127.0.0.1", "0.0.0.0", "169.254.1.1", "224.0.0.1", "::1", "fe80::1", "ff02::1", "dns.example;exit"] {
            XCTAssertThrowsError(try ManagedDNSPolicy.servers(provided: [bad], has4: true, has6: true), bad)
        }
    }
    func testCountryAndExplicitDirectCannotCaptureDNS() throws {
        let rules = try RuleSet(text: "223.5.0.0/16\n11.0.0.0/8")
        let custom = try CustomRuleSet([.init(cidr: "223.5.5.0/24", action: .direct)])
        let path = try PhysicalIPPath(gateway: "192.168.1.1", interface: "en0")
        func plan(_ mode: RoutingMode, dns: [String]) throws -> DualStackRoutePlan {
            try .build(endpoint: "203.0.113.7", tunnel: "utun4", has4: true, has6: false,
                path4: path, path6: nil, local4: [IPv4CIDR("192.168.1.0/24")], local6: [],
                mode: mode, country4: rules, country6: nil, custom: custom, dnsServers: dns)
        }
        let old = try plan(.chinaDirect, dns: [])
        XCTAssertTrue(old.direct4.contains { $0.prefix.contains(IPv4CIDR.parseAddress("223.5.5.5")!) })
        for mode in [RoutingMode.chinaDirect, .fullVPN] {
            let value = try plan(mode, dns: ["223.5.5.5", "10.8.0.1"])
            XCTAssertEqual(value.dns4.count, 2)
            XCTAssertTrue(value.dns4.allSatisfy { $0.destination == .interface("utun4") })
            XCTAssertFalse(value.direct4.contains { $0.prefix.contains(IPv4CIDR.parseAddress("223.5.5.5")!) })
            XCTAssertTrue(value.direct4.contains { $0.prefix.contains(IPv4CIDR.parseAddress("223.5.5.6")!) })
            let explanation = try RouteExplanation.decide(ip: "223.5.5.5", mode: mode, country: rules, custom: custom, protectedDNS: ["223.5.5.5"])
            XCTAssertEqual(explanation.path, .vpn)
            let pf = try LeakGuardPolicy(physical: "en0", endpoint: value.endpoint, port: 1194, transport: .udp,
                local: value.local4, country: [], managedDirect: value.direct4.map(\.prefix))
            XCTAssertFalse(pf.direct.contains { $0.contains(IPv4CIDR.parseAddress("223.5.5.5")!) })
        }
        XCTAssertThrowsError(try plan(.chinaDirect, dns: ["192.168.1.1"]))
        XCTAssertThrowsError(try plan(.chinaDirect, dns: ["203.0.113.7"]))
    }
    func testIPv6DNSIsRemovedFromDirectAllowList() throws {
        let path = try PhysicalIPPath(gateway: "fe80::1%en0", interface: "en0")
        let value = try DualStackRoutePlan.build(endpoint: "2606:4700::1234", tunnel: "utun4", has4: false, has6: true,
            path4: nil, path6: path, local4: [], local6: [], mode: .chinaDirect,
            country4: nil, country6: IPv6RuleSet(text: "240e::/20"), custom: .empty, dnsServers: ["240e::53"])
        XCTAssertFalse(value.direct6.contains { $0.prefix.contains("240e::53") })
        XCTAssertTrue(value.direct6.contains { $0.prefix.contains("240e::54") })
        XCTAssertEqual(value.dns6.map(\.prefix.description), ["240e::53/128"])
    }
}
