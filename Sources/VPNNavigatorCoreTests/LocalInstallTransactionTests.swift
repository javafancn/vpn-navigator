import XCTest
@testable import VPNNavigatorCore

final class LocalInstallTransactionTests: XCTestCase {
    func testAllPersistedPhasesRoundTrip() throws {
        for phase in [LocalInstallTransaction.Phase.preparing, .verifying, .repairRequired] {
            let value = LocalInstallTransaction(version: "0.3.2", architecture: "arm64", phase: phase)
            try value.validate()
            XCTAssertEqual(try JSONDecoder().decode(LocalInstallTransaction.self, from: JSONEncoder().encode(value)), value)
            XCTAssertFalse(value.summary.isEmpty)
        }
    }
    func testRepairHandoffRequiresExactAppVersionAndArchitecture() {
        let value = LocalInstallTransaction(version: "0.3.2", architecture: "arm64", phase: .repairRequired)
        XCTAssertTrue(value.matches(version: "0.3.2", architecture: "arm64"))
        XCTAssertFalse(value.matches(version: "0.3.1", architecture: "arm64"))
        XCTAssertFalse(value.matches(version: "0.3.2", architecture: "x86_64"))
    }
    func testMalformedRecordsCannotAuthorizeRepair() throws {
        for json in [
            #"{"schema":2,"version":"0.3.2","architecture":"arm64","phase":"preparing"}"#,
            #"{"schema":1,"version":"0.3.2\ncommand","architecture":"arm64","phase":"preparing"}"#,
            #"{"schema":1,"version":"0.3.2","architecture":"universal","phase":"preparing"}"#,
            #"{"schema":1,"version":"0.3.2","architecture":"arm64","phase":"complete"}"#
        ] {
            XCTAssertThrowsError(try JSONDecoder().decode(LocalInstallTransaction.self, from: Data(json.utf8)).validate())
        }
    }
}
