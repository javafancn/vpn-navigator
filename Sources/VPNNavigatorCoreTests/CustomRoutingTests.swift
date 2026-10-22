import XCTest
@testable import VPNNavigatorCore

final class CustomRoutingTests: XCTestCase {
    private func rule(_ cidr: String, _ action: CustomRouteAction = .vpn, enabled: Bool = true) -> CustomRouteRule {
        .init(cidr: cidr, action: action, enabled: enabled)
    }
    func testNormalizesHostsAndHostBits() throws {
        let set = try CustomRuleSet([rule(" 9.9.9.9 ", .direct), rule("10.66.4.99/16")])
        XCTAssertEqual(set.rules.map(\.cidr), ["9.9.9.9/32", "10.66.0.0/16"])
    }
    func testRejectsUnsafeAndMalformedPrefixes() {
        for text in ["", "vpn.example", "::1", "1.2.3.4/0", "11.0.0.0/7", "127.0.0.1", "0.0.0.0/8", "169.254.1.1",
                     "100.64.0.0/10", "224.1.1.1", "255.255.255.255", "198.51.100.0/24", "203.0.113.0/24", "9.9.9.9\nadd x"] {
            XCTAssertThrowsError(try CustomRuleSet([rule(text)]), text)
        }
    }
    func testRejectsOverlapsIncludingSameActionAndDuplicateIDs() {
        XCTAssertThrowsError(try CustomRuleSet([rule("11.0.0.0/8"), rule("11.2.0.0/16")]))
        XCTAssertThrowsError(try CustomRuleSet([rule("11.2.0.0/16"), rule("11.2.0.1/32", .direct)]))
        let duplicate = rule("9.9.9.9", .direct, enabled: false)
        XCTAssertThrowsError(try CustomRuleSet([duplicate, duplicate]))
    }
    func testDisabledRulesDoNotConflictOrChangeAppliedDigest() throws {
        let enabled = rule("11.0.0.0/8")
        var disabled = rule("11.2.0.0/16", .direct, enabled: false)
        let first = try CustomRuleSet([enabled, disabled])
        disabled.cidr = "12.0.0.0/8"
        XCTAssertEqual(first.digest, try CustomRuleSet([enabled, disabled]).digest)
        disabled.enabled = true
        XCTAssertNotEqual(first.digest, try CustomRuleSet([enabled, disabled]).digest)
    }
    func testCountAndPreferencesAreBoundedAndLegacySafe() throws {
        XCTAssertThrowsError(try CustomRuleSet((0..<129).map { rule("11.0.\($0).0/24") }))
        let preferences = SessionPreferences(customRules: [rule("10.66.0.0/16"), rule("9.9.9.9", .direct)])
        XCTAssertEqual(try SessionPreferences.decoded(preferences.json), preferences)
        let old = #"{"connectionTimeout":60,"reconnectOriginal":true,"killSwitch":false,"reconnectManaged":false}"#
        XCTAssertNil(try SessionPreferences.decoded(old).customRules)
        XCTAssertThrowsError(try SessionPreferences.decoded(SessionPreferences(customRules: [rule("127.0.0.1")]).json))
        XCTAssertThrowsError(try SessionPreferences.decoded(String(repeating: " ", count: 64_001)))
    }
    func testEnvironmentPreservesEndpointAndOnLinkNetworks() throws {
        let set = try CustomRuleSet([rule("10.66.0.0/16"), rule("9.9.9.9", .direct)])
        XCTAssertThrowsError(try set.validateEnvironment(endpoint: "9.9.9.9", local: []))
        XCTAssertThrowsError(try set.validateEnvironment(endpoint: "8.8.8.8", local: [IPv4CIDR("10.66.8.0/24")]))
        XCTAssertNoThrow(try set.validateEnvironment(endpoint: "8.8.8.8", local: [IPv4CIDR("192.168.1.0/24")]))
        let disabled = try CustomRuleSet([rule("9.9.9.9", enabled: false)])
        XCTAssertNoThrow(try disabled.validateEnvironment(endpoint: "9.9.9.9", local: []))
    }
    func testVPNExceptionsAreRemovedFromPhysicalPrefixes() throws {
        let country = try RuleSet(text: "11.0.0.0/8\n11.2.0.0/16")
        let set = try CustomRuleSet([rule("11.1.0.0/16"), rule("9.9.9.0/24", .direct), rule("10.66.0.0/16", .direct)])
        let result = try set.directPrefixes(country: country, local: [], endpoint: "8.8.8.8")
        func direct(_ ip: String) -> Bool { result.contains { $0.contains(IPv4CIDR.parseAddress(ip)!) } }
        XCTAssertFalse(direct("11.1.0.1")); XCTAssertTrue(direct("11.2.0.1"))
        XCTAssertTrue(direct("9.9.9.9")); XCTAssertTrue(direct("10.66.1.1")); XCTAssertFalse(direct("12.1.1.1"))
        for (i, prefix) in result.enumerated() { XCTAssertFalse(result.dropFirst(i + 1).contains { $0.overlaps(prefix) }) }
    }
    func testEveryAddressInASmallCountryPrefixMatchesBooleanPolicy() throws {
        let country = try RuleSet(text: "11.0.0.0/20\n11.0.2.0/24")
        let set = try CustomRuleSet([rule("11.0.1.0/24"), rule("11.0.4.128/25"), rule("12.0.0.0/24", .direct)])
        let prefixes = try set.directPrefixes(country: country, local: [], endpoint: nil)
        let start = IPv4CIDR.parseAddress("11.0.0.0")!
        for offset in UInt32(0)..<4096 {
            let address = start + offset
            let excluded = try set.active.filter { $0.action == .vpn }.contains { try CustomRuleSet.prefix($0.cidr).contains(address) }
            XCTAssertEqual(prefixes.contains { $0.contains(address) }, !excluded)
        }
    }
    func testHostExceptionsCoverBothEndsWithoutOverflow() throws {
        let country = try RuleSet(text: "223.255.255.0/24")
        let set = try CustomRuleSet([rule("223.255.255.0"), rule("223.255.255.255")])
        let prefixes = try set.directPrefixes(country: country, local: [], endpoint: nil)
        XCTAssertFalse(prefixes.contains { $0.contains(IPv4CIDR.parseAddress("223.255.255.0")!) })
        XCTAssertFalse(prefixes.contains { $0.contains(IPv4CIDR.parseAddress("223.255.255.255")!) })
        XCTAssertTrue(prefixes.contains { $0.contains(IPv4CIDR.parseAddress("223.255.255.254")!) })
    }
    func testLocalCountryExclusionAndCustomDirectReintroduction() throws {
        let country = try RuleSet(text: "11.0.0.0/8")
        let local = [try IPv4CIDR("11.1.0.0/16")]
        let set = try CustomRuleSet([rule("11.2.0.0/24", .direct)])
        let prefixes = try set.directPrefixes(country: country, local: local, endpoint: nil)
        XCTAssertEqual(prefixes, [try IPv4CIDR("11.2.0.0/24")])
    }
    func testModeRoundTripAndFeedRefreshRetainCustomPolicy() throws {
        let countryText = (0..<100).map { "11.0.\($0).0/24" }.joined(separator: "\n")
        let custom = try CustomRuleSet([rule("11.0.4.0/24"), rule("9.9.9.9", .direct)])
        let local = [try IPv4CIDR("192.168.1.0/24")]
        let full = try RoutePlanner.build(serverIPv4: "8.8.8.8", physicalGateway: "192.168.1.1", vpnInterface: "utun4", localPrefixes: local, china: nil, custom: custom)
        let split = try ManagedRouteTransition(current: full, target: .chinaDirect, ruleText: countryText, local: local, custom: custom)
        let round = try ManagedRouteTransition(current: split.plan, target: .fullVPN, ruleText: "", local: local, custom: custom)
        XCTAssertEqual(round.plan.installOrder, full.installOrder)
        XCTAssertFalse(split.plan.direct.contains { $0.prefix.contains(IPv4CIDR.parseAddress("11.0.4.8")!) })
        XCTAssertTrue(split.plan.direct.contains { $0.prefix.contains(IPv4CIDR.parseAddress("9.9.9.9")!) })
        XCTAssertEqual(split.plan.endpoint, full.endpoint); XCTAssertEqual(split.plan.vpnDefaults, full.vpnDefaults)
    }
    func testPFAllowListUsesSameEffectivePrefixesIncludingPrivateExceptions() throws {
        let country = try RuleSet(text: "11.0.0.0/8")
        let custom = try CustomRuleSet([rule("11.1.0.0/16"), rule("10.66.0.0/16", .direct)])
        let local = [try IPv4CIDR("192.168.1.0/24")]
        let direct = try custom.directPrefixes(country: country, local: local, endpoint: "8.8.8.8")
        let policy = try LeakGuardPolicy(physical: "en0", endpoint: "8.8.8.8", port: 1194, transport: .udp, local: local, country: [], managedDirect: direct)
        XCTAssertFalse(policy.direct.contains { $0.contains(IPv4CIDR.parseAddress("11.1.1.1")!) })
        XCTAssertTrue(policy.direct.contains { $0.contains(IPv4CIDR.parseAddress("10.66.1.1")!) })
        XCTAssertThrowsError(try LeakGuardPolicy(physical: "en0", endpoint: "8.8.8.8", port: 1194, transport: .udp, local: local, country: [IPv4CIDR("10.0.0.0/8")]))
        XCTAssertThrowsError(try LeakGuardPolicy(physical: "en0", endpoint: "8.8.8.8", port: 1194, transport: .udp, local: local, country: [], managedDirect: [IPv4CIDR("127.0.0.0/8")]))
    }
    func testStaticPreviewUsesCustomRoutesButPortableExportDoesNotEmbedPolicy() throws {
        let config = "client\nremote fixture.example 1194\n<ca>\nFAKE\n</ca>\n"
        let custom = try CustomRuleSet([rule("9.9.9.9", .direct)])
        let preview = try ProfileExport.render(runtime: config, kind: .routePreview, mode: .fullVPN, rules: nil, custom: custom)
        XCTAssertTrue(String(decoding: preview, as: UTF8.self).contains("route 9.9.9.9 255.255.255.255 net_gateway"))
        let portable = try ProfileExport.render(runtime: config, kind: .portable, mode: .fullVPN, rules: nil, custom: custom)
        XCTAssertFalse(String(decoding: portable, as: UTF8.self).contains("9.9.9.9"))
    }
    func testLegacyProfilesDecodeAndCustomRulesSurviveIndexRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("fixture.ovpn")
        try "client\nremote fixture.example 1194\n<ca>\nFAKE\n</ca>".write(to: source, atomically: true, encoding: .utf8)
        let folder = root.appendingPathComponent("profiles"), store = ProfileStore(root: root.appendingPathComponent("profiles"))
        var profile = try await store.importProfile(from: source)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any]); legacy.removeValue(forKey: "customRules")
        XCTAssertTrue(try JSONDecoder().decode(VPNProfile.self, from: JSONSerialization.data(withJSONObject: legacy)).customRules.isEmpty)
        profile.customRules = try CustomRuleSet([rule("9.9.9.9", .direct)]).rules
        try await store.update(profile)
        try Data("broken".utf8).write(to: folder.appendingPathComponent("profiles.json"))
        let preview = try await store.indexRecoveryPreview(); try await store.recoverIndex(preview)
        let restored = try await store.list(); XCTAssertEqual(restored, [profile])
    }
}
