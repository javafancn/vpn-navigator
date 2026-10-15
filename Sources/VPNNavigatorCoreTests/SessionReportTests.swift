import XCTest
@testable import VPNNavigatorCore

final class SessionReportTests: XCTestCase {
    func testNativeStatusAndByteCountsRoundTrip() throws {
        let id = UUID()
        let report = SessionReport(state: .connected, message: "Ready",
            activeProfileID: id, receivedBytes: 4096, sentBytes: 1200)
        let restored = try JSONDecoder().decode(
            SessionReport.self, from: JSONEncoder().encode(report))
        XCTAssertEqual(restored, report)
        XCTAssertEqual(restored.statusText, "connected: Ready")
        XCTAssertEqual(restored.activeProfileID, id)
        XCTAssertEqual(restored.traffic?.receivedBytes, 4096)
    }
    func testDisconnectedStatusDoesNotInventTraffic() throws {
        let report = SessionReport(state: .disconnected, message: "Disconnected",
            activeProfileID: nil, receivedBytes: nil, sentBytes: nil)
        XCTAssertNil(report.traffic)
        XCTAssertNil(report.activeProfileID)
    }
}
