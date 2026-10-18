import XCTest
@testable import VPNNavigatorCore

final class OpenVPNCommandTests: XCTestCase {
    func testInstalledPathsRemainOneExecutableAfterCommandParsing() throws {
        for path in [
            "/Library/Application Support/VPNNavigator/Local/Payload/macos-dns-updown.sh",
            "/Applications/VPN Navigator.app/Contents/Resources/macos-dns-updown.sh"
        ] {
            XCTAssertEqual(try OpenVPNOptionLexer.tokens(OpenVPNCommand.quotedExecutable(path)), [path])
        }
    }
    func testQuotesBackslashesAndMetacharactersStayLiteral() throws {
        let path = "/tmp/a \"quoted\" \\ folder/$literal;script.sh"
        XCTAssertEqual(try OpenVPNOptionLexer.tokens(OpenVPNCommand.quotedExecutable(path)), [path])
    }
    func testInvalidExecutablePathsAreRejected() {
        for path in ["", "relative/script", "/tmp/line\nbreak", "/tmp/nul\0byte", "/tmp/carriage\rreturn"] {
            XCTAssertThrowsError(try OpenVPNCommand.quotedExecutable(path))
        }
    }
}
