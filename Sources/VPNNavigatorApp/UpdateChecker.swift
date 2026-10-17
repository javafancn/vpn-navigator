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
        assets.first(where: {
            $0.name.lowercased().hasSuffix(".pkg") &&
            ReleaseAssetPolicy.isApprovedInstaller($0.browser_download_url)
        })?.browser_download_url
    }
}
enum UpdateChecker {
    /// Read-only GitHub release metadata check. Installation needs explicit user consent.
    static func latestRelease() async throws -> AvailableUpdate {
        let endpoint = URL(string: "https://api.github.com/repos/javafancn/vpn-navigator/releases/latest")!
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(AvailableUpdate.self, from: data)
    }
}
