import XCTest
@testable import VPNNavigatorCore

final class QuickAccessTests: XCTestCase {
    private func profile(_ name: String, group: String = "个人", favorite: Bool = false) -> VPNProfile {
        VPNProfile(name: name, sourceFilename: name + ".ovpn", relativePath: "secret-material", group: group,
                   notes: "private-note", isFavorite: favorite)
    }
    func testSearchesMetadataWithoutNotesOrMaterialPaths() {
        let value = profile("工作网络", group: "公司")
        XCTAssertEqual(QuickProfileSearch.results([value], query: "公司"), [value])
        XCTAssertEqual(QuickProfileSearch.results([value], query: "ovpn"), [value])
        XCTAssertTrue(QuickProfileSearch.results([value], query: "private-note").isEmpty)
        XCTAssertTrue(QuickProfileSearch.results([value], query: "secret-material").isEmpty)
    }
    func testSearchFoldsWidthCaseAndAccents() {
        let value = profile("Café VPN")
        XCTAssertEqual(QuickProfileSearch.results([value], query: "ＣＡＦＥ"), [value])
    }
    func testAllTokensCanMatchDifferentMetadataFields() {
        let value = profile("Singapore", group: "工作")
        XCTAssertEqual(QuickProfileSearch.results([value], query: "  工作  SING  "), [value])
        XCTAssertTrue(QuickProfileSearch.results([value], query: "工作 London").isEmpty)
    }
    func testExactThenPrefixThenFavoriteRanking() {
        let exact = profile("Work"), prefix = profile("Workshop"), favorite = profile("My Work", favorite: true)
        XCTAssertEqual(QuickProfileSearch.results([favorite, prefix, exact], query: "Work"), [exact, prefix, favorite])
        XCTAssertEqual(QuickProfileSearch.results([prefix, exact, favorite], query: "").first, favorite)
    }
    func testLongQueriesAndDuplicateNamesRemainDeterministic() {
        let a = profile("same"), b = profile("same")
        XCTAssertTrue(QuickProfileSearch.results([a], query: String(repeating: "x", count: 257)).isEmpty)
        XCTAssertEqual(QuickProfileSearch.results([a, b], query: ""), QuickProfileSearch.results([b, a], query: ""))
    }
    func testKeyboardSelectionWrapsAndHandlesDeletion() {
        let a = UUID(), b = UUID()
        XCTAssertEqual(QuickProfileSearch.movedSelection(a, in: [a, b], offset: -1), b)
        XCTAssertEqual(QuickProfileSearch.movedSelection(b, in: [a, b], offset: 1), a)
        XCTAssertEqual(QuickProfileSearch.movedSelection(UUID(), in: [a, b], offset: 1), a)
        XCTAssertNil(QuickProfileSearch.movedSelection(a, in: [], offset: 1))
    }
    func testActiveProfileOpensAndOtherProfilesRequireConfirmation() {
        let a = UUID(), b = UUID()
        XCTAssertEqual(QuickAccessAction.resolve(state: .connected, profileID: a, activeProfileID: a, operationInProgress: false, mayStart: false), .openMain)
        XCTAssertEqual(QuickAccessAction.resolve(state: .connected, profileID: b, activeProfileID: a, operationInProgress: false, mayStart: false), .requestSwitch)
        XCTAssertEqual(QuickAccessAction.resolve(state: .connected, profileID: b, activeProfileID: nil, operationInProgress: false, mayStart: false), .blocked)
    }
    func testUnknownOwnershipAndRecoveryCannotStart() {
        let a = UUID()
        XCTAssertEqual(QuickAccessAction.resolve(state: .failed, profileID: a, activeProfileID: nil, operationInProgress: false, mayStart: false), .blocked)
        XCTAssertEqual(QuickAccessAction.resolve(state: .disconnected, profileID: a, activeProfileID: a, operationInProgress: false, mayStart: true), .blocked)
        XCTAssertEqual(QuickAccessAction.resolve(state: .disconnected, profileID: a, activeProfileID: nil, operationInProgress: false, mayStart: true), .connect)
    }
    func testBusyConnectingAuthenticatingAndStoppingAreBlocked() {
        let a = UUID()
        for state in [TunnelState.connecting, .authenticating, .reconnecting, .stopping] {
            XCTAssertEqual(QuickAccessAction.resolve(state: state, profileID: a, activeProfileID: nil, operationInProgress: false, mayStart: true), .blocked)
        }
        XCTAssertEqual(QuickAccessAction.resolve(state: .disconnected, profileID: a, activeProfileID: nil, operationInProgress: true, mayStart: true), .blocked)
    }
    func testSwitchConfirmationPinsAttemptEvenWhenProfileIsTheSame() {
        let profile = UUID(), attempt = UUID()
        let confirmation = QuickAccessSession(profileID: profile, attemptID: attempt)
        func report(attemptID: UUID, recovery: Bool = false) -> SessionReport {
            SessionReport(state: .connected, message: "", activeProfileID: profile,
                receivedBytes: nil, sentBytes: nil, attemptID: attemptID, networkRecoveryRequired: recovery)
        }
        XCTAssertTrue(confirmation.matches(report(attemptID: attempt)))
        XCTAssertFalse(confirmation.matches(report(attemptID: UUID())))
        XCTAssertTrue(confirmation.matches(report(attemptID: attempt, recovery: true)))
        XCTAssertFalse(confirmation.matches(SessionReport(state: .failed, message: "", activeProfileID: profile,
            receivedBytes: nil, sentBytes: nil, attemptID: attempt, networkRecoveryRequired: true)))
    }
}
