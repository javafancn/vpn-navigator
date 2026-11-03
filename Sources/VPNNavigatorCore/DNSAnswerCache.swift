import Foundation

/// A small session-local wire cache. Exact request bytes (except ID) and
/// transport isolate EDNS/CD/DO, question case and UDP truncation semantics.
/// Only positive A/AAAA replies are cached. Errors, zero TTL, DNSSEC signatures
/// and authenticated DNS messages retain their upstream behavior.
public struct DNSAnswerCache {
    public struct Key: Hashable {
        let wire: Data
        let tcp: Bool
    }
    private struct Entry {
        let packet: Data
        let stored: TimeInterval
        let expires: TimeInterval
        let ttls: [(offset: Int, value: UInt32)]
        var used: UInt64
    }
    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0
    private var byteCount = 0
    private let capacity: Int
    private let maximumBytes: Int
    public init(capacity: Int = 512, maximumBytes: Int = 2_000_000) {
        self.capacity = max(0, capacity); self.maximumBytes = max(0, maximumBytes)
    }
    public static func key(for request: Data, tcp: Bool) -> Key? {
        guard request.count <= 4096, let q = DNSQuestion(request),
              request[6...9].allSatisfy({ $0 == 0 }) else { return nil }
        // Only ordinary queries, with zero or one EDNS OPT additional record.
        let count = Int(request[10]) << 8 | Int(request[11])
        if count == 0 {
            guard q.end == request.count else { return nil }
        } else {
            guard count == 1, q.end + 11 <= request.count, request[q.end] == 0,
                  request[q.end + 1] == 0, request[q.end + 2] == 41,
                  q.end + 11 + Int(request[q.end + 9]) * 256 + Int(request[q.end + 10]) == request.count else { return nil }
        }
        return Key(wire: Data(request.dropFirst(2)), tcp: tcp)
    }
    public mutating func answer(for key: Key, request: Data, now: TimeInterval) -> Data? {
        guard now.isFinite, var entry = entries[key] else { return nil }
        guard now >= entry.stored, now < entry.expires else { remove(key); return nil }
        clock &+= 1; entry.used = clock; entries[key] = entry
        let age = UInt32(min(Double(UInt32.max), floor(now - entry.stored)))
        var result = entry.packet
        result[0] = request[0]; result[1] = request[1]
        for ttl in entry.ttls {
            let value = ttl.value > age ? ttl.value - age : 0
            for i in 0..<4 { result[ttl.offset + i] = UInt8((value >> (24 - i * 8)) & 255) }
        }
        return result
    }
    public mutating func insert(_ packet: Data, for key: Key, request: Data, now: TimeInterval) {
        guard capacity > 0, now.isFinite, packet.count <= 16_384,
              let q = DNSQuestion(request), [1, 28].contains(q.type),
              q.accepts(packet, request: request), packet[2] & 2 == 0, packet[3] & 15 == 0,
              Int(packet[6]) * 256 + Int(packet[7]) > 0,
              let ttls = Self.ttls(packet), let minimum = ttls.map(\.value).min(), minimum > 0 else { return }
        remove(key)
        let size = packet.count + key.wire.count
        guard size <= maximumBytes else { return }
        // Expired entries go first; LRU keeps both allocation and lookup bounded.
        for stale in entries.filter({ $0.value.expires <= now }).map(\.key) { remove(stale) }
        while entries.count >= capacity || byteCount + size > maximumBytes {
            guard let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key else { return }
            remove(oldest)
        }
        clock &+= 1
        entries[key] = Entry(packet: packet, stored: now, expires: now + Double(min(minimum, 300)), ttls: ttls, used: clock)
        byteCount += size
    }
    private mutating func remove(_ key: Key) {
        if let old = entries.removeValue(forKey: key) { byteCount -= old.packet.count + key.wire.count }
    }
    /// Locate RR TTLs without rewriting compression offsets or OPT flags.
    private static func ttls(_ data: Data) -> [(offset: Int, value: UInt32)]? {
        guard let question = DNSQuestion(data, response: true) else { return nil }
        let b = [UInt8](data)
        func word(_ i: Int) -> Int { Int(b[i]) * 256 + Int(b[i + 1]) }
        let records = word(6) + word(8) + word(10)
        guard records <= 256 else { return nil }
        var p = question.end, result: [(offset: Int, value: UInt32)] = []
        for _ in 0..<records {
            var labels = 0
            while true {
                guard p < b.count, labels <= 127 else { return nil }
                let n = Int(b[p]); labels += 1
                if n == 0 { p += 1; break }
                if n & 0xc0 == 0xc0 {
                    guard p + 1 < b.count, ((n & 63) << 8 | Int(b[p + 1])) < p else { return nil }
                    p += 2; break
                }
                guard n <= 63, p + 1 + n < b.count else { return nil }
                p += n + 1
            }
            guard p + 10 <= b.count else { return nil }
            let type = word(p), length = word(p + 8)
            guard p + 10 + length <= b.count, ![24, 46, 249, 250].contains(type) else { return nil }
            let ttl = b[(p + 4)..<(p + 8)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            if type == 41 {
                guard ttl >> 24 == 0 else { return nil } // Extended RCODE.
            } else {
                guard ttl < 0x80000000 else { return nil }
                result.append((p + 4, ttl))
            }
            p += 10 + length
        }
        return p == b.count ? result : nil
    }
}
