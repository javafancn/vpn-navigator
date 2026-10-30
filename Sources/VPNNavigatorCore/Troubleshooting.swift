import Foundation

public enum CheckSeverity: String, Sendable { case pass, info, warning, failure, skipped }
public struct TroubleshootingCheck: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let severity: CheckSeverity
    public let detail: String
    public let suggestion: String
    public init(_ id: String, _ title: String, _ severity: CheckSeverity, _ detail: String, _ suggestion: String = "") {
        self.id = id; self.title = title; self.severity = severity; self.detail = detail; self.suggestion = suggestion
    }
}
public enum ConfigurationCheckState: Sendable { case valid, invalid, missing }
public enum TroubleshootingChecklist {
    public static func session(_ report: SessionReport?) -> [TroubleshootingCheck] {
        guard let report else { return [.init("helper", L10n.text("助手状态无法核验"), .failure, L10n.text("未取得可信助手的会话快照。"), L10n.text("检查助手安装、系统后台服务授权或安装修复入口；不要删除恢复记录。")) ] }
        var values = [TroubleshootingCheck("helper", L10n.text("助手可访问"), .pass, L10n.text("已取得可信 XPC 助手快照。"))]
        if report.challenge != nil { values.append(.init("session", L10n.text("等待身份验证"), .warning, L10n.text("当前会话仍有认证请求。"), L10n.text("回到连接窗口完成验证或明确取消。"))) }
        else if report.state == .connected { values.append(.init("session", L10n.text("助手报告已连接"), .info, L10n.text("隧道状态已连接，目标连通性和实际路由仍需下面的探测。"))) }
        else if ConnectionControl.inProgress(report.state) { values.append(.init("session", L10n.text("连接正在变化"), .warning, L10n.text("连接或断开尚未结束。"), L10n.text("等待状态稳定后重新检查。"))) }
        else if report.requiresNetworkRecovery { values.append(.init("session", L10n.text("网络恢复尚未完成"), .failure, L10n.text("助手保留了待处理的网络恢复状态。"), L10n.text("先查看安全恢复结果；无法核验所有权时保留记录并人工处理。"))) }
        else { values.append(.init("session", L10n.text("当前没有已连接隧道"), report.state == .failed ? .warning : .info, L10n.text("后面的探测反映当前系统网络，不表示流量已经过 VPN。"), L10n.text("需要 VPN 时先连接，再核验实际路径。"))) }
        return values
    }
    public static func configuration(_ state: ConfigurationCheckState) -> TroubleshootingCheck {
        switch state {
        case .valid: return .init("profile", L10n.text("配置安全预检通过"), .pass, L10n.text("本机保存的配置格式、受支持指令和自定义规则通过检查；不代表证书握手或认证已成功。"))
        case .invalid: return .init("profile", L10n.text("配置预检未通过"), .failure, L10n.text("本机配置或规则存在不支持的内容。"), L10n.text("检查配置编辑器、外部材料和重叠规则，保留原始文件后修正。"))
        case .missing: return .init("profile", L10n.text("没有可检查的配置"), .skipped, L10n.text("未选择配置，或活动配置不在本机列表中。"), L10n.text("选择配置；索引损坏时先查看配置列表恢复。"))
        }
    }
    public static func rules(mode: RoutingMode?, count: Int) -> TroubleshootingCheck {
        guard mode == .chinaDirect else { return .init("rules", L10n.text("地区规则检查"), .info, L10n.text("当前模式不依赖中国 IPv4 直连库。")) }
        return count >= 100 ? .init("rules", L10n.text("地区规则已缓存"), .pass, L10n.format("已取得 {0} 条已解析前缀，实际命中还需路由核验。", [String(describing: count)])) :
            .init("rules", L10n.text("地区规则不足"), .failure, L10n.text("规则路由需要至少 100 条有效前缀。"), L10n.text("在路由与规则中更新或导入可信规则文件。"))
    }
    public static func tcp(_ reachable: Bool) -> TroubleshootingCheck {
        reachable ? .init("tcp", L10n.text("目标 TCP 可连接"), .pass, L10n.text("所选目标端口在本次探测时可达，不代表所有站点可用。")) :
            .init("tcp", L10n.text("目标 TCP 未连通"), .warning, L10n.text("目标可能关闭端口、拒绝连接或暂时不可达。"), L10n.text("确认目标及端口，换一个允许访问的目标交叉检查；不能单凭此项断定 VPN 故障。"))
    }
    public static func dns(_ answered: Bool) -> TroubleshootingCheck {
        answered ? .init("dns", L10n.text("系统 DNS 查询有结果"), .pass, L10n.text("所选域名返回了地址；此项不验证解析服务器的归属或是否泄漏。")) :
            .init("dns", L10n.text("系统 DNS 查询未成功"), .warning, L10n.text("所选域名没有取得可用结果。"), L10n.text("确认域名，检查系统 DNS、企业分域解析和当前网络；不要直接覆盖系统 DNS。"))
    }
    public static func route(_ result: RouteLookupResult) -> TroubleshootingCheck {
        if let matches = result.matchesExpected {
            return matches ? .init("route", L10n.text("实际路由与本次策略相符"), .pass, L10n.text("采样接口：") + result.observedInterface + "；" + result.decision.reason) :
                .init("route", L10n.text("实际路由与本次策略不符"), .failure, L10n.text("系统实际出口与助手的预期出口不一致。"), L10n.text("检查其它 VPN、更具体的系统路由及规则；停止连接并确认网络恢复后重试。"))
        }
        return .init("route", L10n.text("系统管理的实际路由"), .info, L10n.text("实际接口：") + result.observedInterface + "。" + result.decision.reason)
    }
    public static func recentFailure(_ events: [DiagnosticEvent]) -> TroubleshootingCheck? {
        let sorted = events.sorted { $0.date < $1.date }
        let boundary = sorted.lastIndex { [.starting, .connected, .cancelled].contains($0.code) }.map { $0 + 1 } ?? 0
        let failures: [DiagnosticCode] = [.timeout, .authentication, .certificate, .tls, .dns, .transport,
            .cipher, .route, .networkChanged, .unexpectedExit, .configuration, .engineSetup]
        guard let event = sorted.dropFirst(boundary).last(where: { failures.contains($0.code) }), Date().timeIntervalSince(event.date) >= 0,
              Date().timeIntervalSince(event.date) < 86_400 else { return nil }
        let suggestion: String
        switch event.code {
        case .authentication: suggestion = L10n.text("核对账户与认证方式，必要时更新保存的凭据。")
        case .configuration: suggestion = L10n.text("检查配置参数及内嵌证书，必要时通过配置更新向导替换文件。")
        case .engineSetup: suggestion = L10n.text("退出应用后重新安装最新版本，保留配置文件；无需修改 VPN 服务端参数。")
        case .certificate, .tls, .cipher: suggestion = L10n.text("检查证书有效期、加密兼容性及服务端配置。")
        case .route, .networkChanged: suggestion = L10n.text("检查其它 VPN 与网络切换情况，断开后核验网络恢复结果。")
        case .dns: suggestion = L10n.text("检查服务器域名和系统解析器，避免直接覆盖企业 DNS。")
        default: suggestion = L10n.text("检查服务端状态、目标端口及当前网络，必要时查看脱敏诊断。")
        }
        return .init("recent", L10n.text("最近会话的故障类别"), .warning, event.code.summary, suggestion + L10n.text("历史类别不替代本次网络探测。"))
    }
}
