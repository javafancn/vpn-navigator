import XCTest
@testable import VPNNavigatorCore

final class OpenVPNCommandTests: XCTestCase {
    func testDNSHookUsesOneWhitespaceFreeFilenameAndItsTrustedDirectory() throws {
        for path in [
            "/Library/Application Support/VPNNavigator/Local/Payload/macos-dns-updown.sh",
            "/Applications/VPN Navigator.app/Contents/Resources/macos-dns-updown.sh",
            "/tmp/parent \"with quotes\"/$literal;folder/macos-dns-updown.sh"
        ] {
            let launch = try OpenVPNCommand.dnsUpDownInvocation(path)
            XCTAssertEqual(launch.directory.appendingPathComponent("macos-dns-updown.sh").path, path)
            XCTAssertEqual(try OpenVPNOptionLexer.tokens(launch.executable), [launch.executable])
            XCTAssertFalse(launch.executable.contains(" "))
            XCTAssertTrue(launch.executable.hasPrefix("./"))
        }
        for path in ["relative/macos-dns-updown.sh", "/tmp/other.sh", "/tmp/line\nbreak/macos-dns-updown.sh"] {
            XCTAssertThrowsError(try OpenVPNCommand.dnsUpDownInvocation(path))
        }
    }
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
