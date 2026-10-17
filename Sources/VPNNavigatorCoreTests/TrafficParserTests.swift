import XCTest
@testable import VPNNavigatorCore

final class TrafficParserTests: XCTestCase {
    func testOpenVPNClientTrafficFormat() {
        XCTAssertEqual(
            ManagementParser.parseByteCount(">BYTECOUNT:1024,2048"),
            TunnelTraffic(receivedBytes: 1024, sentBytes: 2048))
        XCTAssertEqual(
            ManagementParser.parseByteCount(">BYTECOUNT:18446744073709551615,0")?.receivedBytes,
            UInt64.max)
    }
    func testMalformedAndServerBytecountNeverAccepted() {
        for line in [
            ">BYTECOUNT_CLI:4,12,23", ">BYTECOUNT:-1,42",
            ">BYTECOUNT:1", ">BYTECOUNT:1,2,3",
            ">BYTECOUNT:1,garbage", "BYTECOUNT:12,14",
            ">BYTECOUNT:18446744073709551616,0"
        ] { XCTAssertNil(ManagementParser.parseByteCount(line), "Unexpectedly accepted \(line)") }
    }
}
