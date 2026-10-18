import XCTest
@testable import VPNNavigatorCore

final class ManagementAuthenticationTests: XCTestCase {
    private let need = ">PASSWORD:Need 'Auth' username/password"
    private func challenge(_ state: String = "opaque-state", flags: String = "R,E", user: String = "Y3Ix", prompt: String = "Token: PIN") -> String {
        ">PASSWORD:Verification Failed: 'Auth' ['CRV1:\(flags):\(state):\(user):\(prompt)']"
    }
    private func presentation(_ event: ManagementAuthentication.Event?) throws -> AuthenticationChallenge {
        guard case .challenge(let value) = event else { XCTFail("Expected challenge"); throw ChallengeResponseError.invalid }
        return value
    }
    func testDynamicWaitsForNextRequestAndUsesDecodedUsername() throws {
        var flow = ManagementAuthentication()
        flow.setCredentials(username: "account", password: "must-not-reuse")
        XCTAssertNil(flow.receive(challenge()))
        XCTAssertThrowsError(try flow.respond(id: UUID().uuidString, response: "123"))
        let retry = try XCTUnwrap(ManagementParser.parseState(">STATE:1,RECONNECTING,auth-failure,,,,"))
        XCTAssertEqual(flow.transition(retry).state, .authenticating)
        let value = try presentation(flow.receive(need))
        XCTAssertEqual(value.kind, .dynamicOTP)
        XCTAssertEqual(value.prompt, "Token: PIN")
        XCTAssertEqual(try flow.respond(id: value.id.uuidString, response: "8675309"),
                       ["username \"Auth\" \"cr1\"", "password \"Auth\" \"CRV1::opaque-state::8675309\""])
        XCTAssertThrowsError(try flow.respond(id: value.id.uuidString, response: "stale"))
        XCTAssertEqual(flow.transition(retry).state, .reconnecting)
    }
    func testNoResponseFlagRequiresExplicitEmptyAcknowledgement() throws {
        var flow = ManagementAuthentication()
        XCTAssertNil(flow.receive(challenge(flags: "", prompt: "Approve on device")))
        let value = try presentation(flow.receive(need))
        XCTAssertFalse(value.responseRequired)
        XCTAssertThrowsError(try flow.respond(id: value.id.uuidString, response: "unrequested"))
        XCTAssertEqual(try flow.respond(id: value.id.uuidString, response: "").last,
                       "password \"Auth\" \"CRV1::opaque-state::\"")
    }
    func testOpaqueStateAndResponseAreEscapedWithoutInterpretation() throws {
        var flow = ManagementAuthentication()
        XCTAssertNil(flow.receive(challenge("a\"b\\c")))
        let value = try presentation(flow.receive(need))
        XCTAssertEqual(try flow.respond(id: value.id.uuidString, response: "x\"y\\z").last,
                       "password \"Auth\" \"CRV1::a\\\"b\\\\c::x\\\"y\\\\z\"")
    }
    func testChallengeContextIsNotIncludedInSessionReport() throws {
        var flow = ManagementAuthentication()
        _ = flow.receive(challenge("private-state-identifier"))
        let value = try presentation(flow.receive(need))
        let report = SessionReport(state: .authenticating, message: "", activeProfileID: nil,
                                   receivedBytes: nil, sentBytes: nil, challenge: value)
        let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        XCTAssertFalse(json.contains("private-state-identifier"))
        XCTAssertFalse(json.contains("Y3Ix"))
        XCTAssertEqual(try JSONDecoder().decode(SessionReport.self, from: Data(json.utf8)), report)
    }
    func testMalformedFailuresNeverReuseSavedPassword() {
        for line in [challenge(flags: "R,X"), challenge(flags: "R,R"), challenge(""),
                     challenge(user: "!!!!"), challenge(user: "Cg=="), challenge(prompt: "bad\ntext"),
                     challenge(String(repeating: "s", count: 513)), challenge(user: "/w=="),
                     ">PASSWORD:Verification Failed: 'Auth' ['not-a-challenge']"] {
            var flow = ManagementAuthentication(); flow.setCredentials(username: "x", password: "secret")
            guard case .failed = flow.receive(line) else { return XCTFail("Malformed challenge accepted") }
        }
    }
    func testReplacedChallengeInvalidatesOldResponseAndRoundsAreBounded() throws {
        var flow = ManagementAuthentication()
        _ = flow.receive(challenge("a")); let old = try presentation(flow.receive(need))
        _ = flow.receive(challenge("b")); let next = try presentation(flow.receive(need))
        XCTAssertNotEqual(old.id, next.id)
        XCTAssertThrowsError(try flow.respond(id: old.id.uuidString, response: "stale"))
        _ = try flow.respond(id: next.id.uuidString, response: "ok")
        XCTAssertNil(flow.receive(challenge("c")))
        guard case .failed = flow.receive(challenge("d")) else { return XCTFail("Unbounded retries") }
    }
    func testEstablishedTunnelNeverBypassesManagedReconnectPolicy() throws {
        var flow = ManagementAuthentication()
        _ = flow.transition(try XCTUnwrap(ManagementParser.parseState(">STATE:1,CONNECTED,SUCCESS,10.8.0.2,1.2.3.4")))
        guard case .failed = flow.receive(challenge()) else { return XCTFail("Post-connect challenge accepted") }
        let retry = try XCTUnwrap(ManagementParser.parseState(">STATE:2,RECONNECTING,auth-failure,,,,"))
        XCTAssertEqual(flow.transition(retry).state, .reconnecting)
    }
    func testTransportFailureIsNeverMappedToAuthentication() throws {
        var flow = ManagementAuthentication(); _ = flow.receive(challenge())
        for reason in ["tls-error", "connection-reset", "ping-restart"] {
            let retry = try XCTUnwrap(ManagementParser.parseState(">STATE:1,RECONNECTING,\(reason),,,,"))
            XCTAssertEqual(flow.transition(retry).state, .reconnecting)
        }
    }
    func testLegacyFailureEnvelopeAndControlCharacterResponses() throws {
        var flow = ManagementAuthentication()
        _ = flow.receive(challenge().replacingOccurrences(of: "Failed: 'Auth' [", with: "Failed: ["))
        let value = try presentation(flow.receive(need))
        for response in ["", "x\npassword Auth evil", "x\u{2028}y", String(repeating: "x", count: 1025)] {
            XCTAssertThrowsError(try flow.respond(id: value.id.uuidString, response: response))
        }
    }
    func testStaticConcatenationFlagEscapesCombinedValue() throws {
        for flag in ["2", "3"] {
            var flow = ManagementAuthentication(); flow.setCredentials(username: "foo", password: "a\"b\\c")
            let value = try presentation(flow.receive(need + " SC:\(flag),PIN"))
            XCTAssertEqual(try flow.respond(id: value.id.uuidString, response: "123"),
                           ["username \"Auth\" \"foo\"", "password \"Auth\" \"a\\\"b\\\\c123\""])
        }
    }
    func testExpectedDynamicExchangeDoesNotRecordAFalseFailure() {
        XCTAssertNil(OpenVPNLogClassifier.classify("AUTH: Received control message: AUTH_FAILED,CRV1:R:state:Y3Ix:PIN"))
        XCTAssertEqual(OpenVPNLogClassifier.classify("AUTH_FAILED: bad credentials"), .authentication)
    }
    func testOldChallengePayloadUsesSafeDefaults() throws {
        let json = "{\"id\":\"\(UUID().uuidString)\",\"kind\":\"staticOTP\",\"prompt\":\"PIN\"}"
        let value = try JSONDecoder().decode(AuthenticationChallenge.self, from: Data(json.utf8))
        XCTAssertTrue(value.responseRequired); XCTAssertFalse(value.concatenatePassword)
    }
}
