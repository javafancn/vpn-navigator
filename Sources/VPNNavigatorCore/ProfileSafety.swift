import Foundation

/// Reject unsafe or unsupported OpenVPN commands BEFORE passing a profile to a privileged process.
/// This is a strict, intentionally incomplete compatibility profile: denial is safer than guessing.
public enum ProfileSafety {
    private static let allowed: Set<String> = [
        "client", "tls-client", "dev", "dev-type", "proto", "remote", "remote-random",
        "resolv-retry", "nobind", "persist-key", "persist-tun", "auth", "cipher",
        "data-ciphers", "data-ciphers-fallback", "remote-cert-tls", "verb", "mute",
        "mute-replay-warnings", "auth-nocache", "tls-version-min", "tls-cipher",
        "tls-ciphersuites", "key-direction", "auth-user-pass", "reneg-sec",
        "explicit-exit-notify", "push-peer-info", "connect-retry", "connect-timeout",
        "keepalive", "ping", "ping-restart", "tun-mtu", "mssfix", "sndbuf",
        "rcvbuf", "float", "verify-x509-name", "auth-retry", "tls-timeout",
        "remote-random-hostname", "topology", "pull", "allow-compression", "static-challenge",
        "redirect-gateway", "route", "route-ipv6", "dhcp-option", "dns", "ifconfig-ipv6"
    ]
    private static let inlineTags: Set<String> = [
        "ca", "cert", "key", "tls-auth", "tls-crypt", "tls-crypt-v2", "pkcs12"
    ]

    public static func validate(_ content: String) throws -> ValidatedProfile {
        guard content.utf8.count <= 2_000_000 else { throw ProfileValidationError.tooLarge }
        var openTag: String?
        var endpoints: [String] = []
        var requestsCredentials = false
        var hasEmbeddedCA = false
        var sanitized: [String] = []
        for (offset, raw) in content.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.contains("\0") && !line.contains("\r") else {
                throw ProfileValidationError.invalidLine(offset + 1)
            }
            if let tag = openTag {
                if line == "</\(tag)>" { openTag = nil }
                sanitized.append(raw)
                continue
            }
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") {
                sanitized.append(raw)
                continue
            }
            if line.hasPrefix("<") {
                let name = String(line.dropFirst().dropLast())
                guard line.hasSuffix(">"), inlineTags.contains(name) else {
                    throw ProfileValidationError.unsupported(offset + 1, line)
                }
                if name == "ca" { hasEmbeddedCA = true }
                openTag = name
                sanitized.append(raw)
                continue
            }
            // Remove comments only after validating the directive itself.
            let tokens: [String]
            do { tokens = try OpenVPNOptionLexer.tokens(line) }
            catch { throw ProfileValidationError.invalidLine(offset + 1) }
            guard let cmd = tokens.first, !cmd.hasPrefix("--"), allowed.contains(cmd) else {
                throw ProfileValidationError.unsupported(offset + 1, line)
            }
            switch cmd {
            case "remote":
                guard (2...4).contains(tokens.count),
                      let host = tokens.dropFirst().first, isSafeHost(host) else {
                    throw ProfileValidationError.invalidLine(offset + 1)
                }
                if tokens.count >= 3 {
                    guard let port = UInt16(tokens[2]), port > 0 else {
                        throw ProfileValidationError.invalidLine(offset + 1)
                    }
                }
                if tokens.count == 4 {
                    guard ["udp", "udp4", "udp6", "tcp", "tcp4", "tcp6", "tcp-client", "tcp4-client", "tcp6-client"].contains(tokens[3]) else {
                        throw ProfileValidationError.invalidLine(offset + 1)
                    }
                }
                endpoints.append(host)
            case "auth-user-pass":
                guard tokens.count == 1 else { throw ProfileValidationError.unsupported(offset + 1, line) }
                requestsCredentials = true
            case "dev-type":
                guard tokens == ["dev-type", "tun"] else { throw ProfileValidationError.unsupported(offset + 1, line) }
            case "dev":
                guard tokens.count == 2, tokens[1] == "tun" || tokens[1].hasPrefix("utun") else {
                    throw ProfileValidationError.unsupported(offset + 1, line)
                }
            case "redirect-gateway":
                let safeFlags: Set<String> = ["def1", "bypass-dhcp", "bypass-dns", "ipv6", "!ipv4"]
                guard tokens.dropFirst().allSatisfy({ safeFlags.contains($0) }) else {
                    throw ProfileValidationError.unsupported(offset + 1, line)
                }
            case "ifconfig-ipv6":
                guard tokens.count == 3, (try? IPv6CIDR(tokens[1])) != nil, IPAddress.isIPv6(tokens[2]) else { throw ProfileValidationError.invalidLine(offset + 1) }
            case "route-ipv6":
                guard (2...4).contains(tokens.count), (try? IPv6CIDR(tokens[1])) != nil,
                      tokens.count < 3 || IPAddress.isIPv6(tokens[2]), tokens.count < 4 || UInt32(tokens[3]) != nil else { throw ProfileValidationError.invalidLine(offset + 1) }
            case "route":
                guard (3...5).contains(tokens.count),
                      IPv4CIDR.parseAddress(tokens[1]) != nil,
                      IPv4CIDR.parseAddress(tokens[2]) != nil || UInt8(tokens[2]) != nil,
                      tokens.count < 4 || ["vpn_gateway", "net_gateway"].contains(tokens[3]) ||
                          IPv4CIDR.parseAddress(tokens[3]) != nil else {
                    throw ProfileValidationError.unsupported(offset + 1, line)
                }
            case "allow-compression":
                guard tokens.count == 2, tokens[1] == "no" else {
                    throw ProfileValidationError.unsupported(offset + 1, line)
                }
            default:
                break
            }
            sanitized.append(raw)
        }
        guard openTag == nil else { throw ProfileValidationError.unterminatedBlock }
        guard !endpoints.isEmpty else { throw ProfileValidationError.missingRemote }
        // External CA/key/cert paths deliberately disallowed. Inline CA is required in V1.
        guard hasEmbeddedCA else { throw ProfileValidationError.missingInlineCA }
        return ValidatedProfile(text: sanitized.joined(separator: "\n"),
                                remoteHosts: endpoints, requestsCredentials: requestsCredentials)
    }
    private static func isSafeHost(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count < 254 else { return false }
        return value.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == ":")
        }
    }
}
public struct ValidatedProfile: Sendable {
    public let text: String
    public let remoteHosts: [String]
    public let requestsCredentials: Bool
}
public enum ProfileValidationError: Error, Equatable, LocalizedError {
    case unsupported(Int, String), invalidLine(Int), missingRemote, missingInlineCA, unterminatedBlock, tooLarge
    public var errorDescription: String? {
        switch self {
        case .unsupported(let line, _): return "Unsupported OpenVPN directive on line \(line). Script/plugin directives are blocked."
        case .invalidLine(let line): return "Invalid OpenVPN option on line \(line)."
        case .missingRemote: return "No remote VPN server configured."
        case .missingInlineCA: return "This engine currently requires an inline <ca> certificate."
        case .unterminatedBlock: return "Unterminated inline certificate/key block."
        case .tooLarge: return "OpenVPN configuration exceeds size limit."
        }
    }
}

