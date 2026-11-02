import XCTest
@testable import VPNNavigatorCore

final class ServerIdentityPolicyTests: XCTestCase {
    private let base = "client\ndev tun\nremote fixture.example 1194\n<ca>\nTEST_CA\n</ca>\nauth-user-pass\n"
    func testLegacyProfileRemainsEditableButCannotConnect() throws {
        XCTAssertNoThrow(try ProfileSafety.validate(base))
        XCTAssertThrowsError(try ProfileSafety.validateForConnection(base)) { XCTAssertEqual($0 as? ServerIdentityError, .missing) }
        let report = ProfileHealth.inspect(runtime: base)
        XCTAssertTrue(report.issues.contains { $0.id == "server-identity" && $0.severity == .error })
    }
    func testServerRoleAndExactNamesAreAcceptedWithoutChangingSource() throws {
        for option in ["remote-cert-tls server", "remote-cert-tls\tserver # expected role", "\"remote-cert-tls\" \"server\"", "verify-x509-name expected-server name", "verify-x509-name 'CN=expected-server'", "verify-x509-name 'CN=expected-server' subject"] {
            let text = base + option + "\n"
            XCTAssertEqual(try ProfileSafety.validateForConnection(text).text, text)
        }
    }
    func testCommentsInlineMaterialAndNamePrefixesCannotSupplyIdentity() {
        for suffix in ["# remote-cert-tls server", "; verify-x509-name expected name", "verify-x509-name expected name-prefix", "verify-x509-name expected name\nverify-x509-name broad name-prefix", "<cert>\nremote-cert-tls server\n</cert>"] {
            XCTAssertThrowsError(try ProfileSafety.validateForConnection(base + suffix)) { XCTAssertEqual($0 as? ServerIdentityError, .missing) }
        }
        XCTAssertNoThrow(try ProfileSafety.validateForConnection(base + "remote-cert-tls server\nverify-x509-name expected name-prefix"))
    }
    func testWrongRoleConflictsAndMalformedOptionsAreRejected() {
        for suffix in ["remote-cert-tls client", "remote-cert-tls server\nremote-cert-tls client", "remote-cert-tls client\nremote-cert-tls server", "remote-cert-tls client\nverify-x509-name expected name"] {
            XCTAssertThrowsError(try ProfileSafety.validateForConnection(base + suffix)) { XCTAssertEqual($0 as? ServerIdentityError, .wrongRole) }
        }
        for suffix in ["remote-cert-tls", "remote-cert-tls server extra", "remote-cert-tls invalid", "verify-x509-name", "verify-x509-name ''", "verify-x509-name expected invalid", "verify-x509-name expected name extra"] {
            XCTAssertThrowsError(try ProfileSafety.validateForConnection(base + suffix)) { XCTAssertEqual($0 as? ServerIdentityError, .invalid) }
        }
    }
    func testHealthDoesNotCallAnUnconstrainedValidCertificateHealthy() {
        let missing = HealthCertificateFixture.config.replacingOccurrences(of: "remote-cert-tls server\n", with: "")
        let report = ProfileHealth.inspect(runtime: missing, now: HealthCertificateFixture.start.addingTimeInterval(100 * 86_400))
        XCTAssertEqual(report.certificates.count, 1)
        XCTAssertEqual(report.severity, .error)
        XCTAssertEqual(report.issues.map(\.id), ["server-identity"])
    }
}
