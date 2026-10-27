import SwiftUI
import VPNNavigatorCore

/// Both cards use the same verified sampling source as the menu bar. The
/// clock only refreshes presentation/expiry; it never starts a network probe.
struct ConnectionOverviewCards: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let now = Date(), uptime = ProcessInfo.processInfo.systemUptime
            HStack(spacing: 12) {
                LiveTrafficCard(now: now, uptime: uptime)
                ConnectionProtectionCard(now: now, uptime: uptime)
            }
        }
    }
}

private struct LiveTrafficCard: View {
    @EnvironmentObject private var model: AppModel
    let now: Date
    let uptime: Double
    private var fresh: Bool { model.connected && model.menuTraffic.isFresh(at: now, uptime: uptime) }
    private var speed: TunnelSpeed? { fresh ? model.menuTraffic.current(at: now, uptime: uptime) : nil }
    private var points: [TunnelSpeedPoint] { fresh ? model.menuTraffic.visibleSamples(at: now, uptime: uptime) : [] }
    private func bytes(_ count: UInt64?) -> String {
        guard fresh, let count else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .file)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(L10n.text("实时流量"), systemImage: "waveform.path.ecg")
                    .font(.system(size: 17, weight: .semibold))
                Spacer(minLength: 4)
                Text(L10n.text("最近 60 秒")).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                rate(L10n.text("下载"), value: speed?.receivedPerSecond, color: GlassPalette.blue, symbol: "arrow.down")
                rate(L10n.text("上传"), value: speed?.sentPerSecond, color: .teal, symbol: "arrow.up")
            }
            TrafficRatePlot(points: points, uptime: uptime,
                placeholder: model.connected ? L10n.text("等待有效采样") : model.connecting ? L10n.text("连接后开始采样") : L10n.text("等待连接"))
                .frame(height: 68)
            HStack {
                Text(L10n.text("60 秒前")); Spacer(); Text(L10n.text("现在"))
            }.font(.system(size: 9)).foregroundStyle(.secondary)
                .padding(.leading, 48)
            Divider().opacity(0.2)
            HStack(spacing: 8) {
                Text(L10n.text("累计接收") + " " + bytes(model.traffic?.receivedBytes))
                Spacer(minLength: 2)
                Text(L10n.text("累计发送") + " " + bytes(model.traffic?.sentBytes))
            }.font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading).frame(height: 200, alignment: .topLeading)
        .glassCard(cornerRadius: 17)
        .accessibilityElement(children: .contain).accessibilityIdentifier("overview-live-traffic")
    }
    private func rate(_ title: String, value: Double?, color: Color, symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(TunnelSpeedFormat.string(value)).font(.system(size: 18, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.65)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title).accessibilityValue(TunnelSpeedFormat.string(value))
    }
}

private struct TrafficRatePlot: View {
    let points: [TunnelSpeedPoint]
    let uptime: Double
    let placeholder: String
    private var ceiling: Double { max(1_000, (points.map { max($0.speed.receivedPerSecond, $0.speed.sentPerSecond) }.max() ?? 0) * 1.15) }
    var body: some View {
        HStack(spacing: 5) {
            VStack(alignment: .trailing) {
                Text(TunnelSpeedFormat.string(ceiling))
                Spacer()
                Text("0")
            }.font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.6).frame(width: 43)
            ZStack {
                Canvas { context, size in
                    for fraction in [0.0, 0.5, 1.0] {
                        var grid = Path()
                        grid.move(to: .init(x: 0, y: size.height * CGFloat(fraction)))
                        grid.addLine(to: .init(x: size.width, y: size.height * CGFloat(fraction)))
                        context.stroke(grid, with: .color(.secondary.opacity(0.12)), style: .init(lineWidth: 0.5, dash: [2, 3]))
                    }
                    for upload in [false, true] {
                        let locations = points.map { point in
                            CGPoint(x: 2 + (size.width - 4) * CGFloat(max(0, min(1, (point.uptime - (uptime - 60)) / 60))),
                                    y: 2 + (size.height - 4) * CGFloat(1 - min(1, (upload ? point.speed.sentPerSecond : point.speed.receivedPerSecond) / ceiling)))
                        }
                        guard let first = locations.first, let last = locations.last else { continue }
                        let color: Color = upload ? .teal : GlassPalette.blue
                        if locations.count == 1 {
                            context.fill(Path(ellipseIn: CGRect(x: first.x - 2, y: first.y - 2, width: 4, height: 4)), with: .color(color))
                        } else {
                            var line = Path(); line.addLines(locations)
                            var area = line
                            area.addLine(to: .init(x: last.x, y: size.height))
                            area.addLine(to: .init(x: first.x, y: size.height)); area.closeSubpath()
                            context.fill(area, with: .color(color.opacity(0.065)))
                            context.stroke(line, with: .color(color), style: .init(lineWidth: 1.7, lineCap: .round, lineJoin: .round, dash: upload ? [3, 2] : []))
                        }
                    }
                }.clipped().accessibilityHidden(true)
                if points.isEmpty {
                    Text(placeholder).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("最近 60 秒的 VPN 流量趋势"))
        .accessibilityValue(points.isEmpty ? placeholder : L10n.format("有效采样 {0} 个，下载 {1}，上传 {2}", [String(points.count), TunnelSpeedFormat.string(points.last?.speed.receivedPerSecond), TunnelSpeedFormat.string(points.last?.speed.sentPerSecond)]))
    }
}

private struct ConnectionProtectionCard: View {
    @EnvironmentObject private var model: AppModel
    let now: Date
    let uptime: Double
    private var verified: Bool { model.overviewConnectionVerified(at: now, uptime: uptime) }
    private var recovery: Bool { model.overviewRecoveryNeeded }
    private var statusColor: Color { recovery || model.sessionState == .failed ? .orange : verified ? .green : model.connecting || model.routingModeSwitching ? GlassPalette.blue : .secondary }
    private var status: String {
        if model.stopping { return model.menuStatusTitle }
        if recovery { return L10n.text("需要恢复网络") }
        if model.routingModeSwitching { return L10n.text("路由切换中") }
        if model.connected { return verified ? L10n.text("已连接") : L10n.text("连接待核验") }
        return model.menuStatusTitle
    }
    private var duration: String {
        guard verified else { return "—" }
        let seconds = Int(model.menuTraffic.observedConnectedSeconds)
        return String(format: "%02d:%02d:%02d", seconds / 3_600, seconds / 60 % 60, seconds % 60)
    }
    private var protection: String {
        if recovery { return L10n.text("保护待恢复") }
        if verified && model.firewallActive { return L10n.text("PF 已生效") }
        if model.firewallActive { return L10n.text("PF 等待核验") }
        return L10n.text("保护未启用")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(L10n.text("连接状态与保护"), systemImage: "network")
                    .font(.system(size: 17, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 2)
                Button { model.showingPreferences = true } label: { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(L10n.text("连接偏好")).accessibilityLabel(L10n.text("连接偏好"))
                    .disabled(model.maintenanceInProgress || model.profileTransferInProgress)
            }
            HStack {
                Circle().fill(statusColor).frame(width: 6, height: 6)
                Text(status).font(.system(size: 13, weight: .medium)).foregroundStyle(statusColor).lineLimit(1)
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(duration).font(.system(size: 15, weight: .medium)).monospacedDigit()
                    Text(L10n.text("已观察连接")).font(.system(size: 9)).foregroundStyle(.secondary)
                }.help(L10n.text("仅统计应用已核验的连接时间，不计休眠及采样中断。"))
            }
            HStack(spacing: 10) {
                fact(L10n.text("实际路由"), value: verified ? model.activeRoutingMode?.title ?? L10n.text("待核验") : L10n.text("待核验"))
                fact(L10n.text("隧道协议栈"), value: verified ? model.activeIPStack?.title ?? L10n.text("待核验") : L10n.text("待核验"))
            }
            Divider().opacity(0.2)
            HStack(spacing: 8) {
                Toggle(L10n.text("下次连接保护"), isOn: Binding(get: { model.killSwitch }, set: { model.setOverviewProtection($0) }))
                    .toggleStyle(.switch).controlSize(.small).font(.system(size: 11)).tint(GlassPalette.blue)
                    .disabled(!model.canEditOverviewProtection).accessibilityIdentifier("overview-protection-toggle")
                Spacer(minLength: 2)
                Text(protection).font(.system(size: 10, weight: .medium))
                    .foregroundStyle(recovery ? .orange : verified && model.firewallActive ? .green : .secondary)
            }
            if recovery || model.sessionState == .failed {
                HStack(spacing: 8) {
                    Text(L10n.text("连接异常，请先检查并恢复网络。")).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                    Spacer(minLength: 0)
                    Button(recovery ? L10n.text("恢复网络") : L10n.text("一键排障…")) {
                        if recovery { Task { await model.disconnect() } }
                        else { model.showingTroubleshooting = true }
                    }.buttonStyle(ReferenceSecondaryButton()).controlSize(.small)
                        .disabled(model.busy || model.stopping || model.maintenanceInProgress || model.profileTransferInProgress)
                }
            } else {
                Text(verified && model.firewallActive ? L10n.text("PF 状态已核验；DNS 防泄漏需单独检测。") : L10n.text("实验性保护，作用于全局／规则模式；断开后可修改。"))
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).frame(height: 200, alignment: .topLeading)
            .glassCard(cornerRadius: 17)
            .accessibilityElement(children: .contain).accessibilityIdentifier("overview-connection-protection")
    }
    private func fact(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
