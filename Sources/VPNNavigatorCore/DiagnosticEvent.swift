import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Only predefined messages cross into a support report. Raw OpenVPN output,
/// addresses, domain names, profile paths and authentication values are excluded.
public enum DiagnosticCode: String, Codable, Sendable {
    case starting, connected, stopped, cancelled, timeout, authentication, certificate
    case tls, dns, transport, cipher, route, networkChanged, unexpectedExit, recovery, configuration
    public var summary: String {
        switch self {
        case .starting: return L10n.text("正在启动 OpenVPN")
        case .connected: return L10n.text("隧道已建立并通过所选路由策略检查")
        case .stopped: return L10n.text("会话已停止")
        case .cancelled: return L10n.text("用户取消连接")
        case .timeout: return L10n.text("连接或认证超时，请检查服务器及网络")
        case .authentication: return L10n.text("认证失败，请检查用户名、密码或认证方式")
        case .certificate: return L10n.text("证书或私钥校验失败，请检查有效期与配置")
        case .tls: return L10n.text("TLS 协商失败，请检查证书、服务端和网络")
        case .dns: return L10n.text("服务器名称解析或 DNS 配置失败")
        case .transport: return L10n.text("连接传输失败，请检查地址、端口及网络")
        case .cipher: return L10n.text("加密算法协商失败，请检查服务端兼容性")
        case .route: return L10n.text("路由操作失败，需要核验系统网络状态")
        case .networkChanged: return L10n.text("网络路径发生变化，会话已停止")
        case .unexpectedExit: return L10n.text("OpenVPN 异常退出，请检查诊断及服务端状态")
        case .recovery: return L10n.text("已执行安全网络恢复检查")
        case .configuration: return L10n.text("OpenVPN 配置参数无效或与内置引擎不兼容，请检查配置健康报告")
        }
    }
}
public struct DiagnosticEvent: Codable, Identifiable, Sendable {
    public let id: UUID
    public let date: Date
    public let code: DiagnosticCode
    public init(_ code: DiagnosticCode, date: Date = Date()) {
        id = UUID(); self.date = date; self.code = code
    }
}
public enum OpenVPNLogClassifier {
    /// Never return the source line: even apparent errors can contain secrets.
    public static func classify(_ line: String) -> DiagnosticCode? {
        let text = line.uppercased()
        // CRV1 deliberately uses AUTH_FAILED to negotiate the next factor.
        // Malformed/terminal failures are logged by the management callback.
        if text.contains("AUTH_FAILED") && text.contains("CRV1:") { return nil }
        if text.contains("AUTH_FAILED") || text.contains("AUTHENTICATION FAILED") { return .authentication }
        if text.contains("VERIFY ERROR") || text.contains("CANNOT LOAD PRIVATE KEY") || text.contains("CERTIFICATE HAS EXPIRED") || text.contains("CANNOT LOAD CERTIFICATE") || text.contains("CANNOT LOAD CA CERTIFICATE") || text.contains("CA MD TOO WEAK") || text.contains("EE KEY TOO SMALL") || text.contains("CA KEY TOO SMALL") { return .certificate }
        if text.contains("OPTIONS ERROR:") || text.contains("UNRECOGNIZED OPTION") || text.contains("ERROR OPENING CONFIGURATION FILE") { return .configuration }
        if text.contains("TLS ERROR") || text.contains("TLS KEY NEGOTIATION FAILED") { return .tls }
        if text.contains("RESOLVE: CANNOT RESOLVE") || text.contains("DNS-UPDOWN FAILED") { return .dns }
        if text.contains("CIPHER NEGOTIATION FAILED") || text.contains("FAILED TO NEGOTIATE CIPHER") { return .cipher }
        if text.contains("CONNECTION REFUSED") || text.contains("NETWORK IS UNREACHABLE") || text.contains("TCP: CONNECT TO") && text.contains("FAILED") { return .transport }
        return nil
    }
}

/// Bounded, private structured log, shared by the app and helper. Never follows
/// a symlink or appends to a file owned by another user.
public final class DiagnosticEventStore: @unchecked Sendable {
    private let file: URL
    private let lock = NSLock()
    public init(file: URL) {
        self.file = file.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(file.lastPathComponent)
    }
    public func events() -> [DiagnosticEvent] {
        lock.lock(); defer { lock.unlock() }
        return read()
    }
    private func read() -> [DiagnosticEvent] {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              ((attrs[.size] as? NSNumber)?.intValue ?? Int.max) <= 200_000,
              let data = try? Data(contentsOf: file),
              let values = try? JSONDecoder().decode([DiagnosticEvent].self, from: data) else { return [] }
        return Array(values.suffix(150))
    }
    public func append(_ code: DiagnosticCode) {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default, parent = file.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            guard parent.resolvingSymlinksInPath() == parent.standardizedFileURL,
                  let attrs = try? fm.attributesOfItem(atPath: parent.path),
                  (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0,
                  !fm.fileExists(atPath: file.path) || file.resolvingSymlinksInPath() == file.standardizedFileURL else { return }
            var values = read()
            if values.last?.code == code, let last = values.last,
               Date().timeIntervalSince(last.date) < 2 { return }
            values.append(DiagnosticEvent(code)); values = Array(values.suffix(150))
            try JSONEncoder().encode(values).write(to: file, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { /* A full disk cannot disable session teardown. */ }
    }
}
