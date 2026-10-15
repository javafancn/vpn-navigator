import XCTest
@testable import VPNNavigatorCore

final class ProfileHistoryTests: XCTestCase {
    func testRevisionAndRestore() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sample = """
        client
        dev tun
        remote vpn.example.com 1194
        <ca>
        SAMPLE CERTIFICATE TEST DATA
        </ca>
        """
        let source = folder.appendingPathComponent("sample.ovpn")
        try sample.write(to: source, atomically: true, encoding: .utf8)
        let store = ProfileStore(root: folder.appendingPathComponent("profiles"))
        let profile = try await store.importProfile(from: source)
        let revised = sample.replacingOccurrences(of: "vpn.example.com", with: "backup.example.com")
        try await store.revise(profile, text: revised)
        XCTAssertEqual(try await store.original(for: profile), revised)
        let revisions = try await store.revisions(for: profile)
        XCTAssertEqual(revisions.count, 1)
        try await store.restore(profile, revision: revisions[0].filename)
        XCTAssertEqual(try await store.runtimeConfig(for: profile), sample)
        XCTAssertEqual(try await store.revisions(for: profile).count, 2)
    }

    func testRejectUnsafeRevisionAndTraversalRestore() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sample = "client\nremote vpn.example.com 1194\n<ca>\nCA\n</ca>"
        let source = folder.appendingPathComponent("sample.ovpn")
        try sample.write(to: source, atomically: true, encoding: .utf8)
        let store = ProfileStore(root: folder.appendingPathComponent("profiles"))
        let profile = try await store.importProfile(from: source)
        do {
            try await store.revise(profile, text: sample + "\nscript-security 3")
            XCTFail("Unsafe revision unexpectedly accepted")
        } catch {}
        XCTAssertEqual(try await store.original(for: profile), sample)
        do {
            try await store.restore(profile, revision: "../../evil.ovpn")
            XCTFail("Traversal unexpectedly accepted")
        } catch {}
    }
}
