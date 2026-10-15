import Foundation
import Security

/// Build an OS-enforced designated-requirement for privileged XPC callers.
///
/// Do not validate clients by looking up their PID: another process could take
/// that PID after the lookup. macOS 13+ checks this requirement per connection.
enum PeerVerifier {
    static func clientRequirement() -> String? {
        var own: SecCode?
        var staticCode: SecStaticCode?
        guard SecCodeCopySelf([], &own) == errSecSuccess, let own,
              SecCodeCopyStaticCode(own, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
              let values = info as? [String: Any],
              let team = values[kSecCodeInfoTeamIdentifier as String] as? String,
              !team.isEmpty else { return nil }
        let requirement =
          "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and (identifier \"com.javafancn.vpn-navigator\" or identifier \"com.javafancn.vpn-navigator.rule-agent\")"
        var parsed: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &parsed) == errSecSuccess,
              parsed != nil else { return nil }
        return requirement
    }
}
