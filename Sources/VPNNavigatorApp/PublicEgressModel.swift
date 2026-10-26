import Foundation
import Combine
import VPNNavigatorCore

@MainActor
struct PublicEgressService {
    var snapshot: () async -> SessionReport?
    var lookup: (RouteLookupRequest) async throws -> RouteLookupResult
    var query: @Sendable (EgressFamily) async throws -> EgressHTTPResult
    static var live: Self { .init(snapshot: {
        guard HelperClient.shared.installationStatus == .enabled else { return nil }
        return await HelperClient.shared.sessionReport()
    },
        lookup: { try await RoutingInspectionService.live.verifiedLookup($0) }, query: { try await PublicEgressHTTP.query($0) }) }
}
struct PublicEgressRow: Identifiable {
    var id: EgressFamily { family }
    let family: EgressFamily
    let response: EgressHTTPResult?
    let failure: EgressProbeFailure?
    let assessment: EgressPathAssessment?
    let interface: String?
}
private enum EgressQueryOutcome: Sendable {
    case success(EgressFamily, EgressHTTPResult), failure(EgressFamily, EgressProbeFailure)
}

@MainActor
final class PublicEgressModel: ObservableObject {
    @Published private(set) var rows: [PublicEgressRow] = []
    @Published private(set) var running = false
    @Published private(set) var status = "等待手动开始检测"
    @Published private(set) var checkedAt: Date?
    private let service: PublicEgressService
    private var generation = UUID()
    private var work: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    init(service: PublicEgressService? = nil) { self.service = service ?? .live }
    func cancel(clear: Bool = false) {
        generation = UUID(); work?.cancel(); deadline?.cancel(); work = nil; deadline = nil; running = false
        if clear { rows = []; checkedAt = nil }
        status = "已取消；可重新手动检测"
    }
    func invalidate() { cancel(clear: true); status = "会话或网络状态改变，结果已清除，请重新检测。" }
    func start(model: AppModel, families: [EgressFamily], limitNanoseconds: UInt64 = 25_000_000_000) {
        guard !ProcessInfo.processInfo.arguments.contains("--vpnnav-ui-demo-snapshot"), model.canStartEgressProbe else { return }
        let families = EgressFamily.allCases.filter { families.contains($0) }
        guard !families.isEmpty else { return }
        cancel(clear: true); let token = UUID(); generation = token
        running = true; status = "正在查询所选出口并核验会话…"
        let identity = model.egressContextIdentity
        deadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: limitNanoseconds) } catch { return }
            guard let self, token == self.generation else { return }
            self.generation = UUID(); self.work?.cancel(); self.work = nil; self.deadline = nil; self.running = false
            for family in families where !self.rows.contains(where: { $0.family == family }) {
                self.rows.append(.init(family: family, response: nil, failure: .timeout, assessment: nil, interface: nil))
            }
            self.rows.sort { $0.family.rawValue < $1.family.rawValue }; self.status = "整体检测超时，保留已完成的过程采样。"
        }
        work = Task { [weak self] in
            guard let self else { return }
            defer { if token == self.generation { self.running = false; self.work = nil; self.deadline?.cancel(); self.deadline = nil } }
            let report = await self.service.snapshot(), before = EgressSessionContext(report)
            guard token == self.generation, !Task.isCancelled, identity == model.egressContextIdentity else { if token == self.generation { self.invalidate() }; return }
            let query = self.service.query
            await withTaskGroup(of: EgressQueryOutcome.self) { group in
                for family in families {
                    group.addTask {
                        do { return .success(family, try await query(family)) }
                        catch { return .failure(family, (error as? EgressProbeFailure) ?? .transport) }
                    }
                }
                for await value in group {
                    guard token == self.generation, !Task.isCancelled else { group.cancelAll(); return }
                    var fresh = await self.service.snapshot()
                    guard token == self.generation, !Task.isCancelled else { group.cancelAll(); return }
                    guard before == EgressSessionContext(fresh), identity == model.egressContextIdentity else { self.invalidate(); group.cancelAll(); return }
                    let row: PublicEgressRow
                    switch value {
                    case .failure(let family, let failure): row = .init(family: family, response: nil, failure: failure, assessment: nil, interface: nil)
                    case .success(let family, let response):
                        var route: RouteLookupResult?
                        if before.verifiedConnection, response.usedProxy == false, response.cacheHit == false,
                           let remote = response.remoteAddress, family.matches(remote), PublicEgressAddress.isPublic(remote), let report,
                           let request = try? RouteLookupRequest(report: report, ip: remote) {
                            route = try? await self.service.lookup(request)
                            fresh = await self.service.snapshot()
                        }
                        guard before == EgressSessionContext(fresh), token == self.generation, !Task.isCancelled,
                              identity == model.egressContextIdentity else { if token == self.generation { self.invalidate() }; group.cancelAll(); return }
                        let assessment = EgressPathAssessment.evaluate(family: family, response: response, before: before, after: .init(fresh), route: route)
                        let observed = route?.observedInterface
                        row = .init(family: family, response: response, failure: nil, assessment: assessment,
                            interface: observed.flatMap { EgressPathAssessment.safeInterface($0) ? $0 : nil })
                    }
                    guard token == self.generation, !Task.isCancelled else { group.cancelAll(); return }
                    self.rows.append(row); self.rows.sort { $0.family.rawValue < $1.family.rawValue }; self.checkedAt = Date()
                }
            }
            guard token == self.generation, !Task.isCancelled else { return }
            let final = await self.service.snapshot()
            guard token == self.generation, !Task.isCancelled else { return }
            guard before == EgressSessionContext(final), identity == model.egressContextIdentity else { self.invalidate(); return }
            self.status = self.rows.allSatisfy { $0.response != nil } ? "检测完成；路径结论仅针对检测服务的采样。" : "检测完成，部分地址族未取得结果。"
        }
    }
    func showSnapshotIfRequested() {
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true", ProcessInfo.processInfo.arguments.contains("--vpnnav-ui-demo-snapshot"),
              ProcessInfo.processInfo.arguments.contains("--vpnnav-ui-public-egress-snapshot") else { return }
        rows = [.init(family: .ipv4, response: .init(address: "8.8.8.8", remoteAddress: "1.1.1.1", usedProxy: false, cacheHit: false, milliseconds: 120), failure: nil, assessment: .vpnRoute, interface: "utun4"),
                .init(family: .ipv6, response: nil, failure: .transport, assessment: nil, interface: nil)]
        checkedAt = Date(); status = "界面演示数据；没有发起公网请求。"
    }
}
