import Foundation
import VPNNavigatorCore

struct GitHubReleaseAsset: Decodable {
    let name: String
    let browser_download_url: URL
}
struct AvailableUpdate: Decodable {
    let tag_name: String
    let html_url: URL
    let assets: [GitHubReleaseAsset]

    var trustedInstallerURL: URL? {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        return assets.first(where: {
            ReleaseAssetPolicy.supportsArchitecture($0.name, architecture: architecture) &&
            ReleaseAssetPolicy.isApprovedInstaller($0.browser_download_url)
        })?.browser_download_url
    }
}
enum UpdateChecker {
    /// Read-only GitHub release metadata check. Installation needs explicit user consent.
    static func latestRelease() async throws -> AvailableUpdate {
        let endpoint = URL(string: "https://api.github.com/repos/javafancn/vpn-navigator/releases/latest")!
        let data: Data
        do {
            data = try await BoundedDownload.data(from: endpoint, maximumBytes: 2_000_000,
                allowedHosts: ["api.github.com"], timeout: 20)
        } catch BoundedDownload.Failure.httpStatus(404) {
            throw UpdateCheckError.noRelease
        }
        return try JSONDecoder().decode(AvailableUpdate.self, from: data)
    }
}


enum UpdateCheckError: Error, LocalizedError {
    case noRelease
    var errorDescription: String? { L10n.text("项目尚未提供正式 Release 安装包。") }
}
