import XCTest
@testable import VPNNavigatorCore

final class ConfigurationCompatibilityTests: XCTestCase {
    func testQuotedCertificateAndTlsAuthDirection() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "CA".write(to: folder.appendingPathComponent("my ca.pem"), atomically: true, encoding: .utf8)
        try "TLS KEY".write(to: folder.appendingPathComponent("ta.key"), atomically: true, encoding: .utf8)
        let source = "client\ndev tun\nremote vpn.example 1194 udp # endpoint\nca \"my ca.pem\"\ntls-auth ta.key 1"
        let runtime = try ProfileMaterializer.materialize(text: source, directory: folder)
        XCTAssertTrue(runtime.contains("<ca>\nCA\n</ca>"))
        XCTAssertTrue(runtime.contains("key-direction 1"))
        XCTAssertNoThrow(try ProfileSafety.validate(runtime))
    }
    func testQuotedRoutingDirectiveCannotBypassManagedPolicy() throws {
        let source = "client\ndev tun\nremote vpn.example 1194\n<ca>\nCA\n</ca>\n\"route\" 10.0.0.0 255.0.0.0 vpn_gateway"
        let profile = try ProfileSafety.validate(source)
        XCTAssertThrowsError(try ManagedRoutingPolicy.validate(profile, mode: .chinaDirect))
        XCTAssertThrowsError(try ManagedRoutingPolicy.validate(profile, mode: .fullVPN))
    }
    func testMalformedQuotesAndTapAreRejected() {
        XCTAssertThrowsError(try OpenVPNOptionLexer.tokens("remote \"unterminated"))
        XCTAssertThrowsError(try OpenVPNOptionLexer.tokens("key a\\"))
        XCTAssertThrowsError(try ProfileSafety.validate("client\ndev tun\ndev-type tap\nremote vpn.example\n<ca>\nCA\n</ca>"))
    }
    func testDNSRestorationNeverOverwritesAnotherOwner() {
        XCTAssertEqual(DNSRecoveryPolicy.decide(currentMatchesOriginal: true, currentMatchesApplied: false, committed: false), .unchanged)
        XCTAssertEqual(DNSRecoveryPolicy.decide(currentMatchesOriginal: false, currentMatchesApplied: true, committed: true), .restoreOwnedValue)
        XCTAssertEqual(DNSRecoveryPolicy.decide(currentMatchesOriginal: false, currentMatchesApplied: true, committed: false), .conflict)
        XCTAssertEqual(DNSRecoveryPolicy.decide(currentMatchesOriginal: false, currentMatchesApplied: false, committed: true), .conflict)
        XCTAssertFalse(DNSRecoveryPolicy.validServiceID("x\nremove State:/Network"))
        XCTAssertFalse(DNSRecoveryPolicy.validTunnel("utun1;whoami"))
    }
}
