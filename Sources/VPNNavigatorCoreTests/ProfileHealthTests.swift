import XCTest
@testable import VPNNavigatorCore

final class ProfileHealthTests: XCTestCase {
    private let fixture = HealthCertificateFixture.config
    private let start = HealthCertificateFixture.start
    private let end = HealthCertificateFixture.end
    func testRealX509DatesAndHealthyMidpoint() {
        let report = ProfileHealth.inspect(runtime: fixture, now: start.addingTimeInterval(100 * 86_400))
        XCTAssertTrue(report.issues.isEmpty); XCTAssertEqual(report.certificates.count, 1)
        XCTAssertEqual(report.certificates.first?.notBefore, start); XCTAssertEqual(report.certificates.first?.notAfter, end)
        XCTAssertNil(report.reminderSignature(at: start.addingTimeInterval(100 * 86_400)))
    }
    func testExpiredAndNotYetValidAreSeparate() {
        let future = ProfileHealth.inspect(runtime: fixture, now: start.addingTimeInterval(-1))
        let expired = ProfileHealth.inspect(runtime: fixture, now: end.addingTimeInterval(1))
        XCTAssertEqual(future.severity, .error); XCTAssertTrue(future.issues.contains { $0.message.contains("尚未生效") })
        XCTAssertEqual(expired.severity, .error); XCTAssertTrue(expired.issues.contains { $0.message.contains("已过期") })
    }
    func testThirtySevenOneAndExpiredReminderBuckets() {
        let report = ProfileHealth.inspect(runtime: fixture, now: start)
        let days = [31.0, 30, 20, 7, 3, 1, 0.5, -1]
        let signatures = days.map { report.reminderSignature(at: end.addingTimeInterval(-$0 * 86_400)) }
        XCTAssertNil(signatures[0]); XCTAssertNotNil(signatures[1])
        XCTAssertEqual(signatures[1], signatures[2]); XCTAssertEqual(signatures[3], signatures[4]); XCTAssertEqual(signatures[5], signatures[6])
        XCTAssertNotEqual(signatures[2], signatures[3]); XCTAssertNotEqual(signatures[4], signatures[5]); XCTAssertNotEqual(signatures[6], signatures[7])
    }
    func testValidityBoundaryIsInclusiveAndDayWarningRoundsUp() {
        XCTAssertNotEqual(ProfileHealth.inspect(runtime: fixture, now: end).severity, .error)
        let warning = ProfileHealth.inspect(runtime: fixture, now: end.addingTimeInterval(-86_401))
        XCTAssertTrue(warning.issues.contains { $0.message.contains("2 天") })
    }
    func testMalformedAndPartialChainsNeverPassAsHealthy() {
        for value in ["FAKE_CA", HealthCertificateFixture.pem + "\n-----BEGIN CERTIFICATE-----\nBAD\n", ""] {
            let report = ProfileHealth.inspect(runtime: "client\nremote fixture.example\n<ca>\n" + value + "\n</ca>", now: start)
            XCTAssertFalse(report.issues.isEmpty)
        }
    }
    func testDuplicateCertificatesAndClientRole() {
        let config = fixture.replacingOccurrences(of: HealthCertificateFixture.pem, with: HealthCertificateFixture.pem + "\n" + HealthCertificateFixture.pem) + "<cert>\n" + HealthCertificateFixture.pem + "\n</cert>\n<key>\nSYNTHETIC\n</key>\n"
        let report = ProfileHealth.inspect(runtime: config, now: start.addingTimeInterval(100))
        XCTAssertEqual(report.certificates.count, 2); XCTAssertTrue(report.certificates.contains { $0.role == .client })
    }
    func testMissingClientKeyAndEncryptedPKCS12AreExplicit() {
        let report = ProfileHealth.inspect(runtime: fixture + "<cert>\n" + HealthCertificateFixture.pem + "\n</cert>\n", now: start)
        XCTAssertTrue(report.issues.contains { $0.id == "missing-key" })
        let container = ProfileHealth.inspect(runtime: fixture + "<pkcs12>\nDUMMY\n</pkcs12>\n", now: start)
        XCTAssertTrue(container.issues.contains { $0.id == "pkcs12" })
    }
    func testUnsafeDirectiveAndRoutingCompatibilityUseGenericErrors() {
        let secret = "DO_NOT_DISCLOSE_THIS_SECRET"
        let report = ProfileHealth.inspect(runtime: fixture + "up " + secret, now: start)
        XCTAssertEqual(report.severity, .error); XCTAssertFalse(report.issues.map(\.message).joined().contains(secret))
    }
    func testOversizeInputStopsCertificateWork() {
        let report = ProfileHealth.inspect(runtime: String(repeating: "x", count: 2_000_001), now: start)
        XCTAssertEqual(report.severity, .error); XCTAssertTrue(report.certificates.isEmpty)
    }
    func testIdentityIgnoresMetadataAndCommentsButTracksEndpointsAndMaterials() {
        let original = ProfileHealth.credentialContext(fixture)
        XCTAssertEqual(original, ProfileHealth.credentialContext(fixture + "# updated comment\nverb 4\n"))
        XCTAssertNotEqual(original, ProfileHealth.credentialContext(fixture.replacingOccurrences(of: "fixture.example", with: "other.example")))
        XCTAssertNotEqual(original, ProfileHealth.credentialContext(fixture + "<key>\nNEW_TEST_MATERIAL\n</key>\n"))
        XCTAssertNotEqual(original, ProfileHealth.credentialContext(fixture.replacingOccurrences(of: "auth-user-pass", with: "")))
    }
    func testReminderOptInPersistenceDedupeAndPruning() throws {
        let id = UUID(); var ledger = CertificateReminderLedger()
        XCTAssertFalse(ledger.shouldDeliver(id: id, signature: "30"))
        ledger.enabled = true; XCTAssertTrue(ledger.shouldDeliver(id: id, signature: "30"))
        ledger.record(id: id, signature: "30")
        let restored = try JSONDecoder().decode(CertificateReminderLedger.self, from: JSONEncoder().encode(ledger))
        XCTAssertFalse(restored.shouldDeliver(id: id, signature: "30")); XCTAssertTrue(restored.shouldDeliver(id: id, signature: "7"))
        ledger.reconcile(ids: []); XCTAssertTrue(ledger.delivered.isEmpty)
    }
}
