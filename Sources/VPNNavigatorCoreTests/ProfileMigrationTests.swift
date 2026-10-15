import XCTest
@testable import VPNNavigatorCore

final class ProfileMigrationTests: XCTestCase {
    func testOlderProfileIndexReadsWithNewMetadataDefaults() throws {
        let id = UUID()
        let old = VPNProfile(id: id, name: "Work", sourceFilename: "work.ovpn",
                             relativePath: "\(id.uuidString).ovpn")
        let encoded = try JSONEncoder().encode(old)
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        value.removeValue(forKey: "group")
        value.removeValue(forKey: "notes")
        value.removeValue(forKey: "isFavorite")
        let legacy = try JSONSerialization.data(withJSONObject: value)
        let decoded = try JSONDecoder().decode(VPNProfile.self, from: legacy)
        XCTAssertEqual(decoded.name, "Work")
        XCTAssertEqual(decoded.group, "Personal")
        XCTAssertEqual(decoded.notes, "")
        XCTAssertFalse(decoded.isFavorite)
        XCTAssertEqual(decoded.id, id)
    }
    func testRoundTripMetadata() throws {
        let profile = VPNProfile(name: "Tokyo", sourceFilename: "tokyo.ovpn",
                                 relativePath: "test.ovpn", group: "Travel",
                                 notes: "Backup location", isFavorite: true)
        let decoded = try JSONDecoder().decode(VPNProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(profile, decoded)
    }
}
