import Foundation
import Security

/// A connection to the root service is only permitted when the client has
/// a real Apple Developer Team, and the server code matches the bundled
/// helper's exact signing identifier.
public enum PrivilegedServiceTrust {
    public static func helperRequirement() -> String? {
        if BuildChannel.isLocal {
            guard let approval = try? LocalInstallation.load(),
                  LocalInstallation.selfMatches([.app, .agent, .setup], approval: approval) else { return nil }
            return try? approval.requirement(for: [.helper])
        }
        var selfCode: SecCode?
        var staticCode: SecStaticCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode,
              SecCodeCopyStaticCode(selfCode, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
              let values = info as? [String: Any],
              let team = values[kSecCodeInfoTeamIdentifier as String] as? String,
              !team.isEmpty else { return nil }
        let requirement =
            "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"com.javafancn.vpn-navigator.helper\""
        var parsed: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &parsed) == errSecSuccess,
              parsed != nil else { return nil }
        return requirement
    }
}

