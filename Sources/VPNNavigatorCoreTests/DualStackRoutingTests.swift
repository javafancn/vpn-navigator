import XCTest
@testable import VPNNavigatorCore

final class DualStackRoutingTests: XCTestCase {
    func testOtherTunnelCannotBeAdoptedAsPhysicalGateway() {
        for gateway in ["192.0.2.1", "fe80::1%utun3"] {
            XCTAssertThrowsError(try PhysicalIPPath(gateway: gateway, interface: "utun3")) { error in
                XCTAssertEqual(error as? RoutePlanningError, .competingTunnel)
            }
        }
        XCTAssertNoThrow(try PhysicalIPPath(gateway: "192.0.2.1", interface: "en0"))
    }
    private func paths() throws -> (PhysicalIPPath, PhysicalIPPath) {
        (try .init(gateway: "192.168.1.1", interface: "en0"), try .init(gateway: "fe80::1%en0", interface: "en0"))
    }
    private func plan(endpoint: String = "8.8.8.8", has4: Bool = true, has6: Bool = true,
                      mode: RoutingMode = .fullVPN, custom: CustomRuleSet = .empty) throws -> DualStackRoutePlan {
        let p = try paths()
        return try .build(endpoint: endpoint, tunnel: "utun4", has4: has4, has6: has6, path4: p.0, path6: p.1,
            local4: [IPv4CIDR("192.168.1.0/24")], local6: [IPv6CIDR("fd12::/64")], mode: mode,
            country4: mode == .chinaDirect ? RuleSet(text: "11.0.0.0/8") : nil,
            country6: mode == .chinaDirect ? IPv6RuleSet(text: "240e::/20") : nil, custom: custom)
    }
    func testAddressCanonicalizationAndScopedGateways() {
        XCTAssertEqual(IPAddress.canonical("2001:4860:0000:0000::8888"), "2001:4860::8888")
        XCTAssertEqual(IPAddress.canonical("009.009.009.009"), "9.9.9.9")
        for value in ["fe80::1%en0", "::1;delete", "host.example", "2001:::1"] { XCTAssertNil(IPAddress.canonical(value)) }
        XCTAssertEqual(IPAddress.gateway6("fe80::1", interface: "en0"), "fe80::1%en0")
        XCTAssertNil(IPAddress.gateway6("fe80::1%en2", interface: "en0"))
        XCTAssertThrowsError(try PhysicalIPPath(gateway: "fe80::1%en1", interface: "en0"))
    }
    func testIPv6CodingAndBinarySubdivision() throws {
        let value = try IPv6CIDR("2606:4700:1:2::1234/48")
        XCTAssertEqual(value.description, "2606:4700:1::/48")
        XCTAssertEqual(try JSONDecoder().decode(IPv6CIDR.self, from: JSONEncoder().encode(value)), value)
        let children = try value.children()
        XCTAssertEqual(children.map(\.description), ["2606:4700:1::/49", "2606:4700:1:8000::/49"])
        XCTAssertFalse(children[0].overlaps(children[1])); XCTAssertTrue(value.overlaps(children[1]))
        XCTAssertTrue(try IPv6CIDR("2606::1/128").children().isEmpty)
    }
    func testCustomIPv6RulesNormalizeAndSeparateAddressFamilies() throws {
        let value = try CustomRuleSet([.init(cidr: "2606:4700::1111", action: .direct), .init(cidr: "fd66::abcd/64", action: .vpn), .init(cidr: "9.9.9.9", action: .direct)])
        XCTAssertEqual(value.rules.map(\.cidr), ["2606:4700::1111/128", "fd66::/64", "9.9.9.9/32"])
        XCTAssertEqual(try value.directPrefixes(country: nil, local: [], endpoint: nil).map(\.description), ["9.9.9.9/32"])
        XCTAssertEqual(try value.directPrefixes6(country: nil, local: [], endpoint: nil).map(\.description), ["2606:4700::1111/128"])
    }
    func testIPv6RuleOverlapAndSpecialPurposeRejection() throws {
        XCTAssertThrowsError(try CustomRuleSet([.init(cidr: "2606:4700::/32", action: .direct), .init(cidr: "2606:4700::1", action: .vpn)]))
        for prefix in ["::/0", "::1", "fe80::/64", "ff00::/8", "::ffff:192.0.2.1", "2001:db8::/32", "2600::/4"] {
            XCTAssertThrowsError(try CustomRuleSet([.init(cidr: prefix, action: .vpn)]), prefix)
        }
        XCTAssertNoThrow(try CustomRuleSet([.init(cidr: "fc00::/7", action: .vpn)]))
    }
    func testIPv6SubtractionRemovesVPNSpaceFromPhysicalAllowList() throws {
        let custom = try CustomRuleSet([.init(cidr: "2606:4700:1::/48", action: .vpn), .init(cidr: "fd66::/64", action: .direct)])
        let prefixes = try custom.directPrefixes6(country: IPv6RuleSet(text: "2606:4700::/32\n2606:4700:1::/48"), local: [], endpoint: nil)
        XCTAssertFalse(prefixes.contains { $0.contains("2606:4700:1::abcd") })
        XCTAssertTrue(prefixes.contains { $0.contains("2606:4700:2::abcd") })
        XCTAssertTrue(prefixes.contains { $0.contains("fd66::1") })
        for (index, item) in prefixes.enumerated() { XCTAssertFalse(prefixes.dropFirst(index + 1).contains { $0.overlaps(item) }) }
    }
    func testIPv6HostCutsAtBothEdges() throws {
        let custom = try CustomRuleSet([.init(cidr: "2606:4700::", action: .vpn), .init(cidr: "2606:4700::3", action: .vpn)])
        let values = try custom.directPrefixes6(country: IPv6RuleSet(text: "2606:4700::/126"), local: [], endpoint: nil)
        XCTAssertEqual(values.map(\.description), ["2606:4700::1/128", "2606:4700::2/128"])
    }
    func testIPv6ProtectsLANAndServerEndpoint() throws {
        let value = try CustomRuleSet([.init(cidr: "fd66::/48", action: .vpn)])
        XCTAssertThrowsError(try value.directPrefixes6(country: nil, local: [IPv6CIDR("fd66:0:0:1::/64")], endpoint: nil))
        XCTAssertThrowsError(try value.directPrefixes6(country: nil, local: [], endpoint: "fd66::1"))
        let country = try IPv6RuleSet(text: "240e::/20")
        XCTAssertTrue(try CustomRuleSet.empty.directPrefixes6(country: country, local: [IPv6CIDR("240e:123::/32")], endpoint: nil).isEmpty)
    }
    func testDualStackPlanRetainsIndependentEndpointAndDefaults() throws {
        let value = try plan()
        XCTAssertEqual(value.stack, .dual); XCTAssertNotNil(value.endpoint4); XCTAssertNil(value.endpoint6)
        XCTAssertEqual(value.defaults4.count, 2); XCTAssertEqual(value.defaults6.map { $0.prefix.description }, ["::/1", "8000::/1"])
        XCTAssertTrue(value.defaults6.allSatisfy { $0.destination == .interface("utun4") })
    }
    func testIPv6TransportAndIPv6OnlyPhysicalNetwork() throws {
        let value = try plan(endpoint: "2606:4700::1111")
        XCTAssertNil(value.endpoint4); XCTAssertEqual(value.endpoint6?.prefix.description, "2606:4700::1111/128")
        let p = try paths()
        let v6only = try DualStackRoutePlan.build(endpoint: "2606:4700::1111", tunnel: "utun4", has4: true, has6: true,
            path4: nil, path6: p.1, local4: [], local6: [], mode: .fullVPN, country4: nil, country6: nil, custom: .empty)
        XCTAssertEqual(v6only.stack, .dual); XCTAssertEqual(v6only.ipv4.count, 2)
    }
    func testMissingFamilyRefusesItsCustomRules() throws {
        let v6 = try CustomRuleSet([.init(cidr: "fd66::/64", action: .vpn)])
        XCTAssertThrowsError(try plan(has6: false, custom: v6))
        XCTAssertEqual(try plan(has6: false).stack, .ipv4)
        XCTAssertEqual(try plan(has4: false).stack, .ipv6)
        XCTAssertThrowsError(try plan(has4: false, has6: false))
    }
    func testCountryModeUsesBothFeedsAndCustomExceptions() throws {
        let custom = try CustomRuleSet([.init(cidr: "240e:1::/32", action: .vpn), .init(cidr: "2606:4700::1111", action: .direct)])
        let value = try plan(mode: .chinaDirect, custom: custom)
        XCTAssertFalse(value.direct6.contains { $0.prefix.contains("240e:1::1") })
        XCTAssertTrue(value.direct6.contains { $0.prefix.contains("240e:2::1") })
        XCTAssertTrue(value.direct6.contains { $0.prefix.contains("2606:4700::1111") })
        let p = try paths()
        XCTAssertThrowsError(try DualStackRoutePlan.build(endpoint: "8.8.8.8", tunnel: "utun4", has4: true, has6: true,
            path4: p.0, path6: p.1, local4: [], local6: [], mode: .chinaDirect,
            country4: RuleSet(text: "11.0.0.0/8"), country6: nil, custom: .empty))
    }
    func testUnsafeEndpointsAndInterfacesAreRejected() throws {
        for endpoint in ["127.0.0.1", "::1", "ff02::1", "fe80::1", "::ffff:127.0.0.1", "0.0.0.0"] { XCTAssertThrowsError(try plan(endpoint: endpoint), endpoint) }
        let p = try paths()
        XCTAssertThrowsError(try DualStackRoutePlan.build(endpoint: "8.8.8.8", tunnel: "utun4;delete", has4: true, has6: true,
            path4: p.0, path6: p.1, local4: [], local6: [], mode: .fullVPN, country4: nil, country6: nil, custom: .empty))
    }
    func testManagementStateCarriesIPv6PayloadAndIPv6Transport() throws {
        let dual = try XCTUnwrap(ManagementParser.parseState(">STATE:1,CONNECTED,SUCCESS,10.8.0.2,2606:4700::1111,1194,2606:4700::2,40000,fd66::2"))
        XCTAssertNil(dual.remoteIPv4); XCTAssertEqual(dual.remoteIPv6, "2606:4700::1111")
        XCTAssertEqual(dual.localTunnelIPv4, "10.8.0.2"); XCTAssertEqual(dual.localTunnelIPv6, "fd66::2")
        let v6only = try XCTUnwrap(ManagementParser.parseState("1,CONNECTED,SUCCESS,,2606:4700::1111,1194,,,fd66::2"))
        XCTAssertNil(v6only.localTunnelIPv4); XCTAssertEqual(v6only.localTunnelIPv6, "fd66::2")
        XCTAssertNil(ManagementParser.parseState("1,CONNECTED,SUCCESS,10.8.0.2,8.8.8.8,,,,not-ip")?.localTunnelIPv6)
    }
    func testRuleBundleIsBackwardCompatibleAndBounded() throws {
        XCTAssertEqual(try RoutingRuleBundle.decoded("11.0.0.0/8").ipv4, "11.0.0.0/8")
        let value = RoutingRuleBundle(ipv4: "11.0.0.0/8", ipv6: "240e::/20")
        XCTAssertEqual(try RoutingRuleBundle.decoded(value.json).ipv6, "240e::/20")
        XCTAssertThrowsError(try RoutingRuleBundle.decoded(RoutingRuleBundle(ipv4: String(repeating: "x", count: 2_000_001)).json))
        XCTAssertEqual(try SessionPreferences.decoded(SessionPreferences(requireDualStack: true).json).requireDualStack, true)
    }
    func testIPv6ObservationRequiresExactMaskDestinationAndScope() throws {
        let target = IPv6RouteTarget(try IPv6CIDR("2606:4700::/32"), .viaGateway("fe80::1%en0"))
        let raw = "destination: 2606:4700::\nmask: ffff:ffff::\ngateway: fe80::1%en0\ninterface: en0"
        XCTAssertTrue(ObservedIPv6Route(commandOutput: raw).isExactly(target))
        XCTAssertFalse(ObservedIPv6Route(commandOutput: raw.replacingOccurrences(of: "ffff:ffff::", with: "ffff::")).isExactly(target))
        XCTAssertFalse(ObservedIPv6Route(commandOutput: raw.replacingOccurrences(of: "%en0", with: "%en1")).isExactly(target))
        XCTAssertFalse(ObservedIPv6Route(commandOutput: "gateway: fe80::1%en0\ninterface: en0").isExactly(target))
        XCTAssertEqual(target.arguments(adding: true), ["-n", "add", "-inet6", "-net", "2606:4700::/32", "fe80::1%en0"])
    }
    func testLocalIPv6NetworksDoNotClaimGatewayRoutes() {
        let raw = "Internet6:\nDestination Gateway Flags Netif Expire\nfd12::/64 link#4 UC en0\n240e:1::/64 link#4 UC en0\nfe80::%en0/64 link#4 UC en0\n2606:4700::/32 fe80::1%en0 UG en0\nfd66::/64 link#5 UC utun4"
        XCTAssertEqual(LocalIPv6Networks.parse(netstat: raw, physicalInterface: "en0").map(\.description), ["240e:1::/64", "fd12::/64"])
    }
    func testDualPFMatchesEffectiveRoutesAndOnlyEnablesAllocatedFamilies() throws {
        let value = try plan(mode: .chinaDirect, custom: CustomRuleSet([.init(cidr: "240e:1::/32", action: .vpn)]))
        let policy = try LeakGuardPolicy(physical: "en0", endpoint: "8.8.8.8", port: 443, transport: .tcp,
            local: value.local4, country: [], managedDirect: value.direct4.map(\.prefix), physical4: "en0", physical6: "en0",
            local6: value.local6, managedDirect6: value.direct6.map(\.prefix), ipv6Tunnel: true)
        XCTAssertFalse(policy.direct6.contains { $0.contains("240e:1::1") })
        let raw = try policy.rules(tunnel: "utun4")
        XCTAssertTrue(raw.contains("on utun4 inet6 from any")); XCTAssertTrue(raw.contains("icmp6-type { routersol, neighbrsol, neighbradv }"))
        XCTAssertFalse(raw.contains("on en0 inet6 from any to any")); XCTAssertTrue(raw.contains("block drop out quick inet6"))
        let ipv6 = try LeakGuardPolicy(physical: "en0", endpoint: "2606:4700::1111", port: 1194, transport: .udp,
            local: [], country: [], physical6: "en0", ipv4Tunnel: false, ipv6Tunnel: true)
        XCTAssertTrue(try ipv6.rules(tunnel: "utun4").contains("on en0 inet6 proto udp from any to 2606:4700::1111 port 1194"))
        XCTAssertFalse(try ipv6.rules(tunnel: "utun4").contains("on utun4 inet from any"))
    }
    func testMixedJournalReplaysAndPendingIPv6BlocksAllRecovery() throws {
        let v4 = RouteMutation(action: .add, route: try plan().defaults4[0])
        let v6 = IPv6RouteMutation(action: .add, route: try plan().defaults6[0])
        var bytes = Data()
        func add<T: Encodable>(_ value: T) throws { bytes.append(try JSONEncoder().encode(value)); bytes.append(10) }
        try add(RouteLedgerEvent(phase: .begun, mutation: v4)); try add(RouteLedgerEvent(phase: .committed, mutation: v4))
        try add(IPv6RouteLedgerEvent(phase: .begun, ipv6Mutation: v6))
        XCTAssertFalse(RouteLedgerReplay(data: bytes).permitsAutomaticRecovery)
        try add(IPv6RouteLedgerEvent(phase: .committed, ipv6Mutation: v6))
        let result = RouteLedgerReplay(data: bytes)
        XCTAssertTrue(result.permitsAutomaticRecovery); XCTAssertEqual(result.installed, [v4.route]); XCTAssertEqual(result.installed6, [v6.route])
    }
    func testIPv6ExplanationAndFencedLookupUseCanonicalAddress() throws {
        let custom = try CustomRuleSet([.init(cidr: "2606:4700::1111", action: .direct)])
        XCTAssertEqual(try RouteExplanation.decide(ip: "2606:4700::1111", mode: .fullVPN, country: nil, custom: custom).path, .direct)
        XCTAssertEqual(try RouteExplanation.decide(ip: "2606:4700::1111", mode: .fullVPN, country: nil, custom: .empty, available: false).path, .blocked)
        XCTAssertEqual(try RouteExplanation.decide(ip: "240e:1::1", mode: .chinaDirect, country: nil, custom: .empty, country6: IPv6RuleSet(text: "240e::/20")).path, .direct)
        let report = SessionReport(state: .connected, message: "", activeProfileID: UUID(), receivedBytes: nil, sentBytes: nil, attemptID: UUID(), routingMode: .fullVPN, routingRevision: UUID(), ipStack: .dual)
        let request = try RouteLookupRequest(report: report, ip: "2606:4700:0:0::1111")
        XCTAssertEqual(request.ip, "2606:4700::1111"); XCTAssertEqual(try RouteLookupRequest.decoded(request.json), request)
    }
    func testOriginalProfilesAcceptIPv6ButManagedRoutesHaveOneOwner() throws {
        let source = "client\ndev tun\nproto udp6\nremote 2606:4700::1111 1194\nredirect-gateway def1 ipv6\nroute-ipv6 fd66::/64 fd66::1\n<ca>\nFAKE\n</ca>"
        let value = try ProfileSafety.validate(source)
        XCTAssertNoThrow(try ManagedRoutingPolicy.validate(value, mode: .original))
        XCTAssertThrowsError(try ManagedRoutingPolicy.validate(value, mode: .fullVPN))
        let pinned = try GuardEndpoint.parse(source).pinnedProfile(source, address: "2606:4700::2222")
        XCTAssertTrue(pinned.contains("proto udp6")); XCTAssertTrue(pinned.contains("remote 2606:4700::2222 1194"))
    }
}
