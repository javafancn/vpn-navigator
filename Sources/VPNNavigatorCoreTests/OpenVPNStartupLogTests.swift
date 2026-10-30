import XCTest
@testable import VPNNavigatorCore

final class OpenVPNStartupLogTests: XCTestCase {
    func testFragmentedStartupErrorWithoutFinalNewlineIsClassifiedAndRedacted() {
        var log = OpenVPNStartupLog()
        let text = "Options Error: unknown option /private/user-profile user=secret\r\n"
        for byte in text.utf8 { log.receive(Data([byte])) }
        XCTAssertEqual(log.failure, .configuration)
        XCTAssertFalse(log.failure!.summary.contains("user-profile"))
        XCTAssertFalse(log.failure!.summary.contains("secret"))
        var unterminated = OpenVPNStartupLog()
        unterminated.receive(Data("Cannot load certificate file /private/profile".utf8))
        XCTAssertNil(unterminated.failure)
        unterminated.finish()
        XCTAssertEqual(unterminated.failure, .certificate)
    }
    func testLongOrInvalidLinesAreDiscardedWithoutLosingFollowingErrors() {
        var log = OpenVPNStartupLog()
        log.receive(Data(repeating: 65, count: 200_000))
        log.receive(Data("Options Error: forged suffix\n".utf8))
        XCTAssertNil(log.failure)
        log.receive(Data([0xff, 0xfe, 10]))
        log.receive(Data("Cannot load private key file\n".utf8))
        XCTAssertEqual(log.failure, .certificate)
    }
    func testFirstCauseSurvivesGenericExitAndNoCertificateChecksAreRelaxed() {
        var log = OpenVPNStartupLog()
        log.receive(Data("OpenSSL: error: EE key too small\nExiting due to fatal error\n".utf8))
        XCTAssertEqual(log.failure, .certificate)
        for text in ["OpenSSL: CA md too weak", "OpenSSL: CA key too small"] {
            XCTAssertEqual(OpenVPNLogClassifier.classify(text), .certificate)
        }
        XCTAssertNil(OpenVPNLogClassifier.classify("OpenVPN 2.7.8 starting normally"))
    }
}
