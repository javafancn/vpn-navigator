import Foundation

/// Monotonic durations only: no profile, endpoint, resolver or credential data.
public struct ConnectionStageTiming: Codable, Equatable, Sendable {
    public enum Stage: String, Codable, Sendable {
        case preparation, engineStartup, negotiation, dns, routePlanning, routeApplication, verification, resolver, total
    }
    public let stage: Stage
    public let milliseconds: Double
    public init(stage: Stage, milliseconds: Double) { self.stage = stage; self.milliseconds = milliseconds }
    public static func validated(_ values: [Self]?) -> [Self]? {
        guard let values, values.count <= 16, Set(values.map(\.stage)).count == values.count,
              values.allSatisfy({ $0.milliseconds.isFinite && (0...86_400_000).contains($0.milliseconds) }) else { return nil }
        return values
    }
    public var title: String {
        switch stage {
        case .preparation: return L10n.text("配置准备")
        case .engineStartup: return L10n.text("引擎启动")
        case .negotiation: return L10n.text("连接协商")
        case .dns: return L10n.text("DNS 准备")
        case .routePlanning: return L10n.text("路由规划")
        case .routeApplication: return L10n.text("路由应用")
        case .verification: return L10n.text("连接核验")
        case .resolver: return L10n.text("解析器生效")
        case .total: return L10n.text("连接总耗时")
        }
    }
}

public struct ConnectionPerformance: Sendable {
    private let started: Double
    private var previous: Double
    public private(set) var timings: [ConnectionStageTiming] = []
    public init(uptime: Double = ProcessInfo.processInfo.systemUptime) { started = uptime; previous = uptime }
    public mutating func record(_ stage: ConnectionStageTiming.Stage, uptime: Double = ProcessInfo.processInfo.systemUptime) {
        guard stage != .total, uptime.isFinite, uptime >= previous, timings.count < 16,
              !timings.contains(where: { $0.stage == .total }) else { return }
        timings.append(.init(stage: stage, milliseconds: ((uptime - previous) * 1_000_000).rounded() / 1000))
        previous = uptime
    }
    public mutating func complete(uptime: Double = ProcessInfo.processInfo.systemUptime) {
        guard uptime.isFinite, uptime >= previous, !timings.contains(where: { $0.stage == .total }) else { return }
        timings.append(.init(stage: .total, milliseconds: ((uptime - started) * 1_000_000).rounded() / 1000))
    }
}
