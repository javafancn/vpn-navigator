import XCTest
@testable import VPNNavigatorCore

final class ConnectionHistoryTests: XCTestCase {
    private let profile = UUID(), attempt = UUID(), date = Date(timeIntervalSince1970: 1_700_000_000)
    private func report(_ state: TunnelState = .connected, receive: UInt64? = 0, send: UInt64? = 0, mode: RoutingMode? = .original, revision: UUID? = nil, attempt: UUID? = nil, profile: UUID? = nil, failure: DiagnosticCode? = nil) -> ConnectionHistoryInput {
        .report(.init(.init(state: state, message: "NEVER_SAVE_THIS_PASSWORD_OR_HOST.example", activeProfileID: profile ?? self.profile,
            receivedBytes: receive, sentBytes: send, attemptID: attempt ?? self.attempt, networkRecoveryRequired: false,
            routingMode: mode, routingRevision: revision, failureCode: failure)))
    }
    private func advance(_ tracker: inout ConnectionHistoryTracker, _ input: ConnectionHistoryInput, _ seconds: Double) {
        tracker.consume(input, at: date.addingTimeInterval(seconds), uptime: 100 + seconds)
    }
    func testTransitionDedupeRatesAndObservedDuration() {
        var tracker = ConnectionHistoryTracker(now: date)
        advance(&tracker, .begin(profileID: profile, attemptID: attempt), 0)
        advance(&tracker, report(receive: 1000, send: 100), 1)
        advance(&tracker, report(receive: 4000, send: 500), 3)
        XCTAssertEqual(tracker.quality.receivedPerSecond, 1500); XCTAssertEqual(tracker.quality.sentPerSecond, 200)
        XCTAssertEqual(tracker.quality.observedConnectedSeconds, 2); XCTAssertEqual(tracker.records[0].receivedBytes, 3000)
        XCTAssertEqual(tracker.records[0].events.map(\.kind), [.requested, .connected])
    }
    func testShortDuplicatePollDoesNotCreateASpeedSpike() {
        var tracker = ConnectionHistoryTracker(now: date)
        advance(&tracker, report(), 0); advance(&tracker, report(receive: 1000), 0.001)
        XCTAssertNil(tracker.quality.receivedPerSecond)
        advance(&tracker, report(receive: 2000), 2)
        XCTAssertEqual(tracker.quality.receivedPerSecond, 1000)
    }
    func testMissingCountersAreUnknownRatherThanZeroSpeed() {
        var tracker = ConnectionHistoryTracker(now: date)
        advance(&tracker, report(), 0); advance(&tracker, report(receive: 100), 1)
        advance(&tracker, report(receive: nil, send: nil), 2)
        XCTAssertTrue(tracker.quality.verified); XCTAssertNil(tracker.quality.receivedPerSecond)
        XCTAssertEqual(tracker.quality.observedConnectedSeconds, 2)
        advance(&tracker, report(receive: 10000), 3); XCTAssertEqual(tracker.quality.receivedBytes, 100)
    }
    func testUnverifiedAndResumedObservationExcludeTheGap() {
        var tracker = ConnectionHistoryTracker(now: date)
        advance(&tracker, report(), 0); advance(&tracker, report(receive: 200), 2)
        advance(&tracker, .unverified, 3); advance(&tracker, .unverified, 4)
        XCTAssertFalse(tracker.quality.verified); XCTAssertNil(tracker.quality.receivedPerSecond)
        advance(&tracker, report(receive: 9000), 9); advance(&tracker, report(receive: 9200), 11)
        XCTAssertEqual(tracker.quality.observedConnectedSeconds, 4); XCTAssertEqual(tracker.quality.receivedBytes, 400)
        XCTAssertEqual(tracker.records[0].events.filter { $0.kind == .verificationLost }.count, 1)
        XCTAssertTrue(tracker.records[0].events.contains { $0.kind == .observationResumed })
    }
    func testSleepAndClockChangesRestartSampling() {
        var tracker = ConnectionHistoryTracker(now: date)
        advance(&tracker, report(), 0); advance(&tracker, report(receive: 1000), 60)
        XCTAssertNil(tracker.quality.receivedPerSecond); XCTAssertEqual(tracker.quality.observedConnectedSeconds, 0)
        tracker.consume(report(receive: 2000), at: date.addingTimeInterval(-60), uptime: 161)
        XCTAssertNil(tracker.quality.receivedPerSecond); XCTAssertEqual(tracker.quality.receivedBytes, 0)
        XCTAssertTrue(tracker.records[0].events.contains { $0.kind == .observationGap })
    }
    func testResetAndUInt64OverflowRemainBounded() {
        var tracker = ConnectionHistoryTracker(now: date)
        advance(&tracker, report(), 0); advance(&tracker, report(receive: .max), 1)
        advance(&tracker, report(), 2); XCTAssertNil(tracker.quality.receivedPerSecond)
        advance(&tracker, report(receive: .max), 3)
        XCTAssertEqual(tracker.quality.receivedBytes, UInt64.max)
        XCTAssertTrue(tracker.quality.receivedPerSecond?.isFinite == true)
        XCTAssertTrue(tracker.records[0].events.contains { $0.kind == .counterReset })
    }
    func testRouteModeSwitchAndGuardedReconnectStayInOneRecord() {
        var tracker = ConnectionHistoryTracker(now: date)
        advance(&tracker, report(), 0)
        advance(&tracker, report(receive: 10, mode: .fullVPN, revision: UUID()), 1)
        advance(&tracker, report(.reconnecting), 2); advance(&tracker, report(receive: 0, mode: .fullVPN, revision: UUID()), 3)
        XCTAssertEqual(tracker.records.count, 1); XCTAssertTrue(tracker.records[0].events.contains { $0.kind == .modeChanged })
        XCTAssertTrue(tracker.records[0].events.contains { $0.kind == .reconnecting }); XCTAssertNil(tracker.quality.receivedPerSecond)
    }
    func testConnectedWithoutRoutingEvidenceIsNotVerified() {
        var tracker = ConnectionHistoryTracker(now: date)
        advance(&tracker, report(mode: .fullVPN), 0)
        XCTAssertFalse(tracker.quality.verified); XCTAssertFalse(tracker.records[0].everConnected)
        advance(&tracker, report(mode: .fullVPN, revision: UUID()), 2)
        XCTAssertTrue(tracker.quality.verified)
    }
    func testTerminalPollsDoNotDuplicateFailuresOrFinishAnotherAttempt() {
        var tracker = ConnectionHistoryTracker(now: date)
        advance(&tracker, .begin(profileID: profile, attemptID: attempt), 0)
        advance(&tracker, report(.failed, failure: .authentication), 1)
        advance(&tracker, report(.failed, failure: .authentication), 2)
        XCTAssertEqual(tracker.records.count, 1); XCTAssertEqual(tracker.records[0].outcome, .failed)
        let next = UUID(); advance(&tracker, .begin(profileID: profile, attemptID: next), 3)
        advance(&tracker, report(.disconnected), 4)
        XCTAssertEqual(tracker.records.first?.outcome, .observing)
        XCTAssertEqual(tracker.records.first?.attemptID, next)
    }
    func testUserCancellationAndNormalDisconnectHaveDifferentOutcomes() {
        var tracker = ConnectionHistoryTracker(now: date)
        advance(&tracker, .begin(profileID: profile, attemptID: attempt), 0)
        advance(&tracker, .userStop, 1); advance(&tracker, report(.disconnected), 2)
        XCTAssertEqual(tracker.records[0].outcome, .cancelled)
        let next = UUID(); advance(&tracker, report(attempt: next), 3)
        advance(&tracker, .userStop, 4); advance(&tracker, report(.disconnected, attempt: next), 5)
        XCTAssertEqual(tracker.records[0].outcome, .completed)
    }
    func testApplicationRestartClosesOnlyTheRecordedObservation() throws {
        var tracker = ConnectionHistoryTracker(now: date)
        advance(&tracker, report(), 0); advance(&tracker, report(receive: 200), 2)
        let encoded = try JSONEncoder().encode(tracker.archive)
        let archive = try JSONDecoder().decode(ConnectionHistoryArchive.self, from: encoded)
        let resumed = ConnectionHistoryTracker(archive: archive, now: date.addingTimeInterval(86400))
        XCTAssertEqual(resumed.records[0].outcome, .interrupted); XCTAssertEqual(resumed.records[0].observedConnectedSeconds, 2)
        XCTAssertEqual(resumed.records[0].endedAt, date.addingTimeInterval(2))
    }
    func testClearPausesAndNeverPersistsSessionTombstones() throws {
        var tracker = ConnectionHistoryTracker(now: date)
        advance(&tracker, report(), 0); tracker.clearAndPause(now: date.addingTimeInterval(1))
        advance(&tracker, report(receive: 200), 2)
        XCTAssertTrue(tracker.records.isEmpty); XCTAssertFalse(tracker.preferences.enabled)
        let json = String(decoding: try JSONEncoder().encode(tracker.archive), as: UTF8.self)
        XCTAssertFalse(json.contains(profile.uuidString)); XCTAssertFalse(json.contains(attempt.uuidString))
        try tracker.configure(.init(enabled: true), now: date.addingTimeInterval(3))
        XCTAssertEqual(tracker.records.count, 1); XCTAssertEqual(tracker.records[0].receivedBytes, 0)
    }
    func testRetentionAndBothSizeCaps() throws {
        var tracker = ConnectionHistoryTracker(now: date)
        for i in 0..<250 {
            let id = UUID(); advance(&tracker, .begin(profileID: profile, attemptID: id), Double(i * 2))
            advance(&tracker, .requestFailed(attemptID: id), Double(i * 2 + 1))
        }
        XCTAssertEqual(tracker.records.count, 200)
        advance(&tracker, .begin(profileID: profile, attemptID: attempt), 600)
        for i in 0..<100 { advance(&tracker, report(i % 2 == 0 ? .connecting : .authenticating), Double(601 + i)) }
        XCTAssertEqual(tracker.records.count, 200); XCTAssertEqual(tracker.records[0].events.count, 40)
        try tracker.archive.validate()
        advance(&tracker, report(.disconnected), 701)
        tracker.consume(.unverified, at: date.addingTimeInterval(8 * 86400), uptime: 8 * 86400)
        XCTAssertTrue(tracker.records.isEmpty)
    }
    func testDisabledRecordingKeepsLiveMeasurementsAndPriorHistory() throws {
        var tracker = ConnectionHistoryTracker(now: date)
        advance(&tracker, report(), 0)
        try tracker.configure(.init(enabled: false, retentionDays: 30), now: date.addingTimeInterval(1))
        advance(&tracker, report(receive: 100), 2); advance(&tracker, report(receive: 300), 4)
        XCTAssertEqual(tracker.records.count, 1); XCTAssertEqual(tracker.records[0].outcome, .interrupted)
        XCTAssertEqual(tracker.quality.receivedPerSecond, 100)
    }
    func testArchiveValidationAndAllowlistsExcludeArbitraryMessages() throws {
        var tracker = ConnectionHistoryTracker(now: date); advance(&tracker, report(), 0)
        let text = String(decoding: try JSONEncoder().encode(tracker.archive), as: UTF8.self)
        for secret in ["NEVER_SAVE", "PASSWORD", "HOST.example", "challenge", "username"] { XCTAssertFalse(text.contains(secret)) }
        var bad = tracker.archive; bad.schema = 99; XCTAssertThrowsError(try bad.validate())
        bad = tracker.archive; bad.preferences.retentionDays = 1; XCTAssertThrowsError(try bad.validate())
        bad = tracker.archive; bad.records[0].observedConnectedSeconds = .infinity; XCTAssertThrowsError(try bad.validate())
    }
}
