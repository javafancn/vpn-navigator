import Foundation
import Security

/// Never grant root privileges to unsigned or differently signed clients.
/// The signed daemon and app must share a Developer ID Team and the expected bundle id.
enum PeerVerifier {
    static func allows(_ connection: NSXPCConnection) -> Bool {
        var own: SecCode?
        guard SecCodeCopySelf([], &own) == errSecSuccess, let own else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(own, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let team = dict[kSecCodeInfoTeamIdentifier as String] as? String,
              !team.isEmpty else { return false }

        var peer: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: connection.processIdentifier)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &peer) == errSecSuccess,
              let peer else { return false }

        let requirementText = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"com.javafancn.vpn-navigator\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecCodeCheckValidity(peer, [], requirement) == errSecSuccess
    }
}
