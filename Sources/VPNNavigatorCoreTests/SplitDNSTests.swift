import XCTest
@testable import VPNNavigatorCore

final class SplitDNSTests: XCTestCase {
    func testDomainBoundariesAndCase() throws {
        let rules = try ChinaDNSDomains(text: "baidu.com\nbilibili.com\nexample.cn\nxn--fiqs8s.cn\n")
        for name in ["baidu.com", "WWW.BaiDu.Com.", "a.b.bilibili.com", "example.cn", "www.xn--fiqs8s.cn"] { XCTAssertTrue(rules.contains(name), name) }
        for name in ["notbaidu.com", "baidu.com.evil.test", "www.unknown.cn", "google.com", "bad..baidu.com", "www.baidu.com.."] { XCTAssertFalse(rules.contains(name), name) }
        for invalid in ["", "a..cn", "BAD.cn", "*.cn", "-bad.cn", "bad-.cn", "a/cn", String(repeating: "a", count: 64)+".cn"] {
            XCTAssertThrowsError(try ChinaDNSDomains(text: invalid))
        }
    }
    private func query(_ domain: String = "www.baidu.com", type: UInt16 = 1) -> Data {
        var data = Data([0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0])
        for label in domain.split(separator: ".") { data.append(UInt8(label.utf8.count)); data.append(contentsOf: label.utf8) }
        data.append(contentsOf: [0, UInt8(type >> 8), UInt8(type & 255), 0, 1]); return data
    }
    func testDNSQuestionAndIdentityValidation() throws {
        for type: UInt16 in [1, 28, 65, 16] {
            let packet = query(type: type), question = try XCTUnwrap(DNSQuestion(packet))
            XCTAssertEqual(question.name, "www.baidu.com"); XCTAssertEqual(question.type, type)
            let failure = question.failure(for: packet)
            XCTAssertTrue(question.accepts(failure, request: packet)); XCTAssertEqual(failure[3] & 15, 2)
            var forged = failure; forged[0] ^= 1
            XCTAssertFalse(question.accepts(forged, request: packet))
            var changed = query("www.other.com", type: type); changed[2] = 0x81
            XCTAssertFalse(question.accepts(changed, request: packet))
        }
        let data = query()
        for length in 0..<data.count { XCTAssertNil(DNSQuestion(data.prefix(length))) }
        for (offset, value): (Int, UInt8) in [(2,0x81), (2,0x09), (5,2), (12,0xc0), (data.count-1,2)] {
            var bad = data; bad[offset] = value; XCTAssertNil(DNSQuestion(bad))
        }
    }
    func testPhysicalDNSExceptionsNeverOverlapVPNOrFullMode() throws {
        XCTAssertEqual(SplitDNSPolicy.domesticServers(path4: true, path6: true, protectedVPN: ["223.5.5.5"]), ["223.6.6.6"])
        XCTAssertTrue(SplitDNSPolicy.domesticServers(path4: false, path6: false, protectedVPN: []).isEmpty)
        XCTAssertEqual(SplitDNSPolicy.domesticServers(path4: false, path6: true, protectedVPN: []).count, 2)
        let path = try PhysicalIPPath(gateway: "192.168.1.1", interface: "en0")
        let custom = try CustomRuleSet([.init(cidr: "223.5.0.0/16", action: .vpn)])
        func plan(_ mode: RoutingMode, direct: [String]) throws -> DualStackRoutePlan {
            try .build(endpoint: "203.0.113.1", tunnel: "utun4", has4: true, has6: false, path4: path, path6: nil,
                local4: [], local6: [], mode: mode, country4: RuleSet(text: "223.5.0.0/16"), country6: nil,
                custom: custom, dnsServers: ["1.1.1.1"], directDNSServers: direct)
        }
        let rules = try plan(.chinaDirect, direct: ["223.5.5.5"])
        XCTAssertEqual(rules.direct4.map(\.prefix.description), ["223.5.5.5/32"])
        XCTAssertFalse(rules.direct4.contains { $0.prefix.contains(IPv4CIDR.parseAddress("223.5.5.6")!) })
        let explanation = try RouteExplanation.decide(ip: "223.5.5.5", mode: .chinaDirect, country: nil, custom: custom, directDNS: rules.physicalDNS)
        XCTAssertEqual(explanation.path, .direct)
        XCTAssertThrowsError(try plan(.fullVPN, direct: ["223.5.5.5"]))
        XCTAssertThrowsError(try plan(.chinaDirect, direct: ["1.1.1.1"]))
        XCTAssertTrue(try plan(.fullVPN, direct: []).direct4.isEmpty)
    }
}
