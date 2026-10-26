import SwiftUI
import VPNNavigatorCore

enum ConnectionHistoryDisplay {
    static func bytes(_ value: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .binary) }
    static func rate(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "等待采样" }
        return ByteCountFormatter.string(fromByteCount: Int64(min(value, 9_000_000_000_000_000_000)), countStyle: .binary) + "/s"
    }
    static func duration(_ value: Double) -> String {
        let seconds = Int(max(0, min(value.isFinite ? value : 0, 1_000_000_000)))
        return "\(seconds / 3600):" + String(format: "%02d:%02d", seconds / 60 % 60, seconds % 60)
    }
}

struct ConnectionQualityCard: View {
    let snapshot: ConnectionQualitySnapshot
    var body: some View {
        HStack(spacing: 18) {
            metric("下载速率", ConnectionHistoryDisplay.rate(snapshot.verified ? snapshot.receivedPerSecond : nil))
            metric("上传速率", ConnectionHistoryDisplay.rate(snapshot.verified ? snapshot.sentPerSecond : nil))
            metric("已采集连接时长", ConnectionHistoryDisplay.duration(snapshot.observedConnectedSeconds))
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).glassCard(cornerRadius: 16)
    }
    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 18, weight: .semibold, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.8)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ConnectionHistoryView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var expanded = Set<UUID>()
    @State private var onlyFailures = false
    @State private var confirmingClear = false
    private var controller: ConnectionHistoryController { model.connectionHistory }
    private var rows: [ConnectionHistoryRecord] { controller.state.records.filter { !onlyFailures || $0.outcome == .failed } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("会话质量与连接历史", systemImage: "clock.arrow.circlepath").font(.system(size: 23, weight: .bold))
                Spacer()
                Toggle("仅看失败", isOn: $onlyFailures).toggleStyle(.checkbox).font(.callout)
            }
            Text("仅统计已采集区间，不补算退出、休眠或失联期间的数据；采集流量不作为计费依据。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            ConnectionQualityCard(snapshot: controller.state.quality)
            HStack(spacing: 20) {
                Toggle("本机记录连接历史", isOn: Binding(get: { controller.state.preferences.enabled }, set: { value in
                    var preferences = controller.state.preferences; preferences.enabled = value
                    Task { await controller.configure(preferences) }
                }))
                Spacer()
                Picker("保留", selection: Binding(get: { controller.state.preferences.retentionDays }, set: { value in
                    var preferences = controller.state.preferences; preferences.retentionDays = value
                    Task { await controller.configure(preferences) }
                })) { Text("7 天").tag(7); Text("30 天").tag(30); Text("90 天").tag(90) }.frame(width: 150)
            }.font(.callout).disabled(controller.busy || ProcessInfo.processInfo.arguments.contains("--vpnnav-ui-demo-snapshot"))
            if let problem = controller.actionProblem ?? controller.state.problem {
                Label(problem, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if rows.isEmpty {
                        Text(onlyFailures ? "暂无已记录的失败会话。" : controller.state.preferences.enabled ? "暂无连接历史，下一次会话将开始记录。" : "记录已暂停；开启后开始采集，已有历史按所选期限保留。")
                            .font(.callout).foregroundStyle(.secondary).padding(20)
                    }
                    ForEach(rows) { row in
                        DisclosureGroup(isExpanded: Binding(get: { expanded.contains(row.id) }, set: { value in
                            if value { expanded.insert(row.id) } else { expanded.remove(row.id) }
                        })) {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("采集时长 " + ConnectionHistoryDisplay.duration(row.observedConnectedSeconds))
                                    Spacer()
                                    Text("↓ " + ConnectionHistoryDisplay.bytes(row.receivedBytes) + "   ↑ " + ConnectionHistoryDisplay.bytes(row.sentBytes))
                                }.font(.caption).foregroundStyle(.secondary)
                                ForEach(row.events) { event in
                                    HStack(alignment: .top, spacing: 12) {
                                        Text(event.date, style: .time).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).frame(width: 76, alignment: .leading)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(event.kind.title + (event.mode.map { " · " + $0.title } ?? "")).font(.system(size: 13))
                                            if let failure = event.failure { Text(failure.summary).font(.caption).foregroundStyle(.secondary) }
                                        }
                                        Spacer(minLength: 0)
                                    }
                                }
                            }.padding(.top, 10)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(model.profiles.first(where: { $0.id == row.profileID })?.name ?? "已移除或未知配置").font(.system(size: 15, weight: .semibold)).lineLimit(1)
                                    Text(row.beganAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(row.outcome.title).font(.caption).foregroundStyle(row.outcome == .failed ? Color.orange : Color.secondary)
                            }
                        }.padding(14).glassCard(cornerRadius: 12)
                    }
                }.padding(4)
            }.frame(height: 310)
            HStack {
                Button("清空并暂停记录…", role: .destructive) { confirmingClear = true }.buttonStyle(ReferenceSecondaryButton()).disabled(controller.busy || ProcessInfo.processInfo.arguments.contains("--vpnnav-ui-demo-snapshot"))
                Text("仅本机保存，最多 200 次会话").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("完成") { dismiss() }.buttonStyle(ReferencePrimaryButton()).disabled(controller.busy)
            }
        }.padding(24).frame(width: 780).background(GlassAtmosphere()).interactiveDismissDisabled(controller.busy)
            .task { await controller.start(); if let first = rows.first { expanded.insert(first.id) } }
            .confirmationDialog("清空全部连接历史并暂停后续记录？", isPresented: $confirmingClear) {
                Button("清空并暂停", role: .destructive) { Task { await controller.clearAndPause() } }
                Button("取消", role: .cancel) { }
            } message: { Text("不会断开 VPN。清空不可撤销；可随时重新开启记录。此操作不清除独立的故障诊断日志。") }
    }
}
