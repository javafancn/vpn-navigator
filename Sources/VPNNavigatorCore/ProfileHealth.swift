import Foundation
import Security
import CryptoKit

public struct ProfileHealthIssue: Identifiable, Equatable, Sendable {
    public enum Severity: Int, Comparable, Sendable {
        case information, warning, error
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }
    public let id: String
    public let severity: Severity
    public let message: String
}
public struct ProfileCertificate: Identifiable, Equatable, Sendable {
    public enum Role: String, Sendable { case authority = "CA", client = "客户端" }
    public let id: String
    public let role: Role
    public let notBefore: Date
    public let notAfter: Date
}
public struct ProfileHealthReport: Equatable, Sendable {
    public let checkedAt: Date
    public let issues: [ProfileHealthIssue]
    public let certificates: [ProfileCertificate]
    public var severity: ProfileHealthIssue.Severity { issues.map(\.severity).max() ?? .information }
    public var title: String { severity == .error ? "需要处理" : severity == .warning ? "需要关注" : "本地检查通过" }
    /// Identity and threshold, rather than the current date, suppress repeat notices.
    public func reminderSignature(at now: Date) -> String? {
        let values = certificates.compactMap { item -> String? in
            let remaining = item.notAfter.timeIntervalSince(now)
            let bucket: String
            if remaining < 0 { bucket = "expired" }
            else if remaining <= 86_400 { bucket = "1" }
            else if remaining <= 7 * 86_400 { bucket = "7" }
            else if remaining <= 30 * 86_400 { bucket = "30" }
            else { return nil }
            return item.id + ":" + bucket
        }.sorted()
        return values.isEmpty ? nil : ProfileHealth.digest(Data(values.joined(separator: "|").utf8))
    }
}

/// Offline inspection only. Does not evaluate trust, contact a server, decrypt a
/// private key, import identities into Keychain, or weaken the connection checks.
public enum ProfileHealth {
    public static func inspect(runtime: String, mode: RoutingMode = .original, now: Date = Date()) -> ProfileHealthReport {
        var issues: [ProfileHealthIssue] = []
        var certificates: [ProfileCertificate] = []
        func add(_ id: String, _ severity: ProfileHealthIssue.Severity, _ message: String) {
            issues.append(.init(id: id, severity: severity, message: message))
        }
        do {
            let parsed = try ProfileSafety.validate(runtime)
            try ManagedRoutingPolicy.validate(parsed, mode: mode)
        } catch {
            // Never surface a raw directive, embedded key, or arbitrary error.
            add("compatibility", .error, "配置不符合当前引擎或路由模式的兼容要求；请检查服务器、内联 CA 及不支持的选项。")
        }
        guard runtime.utf8.count <= 2_000_000 else {
            return .init(checkedAt: now, issues: issues, certificates: [])
        }
        let blocks = inlineBlocks(runtime)
        if blocks["pkcs12"] != nil { add("pkcs12", .warning, "PKCS#12 材料可能加密，本地健康检查不解锁；其证书有效期尚未检查。") }
        if blocks["cert"] != nil && blocks["key"] == nil && blocks["pkcs12"] == nil {
            add("missing-key", .error, "存在客户端证书，但未发现内联私钥或 PKCS#12 材料。")
        }
        if blocks["key"] != nil && blocks["cert"] == nil && blocks["pkcs12"] == nil {
            add("missing-cert", .warning, "存在私钥，但未发现客户端证书；请确认认证方式。")
        }
        var examined = 0
        for (tag, role) in [("ca", ProfileCertificate.Role.authority), ("cert", .client)] {
            guard let bodies = blocks[tag] else { continue }
            var seen = Set<String>()
            for body in bodies {
                let pieces = body.components(separatedBy: "-----BEGIN CERTIFICATE-----")
                guard pieces.count > 1, pieces.count <= 65 else { add("parse-" + tag, .warning, "\(role.rawValue)证书无法完整解析，有效期尚未检查。"); continue }
                if !pieces[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    add("prefix-" + tag, .warning, "\(role.rawValue)证书包含额外内容，请确认材料格式。")
                }
                for piece in pieces.dropFirst() {
                    guard examined < 64 else { add("certificate-limit", .warning, "证书材料超过 64 项检查上限，部分有效期尚未检查。"); break }
                    examined += 1
                    let parts = piece.components(separatedBy: "-----END CERTIFICATE-----")
                    guard parts.count == 2, parts[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          let der = Data(base64Encoded: parts[0].filter { !$0.isWhitespace }),
                          let certificate = SecCertificateCreateWithData(nil, der as CFData),
                          let dates = validity(certificate), dates.0 <= dates.1 else {
                        add("parse-" + tag, .warning, "\(role.rawValue)证书无法完整解析，有效期尚未检查。"); continue
                    }
                    let fingerprint = digest(der)
                    guard seen.insert(fingerprint).inserted else { continue }
                    let item = ProfileCertificate(id: tag + ":" + fingerprint, role: role, notBefore: dates.0, notAfter: dates.1)
                    certificates.append(item)
                    if now < item.notBefore { add(item.id, .error, "\(role.rawValue)证书尚未生效，请检查系统时间或更新材料。") }
                    else if now > item.notAfter { add(item.id, .error, "\(role.rawValue)证书已过期，请向管理员申请更新。") }
                    else if item.notAfter.timeIntervalSince(now) <= 30 * 86_400 {
                        let days = max(1, Int(ceil(item.notAfter.timeIntervalSince(now) / 86_400)))
                        add(item.id, .warning, "\(role.rawValue)证书将在 \(days) 天内到期，请提前申请更新。")
                    }
                }
            }
        }
        var unique = Set<String>()
        issues = issues.filter { unique.insert($0.id).inserted }
        return .init(checkedAt: now, issues: issues, certificates: certificates)
    }
    private static func validity(_ certificate: SecCertificate) -> (Date, Date)? {
        let keys = [kSecOIDX509V1ValidityNotBefore, kSecOIDX509V1ValidityNotAfter] as CFArray
        guard let values = SecCertificateCopyValues(certificate, keys, nil) as? [String: Any] else { return nil }
        func date(_ key: CFString) -> Date? {
            guard let property = values[key as String] as? [String: Any] else { return nil }
            if let value = property[kSecPropertyKeyValue as String] as? Date { return value }
            if let value = property[kSecPropertyKeyValue as String] as? NSNumber, value.doubleValue.isFinite {
                return Date(timeIntervalSinceReferenceDate: value.doubleValue)
            }
            return nil
        }
        guard let start = date(kSecOIDX509V1ValidityNotBefore), let end = date(kSecOIDX509V1ValidityNotAfter) else { return nil }
        return (start, end)
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func inlineBlocks(_ runtime: String) -> [String: [String]] {
        var result: [String: [String]] = [:], tag: String?, lines: [String] = []
        for raw in runtime.components(separatedBy: .newlines) {
            let row = raw.trimmingCharacters(in: .whitespaces)
            if let active = tag {
                if row == "</\(active)>" { result[active, default: []].append(lines.joined(separator: "\n")); tag = nil; lines = [] }
                else { lines.append(raw) }
            } else if row.hasPrefix("<"), row.hasSuffix(">"), !row.hasPrefix("</") { tag = String(row.dropFirst().dropLast()) }
        }
        return result
    }
    /// Conservative: endpoint, TLS identity, credentials mode and key material
    /// changes invalidate the old credential namespace. No secret is returned.
    static func credentialContext(_ runtime: String) -> String {
        let blocks = inlineBlocks(runtime)
        let identityOptions: Set<String> = ["remote", "proto", "auth-user-pass", "verify-x509-name", "remote-cert-tls", "static-challenge", "tls-cipher", "tls-ciphersuites"]
        var rows: [String] = [], inside: String?
        for raw in runtime.components(separatedBy: .newlines) {
            let row = raw.trimmingCharacters(in: .whitespaces)
            if let tag = inside { if row == "</\(tag)>" { inside = nil }; continue }
            if row.hasPrefix("<"), row.hasSuffix(">") { inside = String(row.dropFirst().dropLast()); continue }
            guard let tokens = try? OpenVPNOptionLexer.tokens(row), let first = tokens.first, identityOptions.contains(first) else { continue }
            rows.append(tokens.joined(separator: " "))
        }
        for key in blocks.keys.sorted() { rows.append(key + ":" + blocks[key]!.joined(separator: "\n")) }
        return digest(Data(rows.joined(separator: "\n").utf8))
    }
}

public struct CertificateReminderLedger: Codable, Equatable, Sendable {
    public var enabled = false
    public private(set) var delivered: [UUID: String] = [:]
    public init() {}
    public func shouldDeliver(id: UUID, signature: String) -> Bool { enabled && delivered[id] != signature }
    public mutating func record(id: UUID, signature: String) { delivered[id] = signature }
    public mutating func reconcile(ids: Set<UUID>) { delivered = delivered.filter { ids.contains($0.key) } }
}
