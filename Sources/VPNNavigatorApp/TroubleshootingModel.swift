import Foundation
import Combine
import VPNNavigatorCore

@MainActor
struct RoutingInspectionService {
    var snapshot: () async -> SessionReport?
    var lookup: (RouteLookupRequest) async throws -> RouteLookupResult
    var local: (String) async throws -> LocalNetworkSnapshot
    var tcp: (String, UInt16) async throws -> TCPProbeResult
    var dns: (String) async throws -> String
    var events: () async -> [DiagnosticEvent]
    static var live: Self {
        .init(snapshot: { await HelperClient.shared.sessionReport() },
              lookup: { try await HelperClient.shared.lookupRoute($0) },
              local: { try await NetworkProbes.localSnapshot(target: $0) },
              tcp: { try await NetworkProbes.tcp($0, port: $1) }, dns: { try await NetworkProbes.dns($0) },
              events: { await HelperClient.shared.diagnosticEvents() })
    }
    func verifiedLookup(_ request: RouteLookupRequest) async throws -> RouteLookupResult {
        let value = try await lookup(request)
        try Task.checkCancellation()
        guard value.request == request, value.decision.ip == request.ip,
              let fresh = await snapshot(), request.matches(fresh) else { throw RoutingModeSwitchError.stale }
        return value
    }
}

@MainActor
final class TroubleshootingModel: ObservableObject {
    @Published private(set) var checks: [TroubleshootingCheck] = []
    @Published private(set) var running = false
    @Published private(set) var status = "等待开始检查"
    @Published private(set) var stale = false
    private var work: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var generation = UUID()
    private let service: RoutingInspectionService
    init(service: RoutingInspectionService? = nil) { self.service = service ?? .live }
    func showSnapshotIfRequested() {
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",
              ProcessInfo.processInfo.arguments.contains("--vpnnav-ui-demo-snapshot"),
              ProcessInfo.processInfo.arguments.contains("--vpnnav-ui-troubleshooting-snapshot") else { return }
        status = "界面预览，未发出网络请求"
        checks = TroubleshootingChecklist.session(nil) + [TroubleshootingChecklist.configuration(.valid),
            TroubleshootingChecklist.rules(mode: .chinaDirect, count: 1000), TroubleshootingChecklist.dns(false),
            TroubleshootingChecklist.tcp(true), .init("route", "未核验 VPN 实际路径", .skipped, "没有可绑定的已连接会话，不能据此判断 VPN 已生效。")]
    }
    func cancel() {
        generation = UUID(); work?.cancel(); work = nil; deadline?.cancel(); deadline = nil
        if running { status = "已取消检查，保留已完成的采样结果" }; running = false
    }
    func invalidateSession() {
        if !checks.isEmpty { stale = true }
    }
    func start(model: AppModel, target: String, port: UInt16, hostname: String, timeout: UInt64 = 30_000_000_000) {
        cancel(); checks = []; stale = false
        guard let address = IPv4CIDR.parseAddress(target), port > 0, DiagnosticTargetPolicy.validHostname(hostname) else {
            status = "请输入有效的 IPv4、端口和域名。"; return
        }
        let target = IPv4CIDR.parseAddressString(address)
        let token = UUID(); generation = token; running = true; status = "正在核验助手与配置…"
        let profiles = model.profiles, selected = model.selected, countryCount = model.rules?.routes.count ?? 0
        deadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: timeout) } catch { return }
            guard let self, self.generation == token, self.running else { return }
            self.work?.cancel(); self.generation = UUID(); self.running = false
            self.status = "检查已超时，可调整目标后重试"
            self.checks.append(.init("deadline", "检查未全部完成", .warning, "已保留完成的采样，未完成项不能视为通过。"))
        }
        work = Task { [weak self] in
            guard let self else { return }
            let report = await service.snapshot()
            guard valid(token) else { return }
            checks = TroubleshootingChecklist.session(report)
            let profile = report?.activeProfileID.flatMap { id in profiles.first { $0.id == id } } ?? (report?.activeProfileID == nil ? selected : nil)
            let mode = report?.state == .connected ? report?.routingMode : profile?.mode
            let configuration = await model.checkConfiguration(profile, mode: mode)
            guard valid(token) else { return }
            checks.append(TroubleshootingChecklist.configuration(configuration))
            checks.append(TroubleshootingChecklist.rules(mode: mode, count: countryCount))
            if mode != .original, let profile, let applied = report?.customRuleDigest {
                let saved = try? CustomRuleSet(profile.customRules).digest
                checks.append(.init("custom", "本次自定义规则", saved == applied ? .pass : .warning,
                    saved == applied ? "助手的实际规则指纹与本机保存的规则一致。" : "本机规则与本次连接不同，下次连接前请确认策略。"))
            }
            status = "正在读取本机路由和 IPv6 状态…"
            do {
                let local = try await service.local(target)
                guard valid(token) else { return }
                checks.append(.init("local", "本机网络状态", .info,
                    "目标接口：\(local.interface.isEmpty ? "未知" : local.interface)；系统解析器：\(local.health.resolverCount) 个。"))
                let safety = local.health.ipv6Safety
                if safety == .noDefaultRoute { checks.append(.init("ipv6", "未发现 IPv6 默认路由", .info, "只代表当前系统路由表采样。")) }
                else if report?.firewallActive == true { checks.append(.init("ipv6", "助手报告保护已启用", .info, "IPv6 物理出口阻断仍需实际流量验收，此检查不提供无泄漏证明。")) }
                else { checks.append(.init("ipv6", "IPv6 路径需要留意", .warning, "存在 IPv6 默认路由或无法确定其归属。", "受管 IPv4 模式要求核验 IPv6 条件；查看路由与连接保护说明。")) }
            } catch {
                guard valid(token) else { return }
                checks.append(.init("local", "本机状态读取未完成", .warning, "未取得完整的路由与解析器快照。", "检查系统网络状态后重试。"))
            }
            guard valid(token) else { return }; status = "正在查询所选域名…"
            do { _ = try await service.dns(hostname); if valid(token) { checks.append(TroubleshootingChecklist.dns(true)) } }
            catch { if valid(token) { checks.append(TroubleshootingChecklist.dns(false)) } }
            guard valid(token) else { return }; status = "正在探测所选 TCP 端口…"
            do { let tcp = try await service.tcp(target, port); if valid(token) { checks.append(TroubleshootingChecklist.tcp(tcp.reachable)) } }
            catch { if valid(token) { checks.append(TroubleshootingChecklist.tcp(false)) } }
            guard valid(token) else { return }; status = "正在核验本次连接的实际路由…"
            if let report, let request = try? RouteLookupRequest(report: report, ip: target) {
                do {
                    let result = try await service.verifiedLookup(request)
                    if valid(token) { checks.append(TroubleshootingChecklist.route(result)) }
                } catch {
                    guard valid(token) else { return }; stale = true
                    checks.append(.init("route", "本次路由无法核验", .warning, "会话可能改变，或助手未能读取目标路由。", "等待连接状态稳定后重新检查。"))
                }
            } else { checks.append(.init("route", "未核验 VPN 实际路径", .skipped, "没有可绑定的已连接会话；上面的 TCP/DNS 结果不能证明 VPN 正在工作。")) }
            guard valid(token) else { return }
            let events = await service.events()
            guard valid(token) else { return }
            if let recent = TroubleshootingChecklist.recentFailure(events) { checks.append(recent) }
            let after = await service.snapshot()
            guard valid(token) else { return }
            if report?.state != after?.state || report?.activeProfileID != after?.activeProfileID ||
               report?.attemptID != after?.attemptID || report?.routingRevision != after?.routingRevision || report?.routingMode != after?.routingMode { stale = true }
            running = false; deadline?.cancel(); deadline = nil; work = nil
            status = stale ? "连接在检查期间发生变化，请重新检查" : "检查完成，请按各项建议处理"
        }
    }
    private func valid(_ token: UUID) -> Bool { generation == token && running && !Task.isCancelled }
}
