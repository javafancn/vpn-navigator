import Foundation
import Security

/// The compile-time channel selects either administrator-approved local code
/// hashes or the existing Developer ID Team requirement. No runtime fallback.
public enum PrivilegedServiceTrust {
    public static func helperRequirement() -> String? {
        if BuildChannel.isLocal {
            guard let approval = try? LocalInstallation.load(),
                  LocalInstallation.selfMatches([.app, .agent, .setup], approval: approval) else { return nil }
            return try? approval.requirement(for: [.helper])
        }
        guard let team = ProcessSigningIdentity.current?.team,
              !team.isEmpty else { return nil }
        let requirement =
            "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"com.javafancn.vpn-navigator.helper\""
        var parsed: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &parsed) == errSecSuccess,
              parsed != nil else { return nil }
        return requirement
    }
}

