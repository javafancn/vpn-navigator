import Foundation

/// Plots real OpenVPN cumulative-counter deltas, not demo measurements.
public struct TrafficTrend: Sendable {
    public private(set) var samples: [Double] = []
    private var previous: UInt64?
    private let limit: Int

    public init(limit: Int = 24) {
        self.limit = max(3, limit)
    }
    public mutating func record(cumulativeBytes: UInt64) {
        guard let last = previous else {
            previous = cumulativeBytes
            return
        }
        previous = cumulativeBytes
        guard cumulativeBytes >= last else {
            samples.removeAll()
            return
        }
        samples.append(Double(cumulativeBytes - last))
        if samples.count > limit { samples.removeFirst(samples.count - limit) }
    }
    public mutating func reset() {
        samples.removeAll()
        previous = nil
    }
}
