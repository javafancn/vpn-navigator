import Foundation
import Security

/// The privileged launchd executable lives at:
/// /Applications/VPN Navigator.app/Contents/Resources/VPNNavigatorHelper
/// It is a *tool*, not an app bundle: Bundle.main.bundleURL is not the .app root.
enum ExecutableTrust {
    static func trustedOpenVPN() throws -> URL {
        guard let executable = Bundle.main.executableURL?.standardizedFileURL.resolvingSymlinksInPath() else {
            throw TrustError.mustInstallToApplications
        }
        let resources = executable.deletingLastPathComponent()
        let contents = resources.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard resources.lastPathComponent == "Resources",
              contents.lastPathComponent == "Contents",
              app.lastPathComponent == "VPN Navigator.app",
              app.deletingLastPathComponent().path == "/Applications",
              executable.lastPathComponent == "VPNNavigatorHelper" else {
            throw TrustError.mustInstallToApplications
        }
        let binary = resources.appendingPathComponent("openvpn")
        let protectedPaths = [
            URL(fileURLWithPath: "/Applications"),
            app, contents, resources, executable, binary
        ]
        for path in protectedPaths {
            let canonical = path.standardizedFileURL
            guard canonical.resolvingSymlinksInPath() == canonical,
                  let attrs = try? FileManager.default.attributesOfItem(atPath: canonical.path),
                  let owner = attrs[.ownerAccountID] as? NSNumber,
                  let mode = attrs[.posixPermissions] as? NSNumber,
                  owner.intValue == 0, mode.intValue & 0o022 == 0 else {
                throw TrustError.unsafePermissions(path.path)
            }
        }
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw TrustError.missing
        }

        // Both binaries must be signed by the same Developer Team, and the
        // OpenVPN executable must have the exact designated identifier.
        var ownCode: SecCode?
        var ownStatic: SecStaticCode?
        guard SecCodeCopySelf([], &ownCode) == errSecSuccess, let ownCode,
              SecCodeCopyStaticCode(ownCode, [], &ownStatic) == errSecSuccess,
              let ownStatic else { throw TrustError.unsigned }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(ownStatic, [], &info) == errSecSuccess,
              let values = info as? [String: Any],
              let team = values[kSecCodeInfoTeamIdentifier as String] as? String,
              !team.isEmpty else { throw TrustError.unsigned }

        var candidate: SecStaticCode?
        guard SecStaticCodeCreateWithPath(binary as CFURL, [], &candidate) == errSecSuccess,
              let candidate else { throw TrustError.unsigned }
        let codeRequirement = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"com.javafancn.vpn-navigator.openvpn\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(codeRequirement as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(candidate, [], requirement) == errSecSuccess else {
            throw TrustError.unsigned
        }
        return binary
    }
}

enum TrustError: Error, LocalizedError {
    case mustInstallToApplications, unsafePermissions(String), missing, unsigned
    var errorDescription: String? {
        switch self {
        case .mustInstallToApplications:
            return "Install the notarized app under /Applications using its signed installer."
        case .unsafePermissions(let path):
            return "The executable or its parent directory is not protected: \(path)"
        case .missing:
            return "Bundled OpenVPN CLI is missing."
        case .unsigned:
            return "The OpenVPN binary does not satisfy the required code signature."
        }
    }
}
