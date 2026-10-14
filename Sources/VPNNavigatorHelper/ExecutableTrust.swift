import Foundation
import Security
import Darwin

/// The root daemon never executes a Homebrew binary or an executable from a
/// user-writable location. All bundled code must have the same Developer Team.
enum ExecutableTrust {
    static func trustedOpenVPN() throws -> URL {
        let bundle = Bundle.main.bundleURL.standardizedFileURL
        let binary = bundle.appendingPathComponent("Contents/Resources/openvpn")
        guard bundle.path.hasPrefix("/Applications/"),
              !bundle.path.contains("/../") else { throw TrustError.mustInstallToApplications }
        // A normal signed .app in ~/Downloads is NOT an acceptable root execution source.
        let protectedPaths = [
            URL(fileURLWithPath: "/Applications"),
            bundle,
            bundle.appendingPathComponent("Contents"),
            bundle.appendingPathComponent("Contents/Resources"),
            binary
        ]
        for path in protectedPaths {
            let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
            guard let uid = attributes[.ownerAccountID] as? NSNumber, uid.intValue == 0,
                  let permissions = attributes[.posixPermissions] as? NSNumber,
                  (permissions.intValue & 0o022) == 0,
                  path.resolvingSymlinksInPath() == path.standardizedFileURL
            else { throw TrustError.unsafePermissions(path.path) }
        }
        let executable = binary.path
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw TrustError.missing }
        var selfCode: SecCode?
        var staticSelf: SecStaticCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess,
              let selfCode,
              SecCodeCopyStaticCode(selfCode, [], &staticSelf) == errSecSuccess,
              let staticSelf else { throw TrustError.unsigned }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticSelf, [], &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let team = dict[kSecCodeInfoTeamIdentifier as String] as? String,
              !team.isEmpty else { throw TrustError.unsigned }

        var candidate: SecStaticCode?
        guard SecStaticCodeCreateWithPath(binary as CFURL, [], &candidate) == errSecSuccess,
              let candidate else { throw TrustError.unsigned }
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"com.javafancn.vpn-navigator.openvpn\""
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(candidate, [], requirement) == errSecSuccess
        else { throw TrustError.unsigned }
        return binary
    }
}
enum TrustError: Error, LocalizedError {
    case mustInstallToApplications, unsafePermissions(String), missing, unsigned
    var errorDescription: String? {
        switch self {
        case .mustInstallToApplications: return "Install the signed app into /Applications with the trusted installer."
        case .unsafePermissions(let path): return "Untrusted writable executable path: \(path)"
        case .missing: return "Bundled OpenVPN engine not installed."
        case .unsigned: return "OpenVPN binary signature or Team ID failed verification."
        }
    }
}
