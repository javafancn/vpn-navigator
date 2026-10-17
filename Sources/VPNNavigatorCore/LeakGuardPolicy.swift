import Foundation

/// Strict IPv4 policy: only the owned tunnel, numeric VPN endpoint, DHCP and
/// explicit direct networks may leave the host. All other IPv4/IPv6 is blocked.
public struct LeakGuardPolicy: Sendable {
    public static let anchor = "com.apple/000.vpn-navigator"
    public let physical: String
    public let endpoint: String
    public let port: UInt16
    public let transport: FirewallRulePreview.Transport
    public let direct: [IPv4CIDR]
    public init(physical: String, endpoint: String, port: UInt16,
                transport: FirewallRulePreview.Transport, local: [IPv4CIDR], country: [IPv4CIDR]) throws {
        guard Self.validPhysical(physical), IPv4CIDR.parseAddress(endpoint) != nil, port > 0,
              !local.isEmpty, local.allSatisfy({ $0.prefix >= 8 }), country.allSatisfy({ $0.prefix >= 8 }) else { throw LeakGuardError.invalid }
        if !country.isEmpty { _ = try RuleSet(text: country.map(\.description).joined(separator: "\n")) }
        self.physical = physical; self.endpoint = endpoint; self.port = port; self.transport = transport
        direct = Array(Set(local + country)).sorted()
    }
    public func rules(tunnel: String?) throws -> String {
        if let tunnel, !DNSRecoveryPolicy.validTunnel(tunnel) { throw LeakGuardError.invalid }
        let tunnelRule = tunnel.map { "pass out quick on \($0) inet from any to any keep state\n" } ?? ""
        return """
        # VPN Navigator owned anchor. Never load this as the host main ruleset.
        table <vpnnav_direct4> const { \(direct.map(\.description).joined(separator: ", ")) }
        pass out quick on lo0 all
        \(tunnelRule)pass out quick on \(physical) inet proto \(transport.rawValue) from any to \(endpoint) port \(port) keep state
        pass out quick on \(physical) inet proto udp from any port 68 to 255.255.255.255 port 67 keep state
        pass out quick on \(physical) inet from any to <vpnnav_direct4> keep state
        block drop out quick inet from any to any
        block drop out quick inet6 from any to any
        """
    }
    public static func validPhysical(_ value: String) -> Bool {
        value.hasPrefix("en") && (1...4).contains(value.dropFirst(2).count) && value.dropFirst(2).allSatisfy { $0.isASCII && $0.isNumber }
    }
    public static func compatibleRootRules(_ text: String) -> Bool {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("No ALTQ") && !$0.hasPrefix("ALTQ") && $0 != "scrub-anchor \"com.apple/*\" all fragment reassemble" }
        return lines == ["anchor \"com.apple/*\" all"] || lines == ["anchor \"com.apple/*\""]
    }
    public static func enableToken(_ text: String) -> String? {
        for line in text.components(separatedBy: .newlines) {
            let pair = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, pair[0] == "Token", !pair[1].isEmpty,
               pair[1].allSatisfy({ $0.isASCII && $0.isNumber }), UInt64(pair[1]) != nil { return pair[1] }
        }
        return nil
    }
}
public enum LeakGuardError: Error, LocalizedError {
    case invalid, incompatibleHost, unresolved, notActive
    public var errorDescription: String? {
        switch self {
        case .invalid: return "断线保护参数无效。"
        case .incompatibleHost: return "此 Mac 的 PF 配置无法安全接入断线保护。未替换系统规则，请检查其他网络过滤服务。"
        case .unresolved: return "断线保护仍需恢复。请先执行安全网络恢复，再建立新连接。"
        case .notActive: return "无法核验断线保护，已停止 VPN 会话。"
        }
    }
}

public struct GuardEndpoint: Sendable {
    public let host: String
    public let port: UInt16
    public let transport: FirewallRulePreview.Transport
    public static func parse(_ profile: String) throws -> Self {
        var inline: String?, remotes: [[String]] = [], proto = "udp"
        for line in profile.components(separatedBy: .newlines) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if let tag = inline { if text == "</\(tag)>" { inline = nil }; continue }
            if text.hasPrefix("<"), text.hasSuffix(">") { inline = String(text.dropFirst().dropLast()); continue }
            let tokens = try OpenVPNOptionLexer.tokens(text)
            if tokens.first == "proto", tokens.count == 2 { proto = tokens[1] }
            if tokens.first == "remote" { remotes.append(tokens) }
        }
        guard let remote = remotes.first, (2...4).contains(remote.count),
              DiagnosticTargetPolicy.validHostname(remote[1]),
              let port = remote.count >= 3 ? UInt16(remote[2]) : 1194, port > 0 else { throw LeakGuardError.invalid }
        if remote.count == 4 { proto = remote[3] }
        let transport: FirewallRulePreview.Transport
        if ["udp", "udp4"].contains(proto) { transport = .udp }
        else if ["tcp", "tcp4", "tcp-client", "tcp4-client"].contains(proto) { transport = .tcp }
        else { throw LeakGuardError.invalid }
        return .init(host: remote[1], port: port, transport: transport)
    }
    public func pinnedProfile(_ source: String, address: String) throws -> String {
        guard IPv4CIDR.parseAddress(address) != nil else { throw LeakGuardError.invalid }
        var result: [String] = [], inline: String?
        for line in source.components(separatedBy: .newlines) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if let tag = inline { result.append(line); if text == "</\(tag)>" { inline = nil }; continue }
            if text.hasPrefix("<"), text.hasSuffix(">") { inline = String(text.dropFirst().dropLast()); result.append(line); continue }
            let name = try OpenVPNOptionLexer.tokens(text).first ?? ""
            if ["remote", "proto", "remote-random", "remote-random-hostname"].contains(name) { continue }
            result.append(line)
        }
        result += ["remote \(address) \(port)", "proto \(transport == .udp ? "udp4" : "tcp4-client")"]
        return result.joined(separator: "\n")
    }
}
