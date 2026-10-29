import Foundation
import SystemConfiguration
import Darwin
import VPNNavigatorCore

/// Write-ahead DNS ownership record. Binary property-list values never become
/// shell input. Restore uses a compare-before-write check and fails on another
/// owner's change, retaining evidence for an explicit recovery attempt.
final class DNSRecoveryJournal {
    private struct Record: Codable {
        let service: String
        let before: [String: Data]
        var tunnel: String?
        var applied: [String: Data]?
        var serverProvided: Bool?
        var previousApplied: [String: Data]?
    }
    private let file: URL
    init(file: URL = URL(fileURLWithPath: "/var/run/vpn-navigator/dns.journal")) { self.file = file }
    private let store = SCDynamicStoreCreate(nil, "VPNNavigator.DNSRecovery" as CFString, nil, nil)
    var exists: Bool { FileManager.default.fileExists(atPath: file.path) }
    private(set) var primaryService: String?

    func begin(serviceOverride: String? = nil) throws {
        guard !exists, let store else { throw DNSJournalError.unavailable }
        let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        let global6 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv6" as CFString) as? [String: Any]
        guard let service = serviceOverride ?? (global?["PrimaryService"] as? String) ?? (global6?["PrimaryService"] as? String),
              DNSRecoveryPolicy.validServiceID(service) else { throw DNSJournalError.unavailable }
        var keys = [primaryKey(service)]
        let owned = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/openvpn-utun[0-9]+/(DNS|DnsBackup)" as CFString) as? [String] ?? []
        guard owned.count < 128 else { throw DNSJournalError.unavailable }
        keys += owned
        try save(.init(service: service, before: try snapshot(keys), tunnel: nil, applied: nil))
        primaryService = service
    }
    func commit(tunnel: String) throws {
        guard DNSRecoveryPolicy.validTunnel(tunnel) else { throw DNSJournalError.unavailable }
        var record = try load()
        record.tunnel = tunnel
        record.applied = try snapshot(keys(record))
        record.serverProvided = true
        try save(record)
    }
    /// Pin the managed global resolver policy, retaining split-DNS dictionaries.
    /// Record both known-owned values before modifying the dynamic store so a
    /// crash on either side of the write remains recoverable without guessing.
    func prepareManaged(tunnel: String, has4: Bool, has6: Bool) throws -> [String] {
        try confirm(tunnel: tunnel)
        var record = try load()
        let primary = primaryKey(record.service)
        func dictionary(_ data: Data?) throws -> [String: Any] {
            guard let data else { return [:] }
            return try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] ?? [:]
        }
        let scoped = try dictionary(record.applied?["State:/Network/Service/openvpn-\(tunnel)/DNS"])
        var global = try dictionary(record.applied?[primary])
        let split = !(scoped["SupplementalMatchDomains"] as? [String] ?? []).isEmpty
        let provided = record.serverProvided == true && !split ? global["ServerAddresses"] as? [String] ?? [] : []
        let servers = try ManagedDNSPolicy.servers(provided: provided, has4: has4, has6: has6)
        let scopedServers = split ? try ManagedDNSPolicy.servers(provided: scoped["ServerAddresses"] as? [String] ?? [], has4: has4, has6: has6) : []
        if global["ServerAddresses"] as? [String] != servers {
            global["ServerAddresses"] = servers
            global["SearchOrder"] = 5000
            let next = try PropertyListSerialization.data(fromPropertyList: global, format: .binary, options: 0)
            record.previousApplied = record.applied
            record.applied?[primary] = next
            try save(record)
            guard let store, SCDynamicStoreSetValue(store, primary as CFString, global as CFDictionary) else { throw DNSJournalError.unavailable }
            try confirm(tunnel: tunnel)
            record.previousApplied = nil
            try save(record)
            _ = try RouteExecutor.command("/usr/bin/dscacheutil", ["-flushcache"])
        }
        return Array(Set(servers + scopedServers)).sorted()
    }
    func confirm(tunnel: String) throws {
        guard DNSRecoveryPolicy.validTunnel(tunnel) else { throw DNSJournalError.unavailable }
        var record = try load()
        if let applied = record.applied {
            guard record.tunnel == tunnel else { throw DNSJournalError.conflict }
            let current = try snapshot(keys(record))
            for key in keys(record) {
                guard try equal(current[key], applied[key]) else { throw DNSJournalError.conflict }
            }
        } else {
            // A server may not provide DNS. Commit a no-op only when no tracked
            // DNS value changed; never infer ownership of an unfinished hook.
            record.tunnel = tunnel
            let current = try snapshot(keys(record))
            for key in keys(record) {
                guard try equal(current[key], record.before[key]) else { throw DNSJournalError.conflict }
            }
            record.applied = current; try save(record)
        }
    }
    func restore() throws {
        guard exists else { return }
        let record = try load(), keys = keys(record)
        let current = try snapshot(keys)
        var set: [String: Any] = [:], remove: [String] = []
        for key in keys {
            let original = record.before[key], applied = record.applied?[key], now = current[key]
            let previousMatches = try record.previousApplied.map { try equal(now, $0[key]) } ?? false
            let decision = DNSRecoveryPolicy.decide(currentMatchesOriginal: try equal(now, original),
                currentMatchesApplied: try equal(now, applied) || previousMatches, committed: record.applied != nil)
            switch decision {
            case .unchanged: continue
            case .conflict: throw DNSJournalError.conflict
            case .restoreOwnedValue:
                if let original { set[key] = try PropertyListSerialization.propertyList(from: original, options: [], format: nil) }
                else { remove.append(key) }
            }
        }
        guard let store, SCDynamicStoreSetMultiple(store, set as CFDictionary, remove as CFArray, nil) else {
            throw DNSJournalError.unavailable
        }
        // Verify before deleting the only recovery record.
        let restored = try snapshot(keys)
        for key in keys {
            guard try equal(restored[key], record.before[key]) else { throw DNSJournalError.conflict }
        }
        try FileManager.default.removeItem(at: file)
        primaryService = nil
    }
    private func primaryKey(_ service: String) -> String { "Setup:/Network/Service/\(service)/DNS" }
    private func keys(_ record: Record) -> [String] {
        var keys = [primaryKey(record.service)]
        if let tunnel = record.tunnel {
            keys += ["State:/Network/Service/openvpn-\(tunnel)/DNS", "State:/Network/Service/openvpn-\(tunnel)/DnsBackup"]
        }
        return keys
    }
    private func snapshot(_ keys: [String]) throws -> [String: Data] {
        guard let store else { throw DNSJournalError.unavailable }
        var values: [String: Data] = [:]
        for key in keys {
            if let value = SCDynamicStoreCopyValue(store, key as CFString) {
                values[key] = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
            }
        }
        return values
    }
    private func equal(_ a: Data?, _ b: Data?) throws -> Bool {
        if a == nil || b == nil { return a == b }
        let lhs = try PropertyListSerialization.propertyList(from: a!, options: [], format: nil) as AnyObject
        let rhs = try PropertyListSerialization.propertyList(from: b!, options: [], format: nil) as AnyObject
        return CFEqual(lhs, rhs)
    }
    private func load() throws -> Record {
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0,
              ((attrs[.size] as? NSNumber)?.intValue ?? Int.max) < 2_000_000 else { throw DNSJournalError.unavailable }
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: file))
        guard DNSRecoveryPolicy.validServiceID(record.service),
              record.tunnel.map(DNSRecoveryPolicy.validTunnel) ?? true else { throw DNSJournalError.unavailable }
        let allowed = Set(keys(record))
        guard Set(record.applied?.keys.map { $0 } ?? []).isSubset(of: allowed),
              Set(record.previousApplied?.keys.map { $0 } ?? []).isSubset(of: allowed), record.before.count < 130 else {
            throw DNSJournalError.unavailable
        }
        return record
    }
    private func save(_ record: Record) throws {
        let bytes = try JSONEncoder().encode(record)
        guard bytes.count < 2_000_000 else { throw DNSJournalError.unavailable }
        try bytes.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
enum DNSJournalError: Error, LocalizedError {
    case unavailable, conflict
    var errorDescription: String? {
        switch self {
        case .unavailable: return "无法安全记录或校验 DNS 状态，已停止连接。"
        case .conflict: return "DNS 状态已改变或事务尚未确认。已保留恢复记录，请核验网络后重试安全恢复。"
        }
    }
}
