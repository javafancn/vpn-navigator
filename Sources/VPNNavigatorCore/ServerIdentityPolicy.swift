import Foundation

/// Structural import/export remains available for repairing legacy profiles.
/// Every connection must additionally verify a server role or an exact X.509
/// identity; merely trusting a CA does not distinguish its clients and servers.
public enum ServerIdentityPolicy {
    public static func validate(_ profile: ValidatedProfile) throws {
        var inline: String?
        var roles = Set<String>()
        var exactName = false
        for raw in profile.text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let tag = inline {
                if line == "</\(tag)>" { inline = nil }
                continue
            }
            if line.hasPrefix("<"), line.hasSuffix(">") { inline = String(line.dropFirst().dropLast()); continue }
            let tokens = try OpenVPNOptionLexer.tokens(line)
            if tokens.first == "remote-cert-tls" {
                guard tokens.count == 2, ["server", "client"].contains(tokens[1]) else { throw ServerIdentityError.invalid }
                roles.insert(tokens[1])
            }
            if tokens.first == "verify-x509-name" {
                guard (2...3).contains(tokens.count), !tokens[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      tokens.count == 2 || ["subject", "name", "name-prefix"].contains(tokens[2]) else { throw ServerIdentityError.invalid }
                // OpenVPN uses the last occurrence. A broad name prefix is
                // not accepted as the only identity constraint.
                exactName = tokens.count == 2 || tokens[2] != "name-prefix"
            }
        }
        guard !roles.contains("client") else { throw ServerIdentityError.wrongRole }
        guard roles.contains("server") || exactName else { throw ServerIdentityError.missing }
    }
}

public enum ServerIdentityError: Error, Equatable, LocalizedError {
    case missing, wrongRole, invalid
    public var errorDescription: String? {
        switch self {
        case .missing: return L10n.text("配置缺少服务端身份校验。请向管理员获取包含 remote-cert-tls server 或精确 verify-x509-name 约束的配置，再连接。")
        case .wrongRole: return L10n.text("配置将对端证书限定为客户端，无法用于安全连接 VPN 服务器。请向管理员获取正确的服务端身份校验配置。")
        case .invalid: return L10n.text("服务端身份校验参数无效，请检查 remote-cert-tls 和 verify-x509-name 配置。")
        }
    }
}
