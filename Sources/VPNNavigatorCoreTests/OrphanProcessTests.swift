import XCTest
@testable import VPNNavigatorCore

final class OrphanProcessTests: XCTestCase {
    func testRecordIsTypedAndRoundTrips() throws {
        let record = try OrphanProcessRecord(pid: 72345)
        let restored = try JSONDecoder().decode(OrphanProcessRecord.self,
                                                 from: JSONEncoder().encode(record))
        XCTAssertEqual(restored, record)
        XCTAssertThrowsError(try OrphanProcessRecord(pid: 0))
        XCTAssertThrowsError(try OrphanProcessRecord(pid: -4))
    }
    func testRecoveryOnlyOnConfirmedAbsentPID() {
        XCTAssertFalse(OrphanProcessRecovery.canClearStaleMarker(
            pidRecordPresent: false, pidConfirmedAbsent: true))
        XCTAssertFalse(OrphanProcessRecovery.canClearStaleMarker(
            pidRecordPresent: true, pidConfirmedAbsent: false))
        XCTAssertTrue(OrphanProcessRecovery.canClearStaleMarker(
            pidRecordPresent: true, pidConfirmedAbsent: true))
    }
}
