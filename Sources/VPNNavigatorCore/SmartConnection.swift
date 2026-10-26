import Foundation

public enum SmartTrigger: String, Codable, Sendable { case launch, wake, networkRestored }
public enum SmartNetworkScope: String, Codable, CaseIterable, Identifiable, Sendable {
    case any, wifi, wired, specifiedWiFi
    public var id: String { rawValue }
    public var title: String { switch self { case .any: return L10n.text("任意可用网络"); case .wifi: return L10n.text("仅 Wi-Fi"); case .wired: return L10n.text("仅有线网络"); case .specifiedWiFi: return L10n.text("指定 Wi-Fi 名称") } }
}
public enum StatusNoticeScope: String, Codable, CaseIterable, Identifiable, Sendable {
    case errors, all
    public var id: String { rawValue }
    public var title: String { self == .errors ? L10n.text("仅异常与认证请求") : L10n.text("连接变化与异常") }
}
public struct SmartConnectionPreferences: Codable, Equatable, Sendable {
    public var enabled = false
    public var paused = false
    public var onLaunch = false
    public var onWake = false
    public var onNetworkRestore = false
    public var profileID: UUID?
    public var networkScope: SmartNetworkScope = .any
    public var wifiNames: [String] = []
    public var allowExpensive = false
    public var notifications = false
    public var noticeScope: StatusNoticeScope = .errors
    public var sound = false
    public init() { }
    public func accepts(_ trigger: SmartTrigger) -> Bool {
        switch trigger { case .launch: return onLaunch; case .wake: return onWake; case .networkRestored: return onNetworkRestore }
    }
    public var valid: Bool {
        wifiNames.count <= 32 && Set(wifiNames).count == wifiNames.count && wifiNames.allSatisfy {
            !$0.isEmpty && $0.utf8.count <= 32 && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        }
    }
}
public struct SmartNetworkState: Equatable, Sendable {
    public enum Kind: String, Sendable { case wifi, wired, other }
    public var online: Bool
    public var kind: Kind
    public var wifiName: String?
    public var expensive: Bool
    public var identity: String
    public init(online: Bool, kind: Kind = .other, wifiName: String? = nil, expensive: Bool = false, identity: String = "") {
        self.online = online; self.kind = kind; self.wifiName = wifiName; self.expensive = expensive; self.identity = identity
    }
}
public struct SmartConnectionContext: Sendable {
    public var state: TunnelState
    public var activeProfileID: UUID?
    public var helperReady: Bool
    public var recoveryRequired: Bool
    public var occupied: Bool
    public var sleeping: Bool
    public init(state: TunnelState, activeProfileID: UUID? = nil, helperReady: Bool, recoveryRequired: Bool = false, occupied: Bool = false, sleeping: Bool = false) {
        self.state = state; self.activeProfileID = activeProfileID; self.helperReady = helperReady
        self.recoveryRequired = recoveryRequired; self.occupied = occupied; self.sleeping = sleeping
    }
}
public enum SmartConnectionDecision: Equatable, Sendable { case connect(UUID), wait(String), disabled }
public enum SmartConnectionPlanner {
    public static func target(profiles: [VPNProfile], successes: [UUID: Date], preferred: UUID?, automatic: Bool, now: Date = Date()) -> VPNProfile? {
        if let preferred { return profiles.first { $0.id == preferred } }
        let successful = profiles.filter { profile in successes[profile.id].map { $0 <= now && $0.timeIntervalSince1970 >= 0 } == true }
        if let result = successful.sorted(by: { left, right in
            let a = successes[left.id]!, b = successes[right.id]!
            return a == b ? left.id.uuidString < right.id.uuidString : a > b
        }).first { return result }
        guard !automatic else { return nil }
        return profiles.sorted {
            if $0.isFavorite != $1.isFavorite { return $0.isFavorite }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }.first
    }
    public static func decide(preferences: SmartConnectionPreferences, trigger: SmartTrigger, network: SmartNetworkState,
                              context: SmartConnectionContext, target: UUID?) -> SmartConnectionDecision {
        guard preferences.enabled, preferences.accepts(trigger) else { return .disabled }
        guard !preferences.paused else { return .wait(L10n.text("自动连接已暂停，恢复后等待下一次触发。")) }
        guard preferences.valid else { return .wait(L10n.text("自动连接设置无效，请检查网络名称列表。")) }
        guard !context.sleeping else { return .wait(L10n.text("系统休眠中，等待唤醒。")) }
        guard network.online else { return .wait(L10n.text("等待可用网络。")) }
        guard preferences.allowExpensive || !network.expensive else { return .wait(L10n.text("当前网络按流量计费，自动连接已跳过。")) }
        switch preferences.networkScope {
        case .any: break
        case .wifi: guard network.kind == .wifi else { return .wait(L10n.text("等待 Wi-Fi 网络。")) }
        case .wired: guard network.kind == .wired else { return .wait(L10n.text("等待有线网络。")) }
        case .specifiedWiFi:
            guard network.kind == .wifi, let name = network.wifiName else { return .wait(L10n.text("无法核验当前 Wi-Fi 名称；请检查位置授权或网络状态。")) }
            guard preferences.wifiNames.contains(name) else { return .wait(L10n.text("当前 Wi-Fi 不在指定列表中。")) }
        }
        guard !context.occupied else { return .wait(L10n.text("应用正在处理其它操作，本次自动连接已跳过。")) }
        if context.state == .connected || ConnectionControl.inProgress(context.state) || context.activeProfileID != nil { return .wait(L10n.text("已有活动会话，自动连接不会切换或重复启动。")) }
        guard context.helperReady else { return .wait(L10n.text("助手状态尚未通过核验，请检查安装与授权。")) }
        guard !context.recoveryRequired else { return .wait(L10n.text("网络恢复尚未完成，请先处理恢复记录。")) }
        guard context.state == .disconnected else { return .wait(L10n.text("连接发生异常，请先手动检查并重试。")) }
        guard let target else { return .wait(preferences.profileID == nil ? L10n.text("请先成功连接一次，或选择固定的自动连接配置。") : L10n.text("指定配置已不存在，请重新选择。")) }
        return .connect(target)
    }
}

/// User-scoped preferences only. Never stores credentials, SSID observations,
/// route output or helper messages; only explicitly configured network names.
public final class SmartConnectionStore {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func load() -> SmartConnectionPreferences {
        guard let data = defaults.data(forKey: "smartConnection.v1"), data.count <= 64_000,
              let value = try? JSONDecoder().decode(SmartConnectionPreferences.self, from: data), value.valid else { return .init() }
        return value
    }
    public func save(_ value: SmartConnectionPreferences) throws {
        guard value.valid else { throw SmartConnectionError.invalidPreferences }
        defaults.set(try JSONEncoder().encode(value), forKey: "smartConnection.v1")
    }
    public func successes() -> [UUID: Date] {
        guard let data = defaults.data(forKey: "smartConnection.successes.v1"), data.count < 32_000,
              let stored = try? JSONDecoder().decode([String: Date].self, from: data), stored.count <= 100 else { return [:] }
        return stored.reduce(into: [:]) { result, pair in if let id = UUID(uuidString: pair.key), pair.value.timeIntervalSince1970.isFinite { result[id] = pair.value } }
    }
    public func recordSuccess(_ id: UUID, at date: Date = Date()) {
        var values = successes(); values[id] = date
        let recent = values.sorted { $0.value > $1.value }.prefix(100)
        let encoded = Dictionary(uniqueKeysWithValues: recent.map { ($0.key.uuidString, $0.value) })
        if let data = try? JSONEncoder().encode(encoded) { defaults.set(data, forKey: "smartConnection.successes.v1") }
    }
}
public enum SmartConnectionError: Error, LocalizedError {
    case invalidPreferences, needsCredentials, occupied, cancelled
    public var errorDescription: String? {
        switch self {
        case .invalidPreferences: return L10n.text("最多保存 32 个不重复的 Wi-Fi 名称，每个名称限 32 字节且不能包含控制字符。")
        case .needsCredentials: return L10n.text("此配置需要身份验证，请先手动连接并按需保存凭据。自动连接不会使用输入框中的临时密码。")
        case .occupied: return L10n.text("当前有活动会话、待恢复记录或正在编辑的内容，未执行自动连接。")
        case .cancelled: return L10n.text("自动连接条件已改变，本次任务已取消。")
        }
    }
}

public enum VPNStatusNotice: String, Codable, Sendable {
    case connected, reconnecting, disconnected, lost, authentication, authenticationFailed, certificateFailed, recovery, failure, unavailable, test
    public var isError: Bool { ![Self.connected, .reconnecting, .disconnected, .test].contains(self) }
    public var title: String {
        switch self {
        case .connected: return L10n.text("VPN 已连接"); case .reconnecting: return L10n.text("VPN 正在重连"); case .disconnected: return L10n.text("VPN 已断开")
        case .lost: return L10n.text("VPN 连接中断"); case .authentication: return L10n.text("VPN 需要身份验证"); case .authenticationFailed: return L10n.text("VPN 认证失败或凭据失效")
        case .certificateFailed: return L10n.text("VPN 证书或 TLS 验证失败"); case .recovery: return L10n.text("VPN 网络恢复未完成")
        case .failure: return L10n.text("VPN 连接未成功"); case .unavailable: return L10n.text("无法核验 VPN 状态"); case .test: return L10n.text("VPN Navigator 通知测试")
        }
    }
    public var body: String {
        switch self {
        case .connected: return L10n.text("助手已确认 VPN 会话。可在应用中查看路由策略并核验具体目标路径。")
        case .reconnecting: return L10n.text("正在按已配置的重连策略处理，请等待状态稳定。")
        case .disconnected: return L10n.text("本次断开已由助手确认。")
        case .lost: return L10n.text("连接意外结束，请打开应用检查网络与服务器状态。")
        case .authentication: return L10n.text("请打开应用完成认证。应用不会自动填写动态验证码。")
        case .authenticationFailed: return L10n.text("请重新核对账户或凭据。自动连接不会反复尝试失败的认证。")
        case .certificateFailed: return L10n.text("请检查证书有效期与服务器配置；不会跳过校验。")
        case .recovery: return L10n.text("请打开应用查看恢复结果，保留尚未确认的路由与 DNS 记录。")
        case .failure: return L10n.text("请打开应用检查认证、配置与网络；自动连接已停止本次尝试。")
        case .unavailable: return L10n.text("助手状态无法确认，请检查安装与服务授权。")
        case .test: return L10n.text("通知已由应用提交。是否显示横幅和播放声音仍由系统设置决定。")
        }
    }
}
public struct StatusNoticeReducer: Sendable {
    private var previous: SessionReport?
    private var seen = Set<String>()
    private var unavailable = false
    private var lastUnavailableAt: Date?
    private var transitionSerial: UInt64 = 0
    public init() { }
    public mutating func observe(_ report: SessionReport?, expectedDisconnect: Bool = false, at now: Date = Date()) -> [VPNStatusNotice] {
        guard let report else {
            guard !unavailable, previous != nil else { return [] }
            unavailable = true
            if let lastUnavailableAt, now.timeIntervalSince(lastUnavailableAt) < 60 { return [] }
            lastUnavailableAt = now; return [.unavailable]
        }
        unavailable = false
        let old = previous; previous = report
        if let old, old.state != report.state || old.attemptID != report.attemptID { transitionSerial &+= 1 }
        let identity = (report.activeProfileID?.uuidString ?? old?.activeProfileID?.uuidString ?? "none") + ":" + (report.attemptID?.uuidString ?? old?.attemptID?.uuidString ?? "none")
        func key(_ notice: VPNStatusNotice, _ detail: String = "") -> String { identity + ":" + notice.rawValue + ":" + detail }
        var notices: [(VPNStatusNotice, String)] = []
        if let challenge = report.challenge { notices.append((.authentication, key(.authentication, challenge.id.uuidString))) }
        if report.state == .failed {
            let notice: VPNStatusNotice
            if report.failureCode == .authentication { notice = .authenticationFailed }
            else if report.failureCode.map({ [DiagnosticCode.certificate, .tls].contains($0) }) == true { notice = .certificateFailed }
            else if let old, !expectedDisconnect, old.state == .connected || old.state == .reconnecting { notice = .lost }
            else { notice = report.requiresNetworkRecovery ? .recovery : .failure }
            notices.append((notice, key(notice)))
            if report.requiresNetworkRecovery { notices.append((.recovery, key(.recovery))) }
        } else if report.state != .connected, !ConnectionControl.inProgress(report.state), report.requiresNetworkRecovery {
            notices.append((.recovery, key(.recovery)))
        } else if let old, report.state == .connected && (old.state != .connected || old.attemptID != report.attemptID) {
            if report.routingMode == .original || report.routingRevision != nil { notices.append((.connected, key(.connected, (report.routingRevision?.uuidString ?? "") + ":" + String(transitionSerial)))) }
        } else if let old, report.state == .reconnecting && old.state != .reconnecting { notices.append((.reconnecting, key(.reconnecting, String(transitionSerial)))) }
        else if let old, report.state == .disconnected && old.state != .disconnected && (old.state == .connected || ConnectionControl.inProgress(old.state)) {
            let notice: VPNStatusNotice = expectedDisconnect ? .disconnected : .lost; notices.append((notice, key(notice)))
        }
        if seen.count > 512 { seen.removeAll() }
        return notices.compactMap { notice, id in seen.insert(id).inserted ? notice : nil }
    }
}
