import XCTest
@testable import VPNNavigatorCore

final class OpenVPNCommandTests: XCTestCase {
    func testLatencyTuningPreservesTransportAndExplicitTimeout() {
        let tcp = "proto tcp-client\nremote vpn.example 443"
        let udp = "proto udp\nremote vpn.example 1194"
        XCTAssertEqual(OpenVPNCommand.latencyArguments(for: tcp), ["--socket-flags", "TCP_NODELAY"])
        XCTAssertTrue(OpenVPNCommand.latencyArguments(for: tcp + "\nsocket-flags TCP_NODELAY").isEmpty)
        XCTAssertEqual(OpenVPNCommand.latencyArguments(for: udp), ["--sndbuf", "524288", "--rcvbuf", "524288"])
        XCTAssertEqual(OpenVPNCommand.latencyArguments(for: udp + "\nsndbuf 262144"), ["--rcvbuf", "524288"])
        XCTAssertTrue(OpenVPNCommand.latencyArguments(for: udp + "\nsndbuf 262144\nrcvbuf 262144").isEmpty)
        XCTAssertEqual(OpenVPNCommand.candidateTimeoutArguments(for: tcp, remainingSeconds: 60, candidateCount: 3), ["--server-poll-timeout", "10"])
        XCTAssertTrue(OpenVPNCommand.candidateTimeoutArguments(for: tcp + "\nconnect-timeout 30", remainingSeconds: 60, candidateCount: 3).isEmpty)
    }
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
