import Foundation
import Security

enum InstallerUpdateError: Error, LocalizedError {
    case invalidURL, oversized, unauthenticated, signatureMismatch, gatekeeperRejected, downloadFailed
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Update URL is not an official VPN Navigator GitHub Release asset."
        case .oversized: return "Downloaded installer exceeds the size limit."
        case .unauthenticated: return "The current app has no trusted Developer ID Team."
        case .signatureMismatch: return "The installer is not signed by this application's Developer ID Team."
        case .gatekeeperRejected: return "macOS Gatekeeper did not approve the installer."
        case .downloadFailed: return "The update download was incomplete."
        }
    }
}

enum InstallerUpdate {
    /// Download and verify only. The system Installer handles user consent and
    /// privileged installation; this process never performs root file operations.
    static func prepare(_ url: URL) async throws -> URL {
        guard ReleaseAssetPolicy.isApprovedInstaller(url) else { throw InstallerUpdateError.invalidURL }
        let team = try signedTeamID()
        let (temporary, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw InstallerUpdateError.downloadFailed
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: temporary.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0, size <= 400_000_000 else { throw InstallerUpdateError.oversized }

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VPNNavigator/Updates", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let installer = support.appendingPathComponent("VPN-Navigator-verified.pkg")
        if FileManager.default.fileExists(atPath: installer.path) {
            try FileManager.default.removeItem(at: installer)
        }
        try FileManager.default.moveItem(at: temporary, to: installer)
        do {
            let signature = try run("/usr/sbin/pkgutil", ["--check-signature", installer.path])
            guard signature.contains("Developer ID Installer:"),
                  signature.contains("(\(team))") else {
                throw InstallerUpdateError.signatureMismatch
            }
            _ = try run("/usr/sbin/spctl",
                        ["--assess", "--type", "install", "--verbose=2", installer.path])
        } catch {
            try? FileManager.default.removeItem(at: installer)
            if error is InstallerUpdateError { throw error }
            throw InstallerUpdateError.gatekeeperRejected
        }
        return installer
    }

    private static func signedTeamID() throws -> String {
        var own: SecCode?
        var code: SecStaticCode?
        guard SecCodeCopySelf([], &own) == errSecSuccess, let own,
              SecCodeCopyStaticCode(own, [], &code) == errSecSuccess, let code else {
            throw InstallerUpdateError.unauthenticated
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
              let values = info as? [String: Any],
              let team = values[kSecCodeInfoTeamIdentifier as String] as? String,
              !team.isEmpty else { throw InstallerUpdateError.unauthenticated }
        return team
    }
    private static func run(_ executable: String, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw InstallerUpdateError.gatekeeperRejected }
        return String(decoding: output, as: UTF8.self)
    }
}
