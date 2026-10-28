import Foundation

/// Strict dual-stack policy: only the owned tunnel, numeric VPN endpoint, DHCP and
/// explicit direct networks may leave the host. All other IPv4/IPv6 is blocked.
public struct LeakGuardPolicy: Sendable {
    public static let anchor = "com.apple/000.vpn-navigator"
    public let physical: String
    public let endpoint: String
    public let port: UInt16
    public let transport: FirewallRulePreview.Transport
    public let direct: [IPv4CIDR]
    public let direct6: [IPv6CIDR]
    public let physical4: String?
    public let physical6: String?
    public let ipv4Tunnel: Bool
    public let ipv6Tunnel: Bool
    public init(physical: String, endpoint: String, port: UInt16,
                transport: FirewallRulePreview.Transport, local: [IPv4CIDR], country: [IPv4CIDR], managedDirect: [IPv4CIDR] = [],
                physical4: String? = nil, physical6: String? = nil, local6: [IPv6CIDR] = [], managedDirect6: [IPv6CIDR] = [],
                ipv4Tunnel: Bool = true, ipv6Tunnel: Bool = false) throws {
        guard Self.validPhysical(physical), physical4.map(Self.validPhysical) ?? true,
              physical6.map(Self.validPhysical) ?? true else { throw LeakGuardError.invalidInterface }
        guard IPAddress.canonical(endpoint) != nil, port > 0 else { throw LeakGuardError.invalidEndpoint }
        guard (IPAddress.isIPv6(endpoint) || !local.isEmpty), local.allSatisfy({ $0.prefix >= 8 && $0.network >> 24 != 0 && $0.network >> 24 != 127 && $0.network >> 24 < 224 }) else { throw LeakGuardError.invalidLocalNetworks }
        guard country.allSatisfy({ $0.prefix >= 8 }) else { throw LeakGuardError.invalid }
        if !country.isEmpty { _ = try RuleSet(text: country.map(\.description).joined(separator: "\n")) }
        guard managedDirect.count <= 30_000 else { throw LeakGuardError.invalid }
        for prefix in managedDirect { _ = try CustomRuleSet.prefix(prefix.description) }
        self.physical = physical; self.endpoint = endpoint; self.port = port; self.transport = transport
        self.physical4 = physical4 ?? (IPAddress.isIPv6(endpoint) ? nil : physical)
        self.physical6 = physical6 ?? (IPAddress.isIPv6(endpoint) ? physical : nil)
        self.ipv4Tunnel = ipv4Tunnel; self.ipv6Tunnel = ipv6Tunnel
        guard managedDirect6.count <= 30_000 else { throw LeakGuardError.invalid }
        for prefix in managedDirect6 { _ = try CustomRuleSet.prefix6(prefix.description) }
        guard local6.allSatisfy({ $0.prefix >= 3 && !$0.address.hasPrefix("ff") && $0.address != "::" }) else { throw LeakGuardError.invalid }
        direct6 = Array(Set(local6 + managedDirect6)).sorted()
        direct = Array(Set(local + country + managedDirect)).sorted()
    }
    public func rules(tunnel: String?) throws -> String {
        if let tunnel, !DNSRecoveryPolicy.validTunnel(tunnel) { throw LeakGuardError.invalid }
        let tunnelRule = tunnel.map { value in
            (ipv4Tunnel ? "pass out quick on \(value) inet from any to any keep state (if-bound)\n" : "") +
            (ipv6Tunnel ? "pass out quick on \(value) inet6 from any to any keep state (if-bound)\n" : "")
        } ?? ""
        let endpointFamily = IPAddress.isIPv6(endpoint) ? "inet6" : "inet"
        let direct4Rule = physical4.map { "pass out quick on \($0) inet from any to <vpnnav_direct4> keep state (if-bound)\n" } ?? ""
        let direct6Rule = physical6.map { "pass out quick on \($0) inet6 from any to <vpnnav_direct6> keep state (if-bound)\n" } ?? ""
        let discovery = physical6.map { value in """
        pass out quick on \(value) inet6 proto icmp6 from any to { fe80::/10, ff02::/16 } icmp6-type { routersol, neighbrsol, neighbradv } no state
        pass out quick on \(value) inet6 proto udp from fe80::/10 port 546 to ff02::1:2 port 547 keep state (if-bound)

        """ } ?? ""
        return """
        # VPN Navigator owned anchor. Never load this as the host main ruleset.
        table <vpnnav_direct4> const { \(direct.map(\.description).joined(separator: ", ")) }
        table <vpnnav_direct6> const { \(direct6.map(\.description).joined(separator: ", ")) }
        pass out quick on lo0 all no state
        \(tunnelRule)pass out quick on \(physical) \(endpointFamily) proto \(transport.rawValue) from any to \(endpoint) port \(port) keep state (if-bound)
        pass out quick on \(physical) inet proto udp from any port 68 to 255.255.255.255 port 67 keep state (if-bound)
        \(direct4Rule)\(direct6Rule)\(discovery)block drop out quick inet from any to any
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
public enum LeakGuardError: Error, LocalizedError, Equatable {
    case invalid, invalidInterface, invalidEndpoint, invalidLocalNetworks, incompatibleHost, unresolved, notActive
    public var errorDescription: String? {
        switch self {
        case .invalid: return L10n.text("断线保护参数无效。")
        case .invalidInterface: return L10n.text("断线保护无法核验物理网卡；请检查当前网络和其它 VPN／TUN。")
        case .invalidEndpoint: return L10n.text("断线保护无法核验服务器地址、端口或传输协议，请检查配置。")
        case .invalidLocalNetworks: return L10n.text("断线保护未取得有效的物理局域网网段，请查看本机路由诊断。")
        case .incompatibleHost: return L10n.text("此 Mac 的 PF 配置无法安全接入断线保护。未替换系统规则，请检查其他网络过滤服务。")
        case .unresolved: return L10n.text("断线保护仍需恢复。请先执行安全网络恢复，再建立新连接。")
        case .notActive: return L10n.text("无法核验断线保护，已停止 VPN 会话。")
        }
    }
}

public struct GuardEndpoint: Sendable {
    public let host: String
    public let port: UInt16
    public let transport: FirewallRulePreview.Transport
    public let preferredFamily: Int?
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
              (DiagnosticTargetPolicy.validHostname(remote[1]) || IPAddress.canonical(remote[1]) != nil),
              let port = remote.count >= 3 ? UInt16(remote[2]) : 1194, port > 0 else { throw LeakGuardError.invalidEndpoint }
        if remote.count == 4 { proto = remote[3] }
        let transport: FirewallRulePreview.Transport
        if ["udp", "udp4", "udp6"].contains(proto) { transport = .udp }
        else if ["tcp", "tcp4", "tcp6", "tcp-client", "tcp4-client", "tcp6-client"].contains(proto) { transport = .tcp }
        else { throw LeakGuardError.invalidEndpoint }
        return .init(host: remote[1], port: port, transport: transport, preferredFamily: proto.contains("6") ? 6 : proto.contains("4") ? 4 : nil)
    }
    public func pinnedProfile(_ source: String, address: String) throws -> String {
        guard IPAddress.canonical(address) != nil else { throw LeakGuardError.invalid }
        var result: [String] = [], inline: String?
        for line in source.components(separatedBy: .newlines) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if let tag = inline { result.append(line); if text == "</\(tag)>" { inline = nil }; continue }
            if text.hasPrefix("<"), text.hasSuffix(">") { inline = String(text.dropFirst().dropLast()); result.append(line); continue }
            let name = try OpenVPNOptionLexer.tokens(text).first ?? ""
            if ["remote", "proto", "remote-random", "remote-random-hostname"].contains(name) { continue }
            result.append(line)
        }
        let proto = transport == .udp ? (IPAddress.isIPv6(address) ? "udp6" : "udp4") : (IPAddress.isIPv6(address) ? "tcp6-client" : "tcp4-client")
        result += ["remote \(address) \(port)", "proto \(proto)"]
        return result.joined(separator: "\n")
    }
}
