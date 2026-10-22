import XCTest
@testable import VPNNavigatorCore

final class SmartConnectionTests: XCTestCase {
    private let id = UUID(), attempt = UUID()
    private var enabled: SmartConnectionPreferences {
        var value = SmartConnectionPreferences(); value.enabled = true; value.onLaunch = true; value.onWake = true; value.onNetworkRestore = true; return value
    }
    private func decision(_ value: SmartConnectionPreferences? = nil, network: SmartNetworkState = .init(online: true),
                          context: SmartConnectionContext = .init(state: .disconnected, helperReady: true)) -> SmartConnectionDecision {
        SmartConnectionPlanner.decide(preferences: value ?? enabled, trigger: .launch, network: network, context: context, target: id)
    }
    private func report(_ state: TunnelState, attemptID: UUID? = nil, recovery: Bool = false,
                        failure: DiagnosticCode? = nil, challenge: AuthenticationChallenge? = nil, verified: Bool = true) -> SessionReport {
        .init(state: state, message: "private-server-message", activeProfileID: id, receivedBytes: nil, sentBytes: nil,
              challenge: challenge, attemptID: attemptID ?? attempt, networkRecoveryRequired: recovery,
              routingMode: .fullVPN, routingRevision: verified ? id : nil, failureCode: failure)
    }
    func testEverythingRequiresOptIn() {
        let value = SmartConnectionPreferences()
        XCTAssertFalse(value.notifications); XCTAssertFalse(value.enabled); XCTAssertFalse(value.sound)
        for trigger in [SmartTrigger.launch, .wake, .networkRestored] { XCTAssertFalse(value.accepts(trigger)) }
        XCTAssertEqual(decision(value), .disabled)
    }
    func testTriggerAndPauseAreIndependentGates() {
        var value = enabled; value.onLaunch = false; XCTAssertEqual(decision(value), .disabled)
        value.onLaunch = true; value.paused = true
        guard case .wait = decision(value) else { return XCTFail() }
        value.paused = false; XCTAssertEqual(decision(value), .connect(id))
    }
    func testUnavailableNetworkSleepingAndMeteredFailClosed() {
        for network in [SmartNetworkState(online: false), .init(online: true, expensive: true)] {
            guard case .wait = decision(network: network) else { return XCTFail() }
        }
        guard case .wait = decision(context: .init(state: .disconnected, helperReady: true, sleeping: true)) else { return XCTFail() }
        var value = enabled; value.allowExpensive = true
        XCTAssertEqual(decision(value, network: .init(online: true, expensive: true)), .connect(id))
    }
    func testExactWiFiNameIsRequiredAndCaseSensitive() {
        var value = enabled; value.networkScope = .specifiedWiFi; value.wifiNames = ["Office"]
        for name in [nil, "office", "Office "] as [String?] {
            guard case .wait = decision(value, network: .init(online: true, kind: .wifi, wifiName: name)) else { return XCTFail() }
        }
        XCTAssertEqual(decision(value, network: .init(online: true, kind: .wifi, wifiName: "Office")), .connect(id))
        guard case .wait = decision(value, network: .init(online: true, kind: .wired, wifiName: "Office")) else { return XCTFail() }
    }
    func testNetworkScopeMatchesPhysicalKind() {
        var value = enabled; value.networkScope = .wired
        XCTAssertEqual(decision(value, network: .init(online: true, kind: .wired)), .connect(id))
        guard case .wait = decision(value, network: .init(online: true, kind: .wifi)) else { return XCTFail() }
        value.networkScope = .wifi
        XCTAssertEqual(decision(value, network: .init(online: true, kind: .wifi)), .connect(id))
    }
    func testAllActiveOrFailedStatesRefuseAutomaticStart() {
        for state in [TunnelState.connected, .connecting, .authenticating, .reconnecting, .stopping, .failed] {
            guard case .wait = decision(context: .init(state: state, helperReady: true)) else { return XCTFail(state.rawValue) }
        }
        guard case .wait = decision(context: .init(state: .disconnected, activeProfileID: id, helperReady: true)) else { return XCTFail() }
    }
    func testUnknownHelperRecoveryAndEditingRefuseStart() {
        for context in [SmartConnectionContext(state: .disconnected, helperReady: false),
                        .init(state: .disconnected, helperReady: true, recoveryRequired: true),
                        .init(state: .disconnected, helperReady: true, occupied: true)] {
            guard case .wait = decision(context: context) else { return XCTFail() }
        }
    }
    func testRecentSuccessfulExistingProfileWinsAndFutureDatesAreIgnored() {
        let a = VPNProfile(name: "a", sourceFilename: "a.ovpn", relativePath: "a")
        let b = VPNProfile(name: "b", sourceFilename: "b.ovpn", relativePath: "b")
        let now = Date(timeIntervalSince1970: 200)
        let result = SmartConnectionPlanner.target(profiles: [a,b], successes: [a.id: now, b.id: now.addingTimeInterval(50), UUID(): now], preferred: nil, automatic: true, now: now)
        XCTAssertEqual(result?.id, a.id)
    }
    func testMissingPinnedProfileNeverFallsBack() {
        let a = VPNProfile(name: "a", sourceFilename: "a.ovpn", relativePath: "a")
        XCTAssertNil(SmartConnectionPlanner.target(profiles: [a], successes: [a.id: Date()], preferred: UUID(), automatic: false))
    }
    func testAutomaticNeedsHistoryButManualCanUseFavorite() {
        let a = VPNProfile(name: "a", sourceFilename: "a.ovpn", relativePath: "a")
        let b = VPNProfile(name: "b", sourceFilename: "b.ovpn", relativePath: "b", isFavorite: true)
        XCTAssertNil(SmartConnectionPlanner.target(profiles: [a,b], successes: [:], preferred: nil, automatic: true))
        XCTAssertEqual(SmartConnectionPlanner.target(profiles: [a,b], successes: [:], preferred: nil, automatic: false)?.id, b.id)
        XCTAssertEqual(SmartConnectionPlanner.target(profiles: [a,b], successes: [:], preferred: a.id, automatic: true)?.id, a.id)
    }
    func testInvalidNamesAndCorruptStoreDisableAutomation() throws {
        let suite = "SmartTests-" + UUID().uuidString
        let isolated = UserDefaults(suiteName: suite)!; defer { isolated.removePersistentDomain(forName: suite) }
        let store = SmartConnectionStore(defaults: isolated)
        for names in [[""], ["duplicate", "duplicate"], ["line\nbreak"], [String(repeating: "中", count: 11)], Array(repeating: "x", count: 33)] {
            var value = enabled; value.wifiNames = names
            XCTAssertThrowsError(try store.save(value))
        }
        isolated.set(Data("{\"enabled\":true}".utf8), forKey: "smartConnection.v1")
        XCTAssertFalse(store.load().enabled)
        var value = enabled; value.paused = true; value.wifiNames = ["Office"]
        try store.save(value); XCTAssertEqual(store.load(), value)
        store.recordSuccess(id); XCTAssertNotNil(store.successes()[id])
    }
    func testConnectedAdoptionIsSilentAndUnverifiedReceiptNeverAnnouncesSuccess() {
        var reducer = StatusNoticeReducer()
        XCTAssertEqual(reducer.observe(report(.connected)), [])
        _ = reducer.observe(report(.connecting, attemptID: UUID()))
        XCTAssertEqual(reducer.observe(report(.connected, verified: false)), [])
    }
    func testConnectedAndReconnectingAreDeduplicated() {
        var reducer = StatusNoticeReducer()
        _ = reducer.observe(report(.connecting))
        XCTAssertEqual(reducer.observe(report(.connected)), [.connected])
        XCTAssertEqual(reducer.observe(report(.connected)), [])
        XCTAssertEqual(reducer.observe(report(.reconnecting)), [.reconnecting])
        XCTAssertEqual(reducer.observe(report(.reconnecting)), [])
        XCTAssertEqual(reducer.observe(report(.connected)), [.connected])
        XCTAssertEqual(reducer.observe(report(.connected)), [])
        XCTAssertEqual(reducer.observe(report(.reconnecting)), [.reconnecting])
    }
    func testIntentionalAndUnexpectedDisconnectAreDistinct() {
        var reducer = StatusNoticeReducer(); _ = reducer.observe(report(.connected))
        XCTAssertEqual(reducer.observe(report(.disconnected), expectedDisconnect: true), [.disconnected])
        var other = StatusNoticeReducer(); _ = other.observe(report(.connected))
        XCTAssertEqual(other.observe(report(.disconnected)), [.lost])
        XCTAssertEqual(other.observe(report(.disconnected)), [])
    }
    func testFailedActiveSessionIsALossAndManualRecoveryFailureIsNotALoss() {
        var reducer = StatusNoticeReducer(); _ = reducer.observe(report(.connected))
        XCTAssertEqual(reducer.observe(report(.failed, recovery: true, failure: .networkChanged)), [.lost, .recovery])
        XCTAssertEqual(reducer.observe(report(.failed, recovery: true, failure: .networkChanged)), [])
        var manual = StatusNoticeReducer(); _ = manual.observe(report(.connected))
        XCTAssertEqual(manual.observe(report(.failed, recovery: true), expectedDisconnect: true), [.recovery])
    }
    func testAuthenticationAndRecoveryRemainDistinctAndDeduplicated() {
        var reducer = StatusNoticeReducer()
        XCTAssertEqual(reducer.observe(report(.failed, recovery: true, failure: .authentication)), [.authenticationFailed, .recovery])
        XCTAssertEqual(reducer.observe(report(.failed, recovery: true, failure: .authentication)), [])
        XCTAssertEqual(reducer.observe(report(.failed, attemptID: UUID(), failure: .certificate)), [.certificateFailed])
    }
    func testChallengeNotifiedOncePerChallengeWithoutContent() {
        var reducer = StatusNoticeReducer()
        let a = AuthenticationChallenge(kind: .dynamicOTP, prompt: "private-secret-prompt")
        XCTAssertEqual(reducer.observe(report(.authenticating, challenge: a)), [.authentication])
        XCTAssertEqual(reducer.observe(report(.authenticating, challenge: a)), [])
        let b = AuthenticationChallenge(kind: .dynamicOTP, prompt: "private-secret-prompt")
        XCTAssertEqual(reducer.observe(report(.authenticating, challenge: b)), [.authentication])
        XCTAssertFalse(VPNStatusNotice.authentication.body.contains(a.prompt))
    }
    func testUnavailableIsNotRepeatedAndCanRecover() {
        var reducer = StatusNoticeReducer(); XCTAssertEqual(reducer.observe(nil), [])
        _ = reducer.observe(report(.connected))
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(reducer.observe(nil, at: now), [.unavailable]); XCTAssertEqual(reducer.observe(nil, at: now), [])
        _ = reducer.observe(report(.connected))
        XCTAssertEqual(reducer.observe(nil, at: now.addingTimeInterval(1)), [])
        _ = reducer.observe(report(.connected))
        XCTAssertEqual(reducer.observe(nil, at: now.addingTimeInterval(61)), [.unavailable])
    }
    func testLegacySessionReportDecodesWithoutNewOptionalFields() throws {
        let data = Data("{\"state\":\"disconnected\",\"message\":\"\",\"firewallActive\":false,\"firewallRecoveryRequired\":false}".utf8)
        let decoded = try JSONDecoder().decode(SessionReport.self, from: data)
        XCTAssertNil(decoded.failureCode); XCTAssertNil(decoded.ipStack)
    }
}
