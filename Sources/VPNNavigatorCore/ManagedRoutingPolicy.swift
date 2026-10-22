import Foundation

/// Enforces a single owner for routes in the app-controlled routing modes.
///
/// The OpenVPN server may still push network configuration: these settings
/// limit *expected* compatibility, not a security boundary against a hostile
/// server. A real firewall is needed to guarantee leak-free network behavior.
public enum ManagedRoutingPolicy {
    private static let blockedClientOptions: Set<String> = [
        "route", "route-ipv6", "redirect-gateway", "redirect-private"
    ]

    public static func validate(_ profile: ValidatedProfile, mode: RoutingMode) throws {
        guard mode != .original else { return }
        var insideInlineBlock = false
        for (offset, line) in profile.text.components(separatedBy: .newlines).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("<") && trimmed.hasSuffix(">") {
                if trimmed.hasPrefix("</") { insideInlineBlock = false }
                else { insideInlineBlock = true }
                continue
            }
            guard !insideInlineBlock,
                  !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix(";") else { continue }
            let tokens = try OpenVPNOptionLexer.tokens(trimmed)
            guard let directive = tokens.first else { continue }
            if blockedClientOptions.contains(String(directive)) {
                throw ManagedRoutingPolicyError.conflictingDirective(
                    line: offset + 1, option: String(directive))
            }
        }
    }

    /// Suppress conflicting server-pushed routes, but retain route-gateway and
    /// DHCP/DNS options needed for the tunnel and macOS resolver integration.
    ///
    /// Prefix "route " (with a space) is deliberate: "route" alone would
    /// also discard route-gateway. These filters are not a hostile-server
    /// isolation guarantee (OpenVPN's own manual warns about whitespace).
    public static func openVPNArguments(mode: RoutingMode) -> [String] {
        guard mode != .original else { return [] }
        let options = [
            "--pull-filter", "ignore", "redirect-gateway",
            "--pull-filter", "ignore", "redirect-private",
            "--pull-filter", "ignore", "route-ipv6",
            "--pull-filter", "ignore", "route ",
            "--route-noexec"
        ]
        return options
    }
}

public enum ManagedRoutingPolicyError: Error, Equatable, LocalizedError {
    case conflictingDirective(line: Int, option: String)

    public var errorDescription: String? {
        switch self {
        case .conflictingDirective(let line, let option):
            return "Managed routing cannot import '\(option)' on line \(line). Remove conflicting routes from the profile or use Original mode."
        }
    }
}

