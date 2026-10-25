import Foundation
import CryptoKit

public enum CustomRouteAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case direct, vpn
    public var id: String { rawValue }
    public var title: String { self == .direct ? "直连" : "走 VPN" }
}
public struct CustomRouteRule: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var cidr: String
    public var action: CustomRouteAction
    public var enabled: Bool
    public init(id: UUID = UUID(), cidr: String, action: CustomRouteAction, enabled: Bool = true) {
        self.id = id; self.cidr = cidr; self.action = action; self.enabled = enabled
    }
}
public enum CustomRouteError: Error, LocalizedError {
    case invalidPrefix, overlap, tooMany, protectedNetwork, complexity
    public var errorDescription: String? {
        switch self {
        case .invalidPrefix: return "请输入有效的 IP 网段：IPv4 /8–/32，IPv6 全球单播 /16–/128 或 ULA /7–/128；不能使用回环、链路本地、组播或保留地址。"
        case .overlap: return "启用的自定义规则不能重叠；请缩小网段、停用或删除冲突项。"
        case .tooMany: return "每个配置最多保存 128 条规则，规则 ID 必须唯一。"
        case .protectedNetwork: return "自定义规则覆盖了当前局域网或 VPN 服务器，请缩小网段后重新连接。"
        case .complexity: return "组合后的直连路由超过 30000 条，请减少例外规则。"
        }
    }
}
public struct CustomRuleSet: Sendable {
    public let rules: [CustomRouteRule]
    public var active: [CustomRouteRule] { rules.filter(\.enabled) }
    public static var empty: Self { try! Self([]) }
    private static let forbidden = ["0.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
        "192.0.0.0/24", "192.0.2.0/24", "192.88.99.0/24", "198.18.0.0/15", "198.51.100.0/24",
        "203.0.113.0/24", "224.0.0.0/4", "240.0.0.0/4"].map { try! IPv4CIDR($0) }
    public static func prefix(_ text: String) throws -> IPv4CIDR {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.utf8.count <= 32, let value = try? IPv4CIDR(clean.contains("/") ? clean : clean + "/32"),
              value.prefix >= 8, !forbidden.contains(where: { $0.overlaps(value) }) else { throw CustomRouteError.invalidPrefix }
        return value
    }
    public init(_ input: [CustomRouteRule]) throws {
        guard input.count <= 128, Set(input.map(\.id)).count == input.count else { throw CustomRouteError.tooMany }
        var values: [CustomRouteRule] = [], prefixes: [IPv4CIDR] = [], prefixes6: [IPv6CIDR] = []
        for var rule in input {
            if rule.cidr.contains(":") {
                let prefix = try Self.prefix6(rule.cidr); rule.cidr = prefix.description
                if rule.enabled {
                    guard !prefixes6.contains(where: { $0.overlaps(prefix) }) else { throw CustomRouteError.overlap }
                    prefixes6.append(prefix)
                }
                values.append(rule); continue
            }
            let prefix = try Self.prefix(rule.cidr); rule.cidr = prefix.description
            if rule.enabled {
                guard !prefixes.contains(where: { $0.overlaps(prefix) }) else { throw CustomRouteError.overlap }
                prefixes.append(prefix)
            }
            values.append(rule)
        }
        rules = values
    }
    public var digest: String {
        let value = active.map { $0.cidr + ":" + $0.action.rawValue }.sorted().joined(separator: "\n")
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public func validateEnvironment(endpoint: String?, local: [IPv4CIDR]) throws {
        for rule in active {
            if rule.cidr.contains(":") { continue }
            let prefix = try Self.prefix(rule.cidr)
            if local.contains(where: { $0.overlaps(prefix) }) || endpoint.flatMap(IPv4CIDR.parseAddress).map({ prefix.contains($0) }) == true {
                throw CustomRouteError.protectedNetwork
            }
        }
    }
    /// Remove VPN exceptions from the *physical allow list*. Explicit utun
    /// routes inside a broad physical route would leave PF permission too broad.
    public func directPrefixes(country: RuleSet?, local: [IPv4CIDR], endpoint: String?) throws -> [IPv4CIDR] {
        try validateEnvironment(endpoint: endpoint, local: local)
        let host = endpoint.flatMap { try? IPv4CIDR($0 + "/32") }
        let base = (country?.routes ?? []).filter { value in !local.contains(where: { $0.overlaps(value) }) && value != host }
        if active.isEmpty { return base }
        typealias Interval = (lo: UInt64, hi: UInt64)
        func interval(_ prefix: IPv4CIDR) -> Interval {
            (UInt64(prefix.network), UInt64(prefix.network) + (UInt64(1) << (32 - prefix.prefix)) - 1)
        }
        let additions = try active.filter { $0.action == .direct && !$0.cidr.contains(":") }.map { try Self.prefix($0.cidr) }
        let cuts = try active.filter { $0.action == .vpn && !$0.cidr.contains(":") }.map { interval(try Self.prefix($0.cidr)) }.sorted { $0.lo < $1.lo }
        var source: [Interval] = []
        for prefix in base + additions { source.append(interval(prefix)) }
        source.sort { left, right in
            if left.lo == right.lo { return left.hi < right.hi }
            return left.lo < right.lo
        }
        var merged: [Interval] = []
        for range in source {
            if let last = merged.last, range.lo <= last.hi + 1 { merged[merged.count - 1].hi = max(last.hi, range.hi) }
            else { merged.append(range) }
        }
        var output: [IPv4CIDR] = []
        func append(_ lo: UInt64, _ hi: UInt64) throws {
            guard lo <= hi else { return }
            var address = lo
            while address <= hi {
                var bits = min(24, address.trailingZeroBitCount)
                while address + (UInt64(1) << bits) - 1 > hi { bits -= 1 }
                let prefix = try IPv4CIDR(IPv4CIDR.parseAddressString(UInt32(address)) + "/\(32 - bits)")
                output.append(prefix)
                guard output.count <= 30_000 else { throw CustomRouteError.complexity }
                address += UInt64(1) << bits
            }
        }
        for range in merged {
            var cursor = range.lo
            for cut in cuts where cut.hi >= range.lo && cut.lo <= range.hi {
                if cut.lo > cursor { try append(cursor, min(range.hi, cut.lo - 1)) }
                cursor = max(cursor, cut.hi + 1)
                if cursor > range.hi { break }
            }
            if cursor <= range.hi { try append(cursor, range.hi) }
        }
        return output.sorted()
    }
}

extension CustomRuleSet {
    public static func prefix6(_ text: String) throws -> IPv6CIDR {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.utf8.count <= 64, let prefix = try? IPv6CIDR(clean.contains("/") ? clean : clean + "/128") else { throw CustomRouteError.invalidPrefix }
        let ula = try IPv6CIDR("fc00::/7")
        if prefix.prefix >= 7 && ula.overlaps(prefix) { return prefix }
        _ = try IPv6RuleSet(text: prefix.description)
        guard prefix.prefix >= 16 else { throw CustomRouteError.invalidPrefix }
        return prefix
    }
    public func directPrefixes6(country: IPv6RuleSet?, local: [IPv6CIDR], endpoint: String?) throws -> [IPv6CIDR] {
        let active6 = active.filter { $0.cidr.contains(":") }
        for rule in active6 {
            let value = try Self.prefix6(rule.cidr)
            if local.contains(where: { $0.overlaps(value) }) || endpoint.map(value.contains) == true { throw CustomRouteError.protectedNetwork }
        }
        let host = endpoint.flatMap { try? IPv6CIDR($0 + "/128") }
        let base = (country?.routes ?? []).filter { value in !local.contains(where: { $0.overlaps(value) }) && value != host }
        let additions = try active6.filter { $0.action == .direct }.map { try Self.prefix6($0.cidr) }
        let cuts = try active6.filter { $0.action == .vpn }.map { try Self.prefix6($0.cidr) }
        var source: [IPv6CIDR] = []
        for value in Set(base + additions).sorted(by: { $0.prefix == $1.prefix ? $0 < $1 : $0.prefix < $1.prefix }) {
            if !source.contains(where: { $0.prefix <= value.prefix && $0.overlaps(value) }) { source.append(value) }
        }
        var result: [IPv6CIDR] = []
        func subtract(_ value: IPv6CIDR, _ overlapping: [IPv6CIDR]) throws {
            if overlapping.contains(where: { $0.prefix <= value.prefix && $0.overlaps(value) }) { return }
            let remaining = overlapping.filter { $0.overlaps(value) }
            if remaining.isEmpty { result.append(value); guard result.count <= 30_000 else { throw CustomRouteError.complexity }; return }
            for child in try value.children() { try subtract(child, remaining) }
        }
        for value in source { try subtract(value, cuts) }
        return result.sorted()
    }
}
