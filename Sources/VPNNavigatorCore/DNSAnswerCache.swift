import Foundation

/// A small session-local wire cache. Exact request bytes (except ID) and
/// transport isolate EDNS/CD/DO, question case and UDP truncation semantics.
/// Only positive A/AAAA/SVCB/HTTPS replies and RFC 2308 SOA NODATA replies are
/// cached. Errors, referrals, zero TTL, DNSSEC signatures and authenticated
/// DNS messages retain their upstream behavior.
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
              let q = DNSQuestion(request), [1, 28, 64, 65].contains(q.type),
              q.accepts(packet, request: request), packet[2] & 2 == 0, packet[3] & 15 == 0,
              let parsed = Self.ttls(packet), parsed.minimum > 0 else { return }
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
        entries[key] = Entry(packet: packet, stored: now, expires: now + Double(min(parsed.minimum, 300)), ttls: parsed.ttls, used: clock)
        byteCount += size
    }
    private mutating func remove(_ key: Key) {
        if let old = entries.removeValue(forKey: key) { byteCount -= old.packet.count + key.wire.count }
    }
    /// Locate RR TTLs without rewriting compression offsets or OPT flags.
    /// Authority SOA records also bound negative/CNAME caching by SOA.MINIMUM.
    private static func ttls(_ data: Data) -> (ttls: [(offset: Int, value: UInt32)], minimum: UInt32)? {
        guard let question = DNSQuestion(data, response: true) else { return nil }
        let b = [UInt8](data)
        func word(_ i: Int) -> Int { Int(b[i]) * 256 + Int(b[i + 1]) }
        func long(_ i: Int) -> UInt32 { b[i..<(i + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } }
        func skipName(from start: Int) -> Int? {
            var p = start, labels = 0
            while true {
                guard p < b.count, labels <= 127 else { return nil }
                let n = Int(b[p]); labels += 1
                if n == 0 { return p + 1 }
                if n & 0xc0 == 0xc0 {
                    guard p + 1 < b.count, ((n & 63) << 8 | Int(b[p + 1])) < p else { return nil }
                    return p + 2
                }
                guard n <= 63, p + 1 + n < b.count else { return nil }
                p += n + 1
            }
        }
        let answers = word(6), authorities = word(8), additionals = word(10)
        let records = answers + authorities + additionals
        guard (answers > 0 || authorities > 0), records <= 256 else { return nil }
        var p = question.end, result: [(offset: Int, value: UInt32)] = []
        var minimum = UInt32.max
        var hasAuthoritySOA = false
        for index in 0..<records {
            guard let next = skipName(from: p), next + 10 <= b.count else { return nil }
            p = next
            let type = word(p), cls = word(p + 2), length = word(p + 8)
            let rdataStart = p + 10, rdataEnd = rdataStart + length
            guard rdataEnd <= b.count, ![24, 46, 249, 250].contains(type) else { return nil }
            var ttl = long(p + 4)
            if type == 41 {
                guard index >= answers + authorities, ttl >> 24 == 0 else { return nil } // Extended RCODE.
            } else {
                guard cls == 1, ttl < 0x80000000 else { return nil }
                if index >= answers && index < answers + authorities && type == 6 {
                    guard let rname = skipName(from: rdataStart),
                          let tail = skipName(from: rname),
                          tail + 20 == rdataEnd else { return nil }
                    let soaMinimum = long(tail + 16)
                    guard soaMinimum < 0x80000000 else { return nil }
                    // Age the SOA's wire TTL from the negative lifetime too;
                    // limiting only local expiry lets downstream caches extend it.
                    ttl = min(ttl, soaMinimum)
                    hasAuthoritySOA = true
                }
                result.append((p + 4, ttl))
                minimum = min(minimum, ttl)
            }
            p = rdataEnd
        }
        guard p == b.count, answers > 0 || hasAuthoritySOA, !result.isEmpty, minimum < UInt32.max else { return nil }
        return (result, minimum)
    }
}
