import XCTest
@testable import VPNNavigatorCore

final class ProductReadinessTests: XCTestCase {
    func testPreferencesRejectUntrustedDeadlines() throws {
        XCTAssertEqual(SessionPreferences(connectionTimeout: 0).connectionTimeout, 20)
        XCTAssertEqual(SessionPreferences(connectionTimeout: 999).connectionTimeout, 180)
        XCTAssertThrowsError(try SessionPreferences.decoded(#"{"connectionTimeout":999,"reconnectOriginal":true}"#))
        XCTAssertThrowsError(try SessionPreferences.decoded(String(repeating: "x", count: 1025)))
        let preferences = SessionPreferences(connectionTimeout: 90, reconnectOriginal: false)
        XCTAssertEqual(try SessionPreferences.decoded(preferences.json), preferences)
    }
    func testConnectionCanBeCancelledDuringAuthenticationAndReconnect() {
        for state: TunnelState in [.connecting, .authenticating, .reconnecting] {
            XCTAssertTrue(ConnectionControl.canStop(state))
            XCTAssertTrue(ConnectionControl.inProgress(state))
        }
        XCTAssertFalse(ConnectionControl.canStop(.stopping))
        XCTAssertFalse(ConnectionControl.canStop(.disconnected))
    }
    func testLogClassificationCannotPersistSourceSecrets() throws {
        let raw = "AUTH_FAILED user=private@example.org password=secret-token 192.168.1.20"
        let code = try XCTUnwrap(OpenVPNLogClassifier.classify(raw))
        XCTAssertEqual(code, .authentication)
        let event = DiagnosticEvent(code)
        let json = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        for secret in ["private@example.org", "secret-token", "192.168.1.20"] {
            XCTAssertFalse(json.contains(secret)); XCTAssertFalse(code.summary.contains(secret))
        }
        XCTAssertNil(OpenVPNLogClassifier.classify("-----BEGIN PRIVATE KEY-----"))
    }
    func testPrivateEventLogIsBoundedAndRejectsSymlink() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("events.json")
        let store = DiagnosticEventStore(file: file)
        for i in 0..<180 { store.append(i.isMultiple(of: 2) ? .starting : .stopped) }
        XCTAssertEqual(store.events().count, 150)
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let target = folder.appendingPathComponent("target.json")
        try Data("unchanged".utf8).write(to: target)
        let link = folder.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        DiagnosticEventStore(file: link).append(.tls)
        XCTAssertEqual(try String(contentsOf: target), "unchanged")
    }
    func testActualPingSummaryAndCompletePacketLoss() throws {
        let output = "3 packets transmitted, 3 packets received, 0.0% packet loss\nround-trip min/avg/max/stddev = 10.0/12.5/14.0/1.0 ms"
        let summary = try XCTUnwrap(PingSummary.parse(output))
        XCTAssertEqual(summary.received, 3)
        XCTAssertEqual(summary.averageMilliseconds, 12.5)
        XCTAssertEqual(PingSummary.parse("3 packets transmitted, 0 packets received, 100.0% packet loss")?.loss, 100)
        XCTAssertNil(PingSummary.parse("ping: cannot resolve host"))
    }
    func testProbeTargetCannotBecomeCommandOrMultilineInput() {
        for bad in ["-h", "a..b", "example.com\nremote", "$(touch file)", "x;whoami", "a/b", "a b", String(repeating: "a", count: 64)] {
            XCTAssertFalse(DiagnosticTargetPolicy.validHostname(bad), bad)
        }
        XCTAssertTrue(DiagnosticTargetPolicy.validHostname("www.apple.com"))
        XCTAssertTrue(DiagnosticTargetPolicy.validHostname("223.5.5.5"))
    }
}
