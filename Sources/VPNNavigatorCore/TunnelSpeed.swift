import Foundation

public struct TunnelSpeed: Equatable, Sendable {
    public let receivedPerSecond: Double
    public let sentPerSecond: Double
}

public struct TunnelSpeedPoint: Equatable, Sendable {
    public let uptime: Double
    public let speed: TunnelSpeed
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
    public private(set) var samples: [TunnelSpeedPoint] = []
    /// Observed connected intervals only; never infer connection time while
    /// this application was absent, sleeping or unable to verify the session.
    public private(set) var observedConnectedSeconds: Double = 0
    public init() {}
    public mutating func reset() {
        previous = nil; speed = nil; samples = []; observedConnectedSeconds = 0
    }
    public mutating func observe(_ report: SessionReport, at date: Date = Date(), uptime: Double = ProcessInfo.processInfo.systemUptime) {
        guard date.timeIntervalSince1970.isFinite, uptime.isFinite, uptime >= 0,
              ConnectionObservation(report).verifiedConnection,
              let profile = report.activeProfileID, let attempt = report.attemptID,
              let traffic = report.traffic else { reset(); return }
        let next = Sample(profile: profile, attempt: attempt, traffic: traffic, date: date, uptime: uptime)
        guard let old = previous, old.profile == profile, old.attempt == attempt else {
            reset(); previous = next; return
        }
        let elapsed = uptime - old.uptime, wall = date.timeIntervalSince(old.date)
        guard elapsed >= 0, elapsed <= 5, wall >= 0, wall <= 5,
              abs(wall - elapsed) <= 2 else { previous = next; speed = nil; samples = []; return }
        // Additional UI refreshes must not divide by tiny intervals or consume
        // the baseline needed by the regular one-second poll.
        guard traffic.receivedBytes >= old.traffic.receivedBytes,
              traffic.sentBytes >= old.traffic.sentBytes else {
            observedConnectedSeconds += elapsed
            previous = next; speed = nil; samples = []; return
        }
        guard elapsed >= 0.5 else { return }
        observedConnectedSeconds += elapsed
        speed = .init(receivedPerSecond: Double(traffic.receivedBytes - old.traffic.receivedBytes) / elapsed,
                      sentPerSecond: Double(traffic.sentBytes - old.traffic.sentBytes) / elapsed)
        previous = next
        if let speed { samples.append(.init(uptime: uptime, speed: speed)) }
        samples.removeAll { uptime - $0.uptime > 60 }
        if samples.count > 121 { samples.removeFirst(samples.count - 121) }
    }
    public func current(at date: Date = Date(), uptime: Double = ProcessInfo.processInfo.systemUptime) -> TunnelSpeed? {
        isFresh(at: date, uptime: uptime) ? speed : nil
    }
    public func visibleSamples(at date: Date = Date(), uptime: Double = ProcessInfo.processInfo.systemUptime) -> [TunnelSpeedPoint] {
        guard isFresh(at: date, uptime: uptime) else { return [] }
        return samples.filter { (0...60).contains(uptime - $0.uptime) }
    }
    public func isFresh(at date: Date = Date(), uptime: Double = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard let previous, uptime.isFinite, date.timeIntervalSince1970.isFinite else { return false }
        let age = uptime - previous.uptime, wall = date.timeIntervalSince(previous.date)
        return (0...5).contains(age) && (0...5).contains(wall) && abs(wall - age) <= 2
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
