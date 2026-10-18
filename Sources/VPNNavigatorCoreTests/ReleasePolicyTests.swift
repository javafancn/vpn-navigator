import XCTest
@testable import VPNNavigatorCore

final class ReleasePolicyTests: XCTestCase {
    func testUpdaterDoesNotSelectTheOtherArchitecture() {
        XCTAssertTrue(ReleaseAssetPolicy.supportsArchitecture("VPN-Navigator-0.1.0-arm64.pkg", architecture: "arm64"))
        XCTAssertFalse(ReleaseAssetPolicy.supportsArchitecture("VPN-Navigator-0.1.0-arm64.pkg", architecture: "x86_64"))
        XCTAssertTrue(ReleaseAssetPolicy.supportsArchitecture("VPN-Navigator-0.1.0-x86_64.pkg", architecture: "x86_64"))
        XCTAssertFalse(ReleaseAssetPolicy.supportsArchitecture("VPN-Navigator-0.1.0-x86_64.pkg", architecture: "arm64"))
        XCTAssertTrue(ReleaseAssetPolicy.supportsArchitecture("VPN-Navigator-0.1.0-Universal.pkg", architecture: "arm64"))
    }
    func testLocalAndUninstallPackagesCannotEnterSignedUpdater() {
        for name in ["VPN-Navigator-arm64-Local.pkg", "VPN-Navigator-Local-Uninstall.pkg", "VPN-Navigator-uninstall.pkg"] {
            XCTAssertFalse(ReleaseAssetPolicy.isApprovedInstaller(URL(string: "https://github.com/javafancn/vpn-navigator/releases/download/v0.2.0/" + name)!))
        }
    }
    func testStableVersionsAndSorting() throws {
        XCTAssertEqual(ReleaseVersion("v1.2.3"), ReleaseVersion("1.2.3"))
        XCTAssertTrue(try XCTUnwrap(ReleaseVersion("1.3.0")) > XCTUnwrap(ReleaseVersion("1.2.9")))
        XCTAssertNil(ReleaseVersion("1.2.3-beta"))
        XCTAssertNil(ReleaseVersion("1.2"))
        XCTAssertNil(ReleaseVersion("v1.2.x"))
    }
    func testOnlyOfficialGitHubReleasePagesAndAssets() {
        XCTAssertTrue(ReleaseAssetPolicy.isApprovedInstaller(URL(string:
            "https://github.com/javafancn/vpn-navigator/releases/download/v1.0.0/VPN-Navigator.pkg")!))
        XCTAssertFalse(ReleaseAssetPolicy.isApprovedInstaller(URL(string:
            "https://evil.example/releases/download/v1.0.0/VPN-Navigator.pkg")!))
        XCTAssertFalse(ReleaseAssetPolicy.isApprovedInstaller(URL(string:
            "https://github.com/javafancn/other/releases/download/v1.0.0/VPN-Navigator.pkg")!))
        XCTAssertFalse(ReleaseAssetPolicy.isApprovedInstaller(URL(string:
            "http://github.com/javafancn/vpn-navigator/releases/download/v1.0.0/VPN-Navigator.pkg")!))
        XCTAssertTrue(ReleaseAssetPolicy.isApprovedReleasePage(URL(string:
            "https://github.com/javafancn/vpn-navigator/releases/tag/v1.0.0")!))
    }
}

