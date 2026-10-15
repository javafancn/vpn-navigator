import XCTest
@testable import VPNNavigatorCore

final class TrafficTrendTests: XCTestCase {
    func testOnlyRealDeltasAndBoundedHistory() {
        var trend = TrafficTrend(limit: 3)
        trend.record(cumulativeBytes: 100)
        XCTAssertTrue(trend.samples.isEmpty)
        trend.record(cumulativeBytes: 140)
        trend.record(cumulativeBytes: 205)
        trend.record(cumulativeBytes: 207)
        XCTAssertEqual(trend.samples, [40, 65, 2])
        trend.record(cumulativeBytes: 217)
        XCTAssertEqual(trend.samples, [65, 2, 10])
    }
    func testReconnectOrDisconnectResetsSparkline() {
        var trend = TrafficTrend()
        trend.record(cumulativeBytes: 200)
        trend.record(cumulativeBytes: 235)
        trend.record(cumulativeBytes: 8)
        XCTAssertTrue(trend.samples.isEmpty)
        trend.record(cumulativeBytes: 25)
        XCTAssertEqual(trend.samples, [17])
        trend.reset()
        trend.record(cumulativeBytes: 1000)
        XCTAssertTrue(trend.samples.isEmpty)
    }
}
