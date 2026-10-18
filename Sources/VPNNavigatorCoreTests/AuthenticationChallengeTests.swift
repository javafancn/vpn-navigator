import XCTest
@testable import VPNNavigatorCore

final class AuthenticationChallengeTests: XCTestCase {
    func testStaticChallengeDoesNotFallBackToPlainPassword() throws {
        let challenge = try XCTUnwrap(AuthenticationChallenge.parse(">PASSWORD:Need 'Auth' username/password SC:1,Token PIN"))
        XCTAssertEqual(challenge.kind, .staticOTP)
        XCTAssertEqual(try challenge.responseCommand(response: "8675309", accountPassword: "bar"),
                       "password \"Auth\" \"SCRV1:YmFy:ODY3NTMwOQ==\"")
        XCTAssertThrowsError(try challenge.responseCommand(response: "123\npassword Auth evil", accountPassword: "bar"))
        XCTAssertThrowsError(try challenge.responseCommand(response: "123", accountPassword: ""))
    }
    func testPrivateKeyPasswordEscapesManagementSyntax() throws {
        let challenge = try XCTUnwrap(AuthenticationChallenge.parse(">PASSWORD:Need 'Private Key' password"))
        XCTAssertEqual(challenge.kind, .privateKey)
        XCTAssertEqual(try challenge.responseCommand(response: "a\"b\\c", accountPassword: ""),
                       "password \"Private Key\" \"a\\\"b\\\\c\"")
    }
    func testUnknownOrMaliciousChallengesAreRejected() {
        XCTAssertNil(AuthenticationChallenge.parse(">PASSWORD:Need 'HTTP Proxy' username/password"))
        XCTAssertNil(AuthenticationChallenge.parse(">PASSWORD:Need 'Auth' username/password SC:4,unsupported format"))
        XCTAssertNil(AuthenticationChallenge.parse(">PASSWORD:Need 'Auth' username/password SC:1,bad\ntext"))
        XCTAssertNil(AuthenticationChallenge.parse(">PASSWORD:Need 'Auth' username/password SC:1,"))
        XCTAssertNil(AuthenticationChallenge.parse(">PASSWORD:Need 'Auth' username/password"))
    }
    func testChallengeIsScopedToAnAttempt() throws {
        let a = AuthenticationChallenge(kind: .privateKey, prompt: "Unlock")
        let b = AuthenticationChallenge(kind: .privateKey, prompt: "Unlock")
        XCTAssertNotEqual(a.id, b.id)
        let report = SessionReport(state: .authenticating, message: "", activeProfileID: nil,
                                   receivedBytes: nil, sentBytes: nil, challenge: a)
        XCTAssertEqual(try JSONDecoder().decode(SessionReport.self, from: JSONEncoder().encode(report)).challenge, a)
    }
}
