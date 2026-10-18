import XCTest
import CryptoKit
@testable import VPNNavigatorCore

final class LocalApprovalTests: XCTestCase {
    private func approval(uid: UInt32 = 501, architecture: String = "arm64", version: String = "0.2.0") -> LocalApproval {
        let binaries = Dictionary(uniqueKeysWithValues: LocalRole.allCases.map {
            ($0.rawValue, LocalBinary(sha256: String(repeating: "a", count: 64), cdhash: String(repeating: "b", count: 40), identifier: $0.identifier))
        })
        return LocalApproval(version: version, architecture: architecture, ownerUID: uid, binaries: binaries, dnsSHA256: String(repeating: "c", count: 64), uninstallerSHA256: String(repeating: "d", count: 64))
    }
    func testApprovalRoundTripAndExactIdentityRequirement() throws {
        let value = approval(), decoded = try JSONDecoder().decode(LocalApproval.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(value, decoded)
        let requirement = try decoded.requirement(for: [.app, .agent])
        XCTAssertTrue(requirement.contains("cdhash H\"" + String(repeating: "b", count: 40)))
        XCTAssertTrue(requirement.contains(LocalRole.app.identifier))
        XCTAssertFalse(requirement.contains(LocalRole.setup.identifier))
        XCTAssertThrowsError(try decoded.requirement(for: []))
    }
    func testInvalidUserVersionAndArchitectureAreRejected() {
        for value in [approval(uid: 0), approval(uid: 499), approval(architecture: "universal"), approval(version: "0.2.0\nanything")] {
            XCTAssertThrowsError(try value.validate())
        }
    }
    func testUnexpectedRolesAndInjectedRequirementsAreRejected() throws {
        let data = try JSONEncoder().encode(approval())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var binaries = try XCTUnwrap(object["binaries"] as? [String: Any])
        binaries["arbitrary-root-command"] = binaries["app"]; object["binaries"] = binaries
        XCTAssertThrowsError(try JSONDecoder().decode(LocalApproval.self, from: JSONSerialization.data(withJSONObject: object)).validate())
        binaries.removeValue(forKey: "arbitrary-root-command")
        var app = try XCTUnwrap(binaries["app"] as? [String: Any]); app["cdhash"] = "x\" or anchor apple generic"
        binaries["app"] = app; object["binaries"] = binaries
        XCTAssertThrowsError(try JSONDecoder().decode(LocalApproval.self, from: JSONSerialization.data(withJSONObject: object)).validate())
    }
    func testHashingIsBoundedAndMatchesSHA256() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let content = Data(repeating: 0x42, count: 140_000); try content.write(to: path)
        XCTAssertEqual(try LocalInstallation.hash(path), SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined())
    }
}
