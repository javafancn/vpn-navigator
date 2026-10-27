import XCTest
@testable import VPNNavigatorCore

final class ProfileCompatibilityTests: XCTestCase {
    // Entirely synthetic; no uploaded endpoints, names, keys or certificates.
    private let base = "client\ndev tun\nproto udp\nremote fixture.example 1194\nauth-user-pass\n<ca>\nSYNTHETIC_CA\n</ca>\n"
    private let hints = "ignore-unknown-option block-outside-dns\nsetenv opt block-outside-dns # Windows-only DNS hint\n"

    func testCrossPlatformHintsPreserveValidatedProfileAndCredentials() throws {
        let text = base + hints
        let validated = try ProfileSafety.validate(text)
        XCTAssertEqual(validated.text, text)
        XCTAssertEqual(validated.remoteHosts, ["fixture.example"])
        XCTAssertTrue(validated.requestsCredentials)
    }

    func testEachOptionalHintCanAppearIndependently() throws {
        for hint in ["ignore-unknown-option block-outside-dns", "setenv opt block-outside-dns"] {
            XCTAssertNoThrow(try ProfileSafety.validate(base + hint))
        }
    }

    func testQuotedTargetsWhitespaceAndInlineCommentsKeepOriginalText() throws {
        let text = base + "  ignore-unknown-option \"block-outside-dns\" ; compatibility\n\tsetenv opt 'block-outside-dns' # compatibility\n"
        XCTAssertEqual(try ProfileSafety.validate(text).text, text)
    }

    func testIgnoreListCannotBroadenSafetyPolicy() {
        for directive in ["ignore-unknown-option", "ignore-unknown-option up",
                          "ignore-unknown-option block-outside-dns up",
                          "ignore-unknown-option block-outside-dns management",
                          "ignore-unknown-option --block-outside-dns"] {
            XCTAssertThrowsError(try ProfileSafety.validate(base + directive), directive)
        }
    }

    func testArbitraryEnvironmentAndOptionalWrappersRemainBlocked() {
        for directive in ["setenv FORWARD_COMPATIBLE 1", "setenv LD_PRELOAD /tmp/injected.so",
                          "setenv opt up /tmp/injected.sh", "setenv opt route-noexec",
                          "setenv opt management 127.0.0.1 9999",
                          "setenv opt block-outside-dns extra", "setenv opt block-outside-dns;up"] {
            XCTAssertThrowsError(try ProfileSafety.validate(base + directive), directive)
        }
    }

    func testLaterUnsafeDirectiveIsStillRejectedAtOriginalLine() {
        let text = base + hints + "up /tmp/injected.sh"
        let line = text.components(separatedBy: .newlines).count
        XCTAssertThrowsError(try ProfileSafety.validate(text)) { error in
            XCTAssertEqual(error as? ProfileValidationError, .unsupported(line, "up /tmp/injected.sh"))
        }
    }

    func testMandatoryWindowsOnlyOptionIsNotSilentlyDropped() {
        XCTAssertThrowsError(try ProfileSafety.validate(base + "block-outside-dns"))
    }

    func testImportAndPortableExportKeepOriginalCompatibilityHints() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = base + hints, source = root.appendingPathComponent("synthetic.ovpn")
        try text.write(to: source, atomically: true, encoding: .utf8)
        let store = ProfileStore(root: root.appendingPathComponent("Profiles"))
        let profile = try await store.importProfile(from: source)
        let original = try await store.original(for: profile)
        let runtime = try await store.runtimeConfig(for: profile)
        let portable = try ProfileExport.render(runtime: runtime, kind: .portable, mode: .original, rules: nil)
        XCTAssertEqual(original, text)
        XCTAssertEqual(try String(contentsOf: source), text)
        XCTAssertEqual(try ProfileSafety.validate(runtime).text, runtime)
        XCTAssertEqual(String(decoding: portable, as: UTF8.self), text)
    }
}
