import XCTest
@testable import VPNNavigatorCore

final class TunnelSpeedTests: XCTestCase {
    private let profile = UUID(), attempt = UUID()
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private func report(_ received: UInt64 = 1_000, _ sent: UInt64 = 100, state: TunnelState = .connected,
                        profile: UUID? = nil, attempt: UUID? = nil, recovery: Bool = false, mode: RoutingMode? = .original) -> SessionReport {
        .init(state: state, message: "synthetic", activeProfileID: profile ?? self.profile,
              receivedBytes: received, sentBytes: sent, attemptID: attempt ?? self.attempt,
              networkRecoveryRequired: recovery, routingMode: mode)
    }
    private func feed(_ tracker: inout TunnelSpeedTracker, _ report: SessionReport, _ time: Double, wall: Double? = nil) {
        tracker.observe(report, at: start.addingTimeInterval(wall ?? time), uptime: time)
    }
    private func current(_ tracker: TunnelSpeedTracker, _ time: Double, wall: Double? = nil) -> TunnelSpeed? {
        tracker.current(at: start.addingTimeInterval(wall ?? time), uptime: time)
    }
    func testActualElapsedTimeAndMeasuredIdle() {
        var tracker = TunnelSpeedTracker()
        feed(&tracker, report(), 10)
        XCTAssertNil(current(tracker, 10))
        feed(&tracker, report(4_000, 400), 12)
        XCTAssertEqual(current(tracker, 12)?.receivedPerSecond, 1_500)
        XCTAssertEqual(current(tracker, 12)?.sentPerSecond, 150)
        feed(&tracker, report(4_000, 400), 13)
        XCTAssertEqual(current(tracker, 13)?.receivedPerSecond, 0)
    }
    func testProfileAndAttemptChangesRebaseline() {
        for changeProfile in [false, true] {
            var tracker = TunnelSpeedTracker()
            feed(&tracker, report(), 10); feed(&tracker, report(2_000, 200), 11)
            feed(&tracker, report(9_000, 900, profile: changeProfile ? UUID() : profile,
                                 attempt: changeProfile ? attempt : UUID()), 12)
            XCTAssertNil(current(tracker, 12))
        }
    }
    func testReconnectDisconnectAndRecoveryClearReadings() {
        for state in [TunnelState.reconnecting, .authenticating, .stopping, .disconnected, .failed] {
            var tracker = TunnelSpeedTracker()
            feed(&tracker, report(), 10); feed(&tracker, report(2_000, 200), 11)
            feed(&tracker, report(state: state), 12)
            XCTAssertNil(current(tracker, 12))
            feed(&tracker, report(50_000, 500), 13)
            XCTAssertNil(current(tracker, 13))
        }
        var tracker = TunnelSpeedTracker()
        feed(&tracker, report(), 10); feed(&tracker, report(2_000, 200), 11)
        feed(&tracker, report(recovery: true), 12)
        XCTAssertNil(current(tracker, 12))
    }
    func testIncompleteUnverifiedReportsAndExplicitReset() {
        let invalid: [SessionReport] = [
            .init(state: .connected, message: "", activeProfileID: profile, receivedBytes: 3_000, sentBytes: 300, networkRecoveryRequired: false, routingMode: .original),
            .init(state: .connected, message: "", activeProfileID: nil, receivedBytes: 3_000, sentBytes: 300, attemptID: attempt, networkRecoveryRequired: false, routingMode: .original),
            .init(state: .connected, message: "", activeProfileID: profile, receivedBytes: nil, sentBytes: nil, attemptID: attempt, networkRecoveryRequired: false, routingMode: .original),
            report(mode: nil), report(mode: .fullVPN)
        ]
        for value in invalid {
            var tracker = TunnelSpeedTracker()
            feed(&tracker, report(), 10); feed(&tracker, report(2_000, 200), 11)
            feed(&tracker, value, 12)
            XCTAssertNil(current(tracker, 12))
        }
        var tracker = TunnelSpeedTracker()
        feed(&tracker, report(), 10); feed(&tracker, report(2_000, 200), 11)
        tracker.reset(); XCTAssertNil(current(tracker, 11))
    }
    func testEitherCounterResetCannotUnderflow() {
        for value in [report(1, 300), report(3_000, 1)] {
            var tracker = TunnelSpeedTracker()
            feed(&tracker, report(), 10); feed(&tracker, report(2_000, 200), 11)
            feed(&tracker, value, 12)
            XCTAssertNil(current(tracker, 12))
            feed(&tracker, report(4_000, 400), 13)
            XCTAssertNotNil(current(tracker, 13))
        }
    }
    func testStaleSleepClockChangesAndInvalidTime() {
        var tracker = TunnelSpeedTracker()
        feed(&tracker, report(), 10); feed(&tracker, report(2_000, 200), 11)
        XCTAssertNil(current(tracker, 17))
        XCTAssertNil(current(tracker, 12, wall: 300))
        XCTAssertNil(current(tracker, 10))
        feed(&tracker, report(50_000, 5_000), 12, wall: 300)
        XCTAssertNil(current(tracker, 12, wall: 300))
        feed(&tracker, report(51_000, 5_100), 13, wall: 301)
        XCTAssertEqual(current(tracker, 13, wall: 301)?.receivedPerSecond, 1_000)
        feed(&tracker, report(), .nan)
        XCTAssertNil(current(tracker, 13, wall: 301))
        XCTAssertNil(tracker.current(at: Date(timeIntervalSince1970: .infinity), uptime: 13))
    }
    func testExtraRefreshDoesNotConsumeShortInterval() {
        var tracker = TunnelSpeedTracker()
        feed(&tracker, report(), 10)
        feed(&tracker, report(1_500, 150), 10.1)
        XCTAssertNil(current(tracker, 10.1))
        feed(&tracker, report(2_000, 200), 11)
        XCTAssertEqual(current(tracker, 11)?.receivedPerSecond, 1_000)
        feed(&tracker, report(3_000, 300), 9)
        XCTAssertNil(current(tracker, 9))
    }
    func testCompactFormattingAndExtremeCounters() {
        XCTAssertEqual(TunnelSpeedFormat.string(nil), "—")
        XCTAssertEqual(TunnelSpeedFormat.string(.nan), "—")
        XCTAssertEqual(TunnelSpeedFormat.string(-1), "—")
        XCTAssertEqual(TunnelSpeedFormat.string(0), "0 B/s")
        XCTAssertEqual(TunnelSpeedFormat.string(999), "999 B/s")
        XCTAssertEqual(TunnelSpeedFormat.string(1_000), "1.0 KB/s")
        XCTAssertEqual(TunnelSpeedFormat.string(1_250_000), "1.2 MB/s")
        XCTAssertEqual(TunnelSpeedFormat.string(999_999), "1.0 MB/s")
        var tracker = TunnelSpeedTracker()
        feed(&tracker, report(0, 0), 10)
        feed(&tracker, report(UInt64.max, UInt64.max), 11)
        XCTAssertTrue(current(tracker, 11)!.receivedPerSecond.isFinite)
        XCTAssertLessThanOrEqual(TunnelSpeedFormat.string(current(tracker, 11)?.receivedPerSecond).count, 9)
    }
    func testChartKeepsOnlySixtySecondsWithRealTimestamps() {
        var tracker = TunnelSpeedTracker()
        for time in 0...80 { feed(&tracker, report(UInt64(time * 1_000), UInt64(time * 100)), Double(time)) }
        let points = tracker.visibleSamples(at: start.addingTimeInterval(80), uptime: 80)
        XCTAssertEqual(points.count, 61)
        XCTAssertEqual(points.first?.uptime, 20)
        XCTAssertEqual(points.last?.uptime, 80)
        XCTAssertTrue(points.allSatisfy { $0.speed.receivedPerSecond == 1_000 && $0.speed.sentPerSecond == 100 })
        XCTAssertEqual(tracker.observedConnectedSeconds, 80)
    }
    func testIrregularPollsUseTheirRealTimeOnTheChart() {
        var tracker = TunnelSpeedTracker()
        feed(&tracker, report(0, 0), 10)
        feed(&tracker, report(2_000, 200), 12)
        feed(&tracker, report(5_000, 500), 15)
        XCTAssertEqual(tracker.samples.map(\.uptime), [12, 15])
        XCTAssertEqual(tracker.samples.map { $0.speed.receivedPerSecond }, [1_000, 1_000])
        XCTAssertEqual(tracker.observedConnectedSeconds, 5)
    }
    func testChartExpiresWithoutAnotherReport() {
        var tracker = TunnelSpeedTracker()
        feed(&tracker, report(), 10); feed(&tracker, report(2_000, 200), 11)
        XCTAssertFalse(tracker.visibleSamples(at: start.addingTimeInterval(11), uptime: 11).isEmpty)
        XCTAssertTrue(tracker.visibleSamples(at: start.addingTimeInterval(17), uptime: 17).isEmpty)
        XCTAssertFalse(tracker.isFresh(at: start.addingTimeInterval(17), uptime: 17))
        XCTAssertTrue(tracker.visibleSamples(at: start.addingTimeInterval(300), uptime: 12).isEmpty)
    }
    func testResetAndNewAttemptNeverMixCurvesOrDurations() {
        var tracker = TunnelSpeedTracker()
        feed(&tracker, report(), 10); feed(&tracker, report(2_000, 200), 11)
        feed(&tracker, report(9_000, 900, attempt: UUID()), 12)
        XCTAssertTrue(tracker.samples.isEmpty)
        XCTAssertEqual(tracker.observedConnectedSeconds, 0)
        tracker.reset(); XCTAssertTrue(tracker.samples.isEmpty)
        XCTAssertFalse(tracker.isFresh(at: start.addingTimeInterval(12), uptime: 12))
    }
    func testCounterResetClearsChartImmediatelyEvenDuringExtraRefresh() {
        var tracker = TunnelSpeedTracker()
        feed(&tracker, report(), 10); feed(&tracker, report(2_000, 200), 11)
        feed(&tracker, report(1, 1), 11.1)
        XCTAssertTrue(tracker.samples.isEmpty)
        XCTAssertNil(current(tracker, 11.1))
        XCTAssertEqual(tracker.observedConnectedSeconds, 1.1, accuracy: 0.0001)
    }
    func testGapStartsANewCurveAndExcludesUnobservedDuration() {
        var tracker = TunnelSpeedTracker()
        feed(&tracker, report(), 10); feed(&tracker, report(2_000, 200), 11)
        feed(&tracker, report(100_000, 10_000), 30)
        XCTAssertTrue(tracker.samples.isEmpty)
        XCTAssertEqual(tracker.observedConnectedSeconds, 1)
        feed(&tracker, report(101_000, 10_100), 31)
        XCTAssertEqual(tracker.samples.map(\.uptime), [31])
        XCTAssertEqual(tracker.observedConnectedSeconds, 2)
    }
    func testHalfSecondReportsRemainBoundedAndZeroIsMeasured() {
        var tracker = TunnelSpeedTracker()
        for i in 0...400 { feed(&tracker, report(), Double(i) * 0.5) }
        XCTAssertEqual(tracker.samples.count, 121)
        XCTAssertTrue(tracker.samples.allSatisfy { $0.speed.receivedPerSecond == 0 && $0.speed.sentPerSecond == 0 })
        feed(&tracker, report(state: .reconnecting), 201)
        XCTAssertTrue(tracker.samples.isEmpty)
        XCTAssertEqual(tracker.observedConnectedSeconds, 0)
    }
}
