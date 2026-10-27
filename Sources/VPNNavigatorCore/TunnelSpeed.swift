import Foundation

public struct TunnelSpeed: Equatable, Sendable {
    public let receivedPerSecond: Double
    public let sentPerSecond: Double
}

/// In-memory throughput from authenticated helper counters. Session changes,
/// counter resets and observation gaps establish a new baseline, never a spike.
public struct TunnelSpeedTracker: Sendable {
    private struct Sample: Sendable {
        let profile: UUID
        let attempt: UUID
        let traffic: TunnelTraffic
        let date: Date
        let uptime: Double
    }
    private var previous: Sample?
    private var speed: TunnelSpeed?
    public init() {}
    public mutating func reset() { previous = nil; speed = nil }
    public mutating func observe(_ report: SessionReport, at date: Date = Date(), uptime: Double = ProcessInfo.processInfo.systemUptime) {
        guard date.timeIntervalSince1970.isFinite, uptime.isFinite, uptime >= 0,
              ConnectionObservation(report).verifiedConnection,
              let profile = report.activeProfileID, let attempt = report.attemptID,
              let traffic = report.traffic else { reset(); return }
        let next = Sample(profile: profile, attempt: attempt, traffic: traffic, date: date, uptime: uptime)
        guard let old = previous, old.profile == profile, old.attempt == attempt else {
            previous = next; speed = nil; return
        }
        let elapsed = uptime - old.uptime, wall = date.timeIntervalSince(old.date)
        guard elapsed >= 0, elapsed <= 5, wall >= 0, wall <= 5,
              abs(wall - elapsed) <= 2,
              traffic.receivedBytes >= old.traffic.receivedBytes,
              traffic.sentBytes >= old.traffic.sentBytes else { previous = next; speed = nil; return }
        // Additional UI refreshes must not divide by tiny intervals or consume
        // the baseline needed by the regular one-second poll.
        guard elapsed >= 0.5 else { return }
        speed = .init(receivedPerSecond: Double(traffic.receivedBytes - old.traffic.receivedBytes) / elapsed,
                      sentPerSecond: Double(traffic.sentBytes - old.traffic.sentBytes) / elapsed)
        previous = next
    }
    public func current(at date: Date = Date(), uptime: Double = ProcessInfo.processInfo.systemUptime) -> TunnelSpeed? {
        guard let previous, uptime.isFinite, date.timeIntervalSince1970.isFinite else { return nil }
        let age = uptime - previous.uptime, wall = date.timeIntervalSince(previous.date)
        guard (0...5).contains(age), (0...5).contains(wall), abs(wall - age) <= 2 else { return nil }
        return speed
    }
}

public enum TunnelSpeedFormat {
    /// Decimal byte units, deliberately compact enough for a fixed menu-bar
    /// slot. A missing reading is distinct from a measured idle tunnel.
    public static func string(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond, bytesPerSecond.isFinite, bytesPerSecond >= 0 else { return "—" }
        let units = ["B/s", "KB/s", "MB/s", "GB/s", "TB/s", "PB/s", "EB/s"]
        var value = bytesPerSecond, unit = 0
        while value >= 999.5, unit < units.count - 1 { value /= 1_000; unit += 1 }
        let format = unit == 0 || value >= 100 ? "%.0f" : "%.1f"
        return String(format: format, locale: Locale(identifier: "en_US_POSIX"), value) + " " + units[unit]
    }
}
