import Foundation

struct AvailableUpdate: Decodable {
    let tag_name: String
    let html_url: URL
}
enum UpdateChecker {
    /// Read-only check; the app does not execute downloaded code or silently update root services.
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
