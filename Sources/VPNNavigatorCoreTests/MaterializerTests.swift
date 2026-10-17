import XCTest
@testable import VPNNavigatorCore

final class MaterializerTests: XCTestCase {
    func testRelativeCertificateBecomesInline() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "TEST-CA".write(to: root.appendingPathComponent("ca.crt"), atomically: true, encoding: .utf8)
        let text = "client\nremote vpn.example 1194\ndev tun\nca ca.crt\nauth-user-pass user.txt"
        let output = try ProfileMaterializer.materialize(text: text, directory: root)
        XCTAssertTrue(output.contains("<ca>\nTEST-CA\n</ca>"))
        XCTAssertTrue(output.contains("auth-user-pass"))
        XCTAssertFalse(output.contains("user.txt"))
        XCTAssertNoThrow(try ProfileSafety.validate(output))
    }
    func testRejectTraversal() throws {
        let root = FileManager.default.temporaryDirectory
        XCTAssertThrowsError(try ProfileMaterializer.materialize(text: "ca ../secrets.key", directory: root))
        XCTAssertThrowsError(try ProfileMaterializer.materialize(text: "ca /etc/passwd", directory: root))
    }
}
