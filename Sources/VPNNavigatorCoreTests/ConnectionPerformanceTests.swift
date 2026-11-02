import XCTest
@testable import VPNNavigatorCore

final class ConnectionPerformanceTests: XCTestCase {
    func testStageDurationsUseMonotonicDeltasAndTotalIsNotAnotherDelta() throws {
        var tracker = ConnectionPerformance(uptime: 10)
        tracker.record(.preparation, uptime: 10.025)
        tracker.record(.engineStartup, uptime: 10.1)
        tracker.record(.negotiation, uptime: 10.5)
        tracker.complete(uptime: 10.6)
        tracker.complete(uptime: 11)
        XCTAssertEqual(tracker.timings.map(\.milliseconds), [25, 75, 400, 600])
        let encoded = try JSONEncoder().encode(tracker.timings)
        XCTAssertEqual(try JSONDecoder().decode([ConnectionStageTiming].self, from: encoded), tracker.timings)
    }
    func testInvalidClockAndRepeatedEventsStayBounded() {
        var tracker = ConnectionPerformance(uptime: 1)
        tracker.record(.dns, uptime: .nan)
        tracker.record(.dns, uptime: 0)
        XCTAssertTrue(tracker.timings.isEmpty)
        for index in 1...100 { tracker.record(.negotiation, uptime: Double(index)) }
        tracker.complete(uptime: 101)
        XCTAssertEqual(tracker.timings.count, 17)
    }
    func testLegacySessionReportDoesNotRequireTimings() throws {
        let report = SessionReport(state: .disconnected, message: "Disconnected", activeProfileID: nil, receivedBytes: nil, sentBytes: nil)
        let decoded = try JSONDecoder().decode(SessionReport.self, from: JSONEncoder().encode(report))
        XCTAssertNil(decoded.connectionTimings)
    }
}
