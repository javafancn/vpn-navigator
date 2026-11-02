import SwiftUI
import VPNNavigatorCore

struct ConnectionTimingView: View {
    let timings: [ConnectionStageTiming]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.text("连接阶段耗时"), systemImage: "stopwatch").font(.headline)
            if timings.isEmpty {
                Text(L10n.text("暂无阶段耗时，请使用更新后的助手连接一次。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(timings.indices, id: \.self) { index in
                HStack {
                    Text(timings[index].title)
                    Spacer()
                    Text(String(format: "%.1f ms", timings[index].milliseconds)).monospacedDigit()
                }.font(.caption).fontWeight(timings[index].stage == .total ? .semibold : .regular)
            }
        }.textSelection(.enabled)
    }
}
