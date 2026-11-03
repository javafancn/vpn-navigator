#if DEBUG
import Foundation
import SystemConfiguration
import VPNNavigatorCore

/// Exercises real SCDynamicStore and the write-ahead record on a synthetic
/// service UUID. It never changes the DNS of an existing network service.
enum DNSJournalSelfTest {
    static func run() throws {
        guard let store = SCDynamicStoreCreate(nil, "VPNNavigator.DNSJournalSelfTest" as CFString, nil, nil) else { throw DNSJournalError.unavailable }
        let id = UUID().uuidString
        let key = "Setup:/Network/Service/\(id)/DNS" as CFString
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { SCDynamicStoreRemoveValue(store, key); try? FileManager.default.removeItem(at: folder) }
        let original = ["ServerAddresses": ["192.0.2.53", "2001:db8::53"]] as CFDictionary
        let applied = ["ServerAddresses": ["198.51.100.53", "2001:db8:1::53"]] as CFDictionary
        let other = ["ServerAddresses": ["203.0.113.53"]] as CFDictionary
        var cacheFlushes = 0
        let journal = DNSRecoveryJournal(file: folder.appendingPathComponent("dns.journal"), flushCache: { cacheFlushes += 1 })
        guard SCDynamicStoreSetValue(store, key, original) else { throw DNSJournalError.unavailable }
        try journal.begin(serviceOverride: id)
        guard try journal.physicalResolvers() == ["192.0.2.53", "2001:db8::53"] else { throw DNSJournalError.conflict }
        guard SCDynamicStoreSetValue(store, key, applied) else { throw DNSJournalError.unavailable }
        try journal.commit(tunnel: "utun9999")
        try journal.confirm(tunnel: "utun9999")
        try journal.restore()
        guard CFEqual(SCDynamicStoreCopyValue(store, key), original), !journal.exists else { throw DNSJournalError.conflict }

        // Exercise native server application, not just an externally edited store.
        try journal.begin(serviceOverride: id)
        try journal.applyProvided(tunnel: "utun9999", servers: ["223.5.5.5"], search: ["corp.test"], match: [])
        guard try journal.prepareManaged(tunnel: "utun9999", has4: true, has6: false) == ["223.5.5.5"] else { throw DNSJournalError.conflict }
        try journal.restore()
        guard CFEqual(SCDynamicStoreCopyValue(store, key), original) else { throw DNSJournalError.conflict }

        // DHCP-only DNS must be captured before the hook, without writing or
        // claiming ownership of the physical service's State dictionary.
        let stateKey = "State:/Network/Service/\(id)/DNS" as CFString
        SCDynamicStoreRemoveValue(store, key)
        let dhcp = ["ServerAddresses": ["192.168.1.1"]] as CFDictionary
        SCDynamicStoreSetValue(store, stateKey, dhcp)
        defer { SCDynamicStoreRemoveValue(store, stateKey) }
        try journal.begin(serviceOverride: id)
        try journal.applyProvided(tunnel: "utun9999", servers: ["10.8.0.53"], search: [], match: [])
        _ = try journal.prepareManaged(tunnel: "utun9999", has4: true, has6: false)
        guard try journal.physicalResolvers() == ["192.168.1.1"] else { throw DNSJournalError.conflict }
        try journal.publishManagedResolver(tunnel: "utun9999", port: 53)
        let conventional = SCDynamicStoreCopyValue(store, key) as? [String: Any]
        guard conventional?["ServerAddresses"] as? [String] == ["127.0.0.1"], conventional?["ServerPort"] == nil else { throw DNSJournalError.conflict }
        try journal.restore()
        guard SCDynamicStoreCopyValue(store, key) == nil, CFEqual(SCDynamicStoreCopyValue(store, stateKey), dhcp) else { throw DNSJournalError.conflict }
        SCDynamicStoreRemoveValue(store, stateKey)
        SCDynamicStoreSetValue(store, key, original)

        // Session loopback port publication must be reversible on a live
        // mode switch and an external DNS edit must still be refused.
        try journal.begin(serviceOverride: id)
        try journal.applyProvided(tunnel: "utun9999", servers: ["10.8.0.53"], search: [], match: [])
        _ = try journal.prepareManaged(tunnel: "utun9999", has4: true, has6: false)
        try journal.publishManagedResolver(tunnel: "utun9999", port: 54321)
        let check = try journal.verificationCheck(tunnel: "utun9999")
        try check()
        let firstPortFlushes = cacheFlushes
        let proxyDNS = SCDynamicStoreCopyValue(store, key) as? [String: Any]
        guard proxyDNS?["ServerAddresses"] as? [String] == ["127.0.0.1"], proxyDNS?["ServerPort"] as? Int == 54321,
              try journal.managedGlobalServers() == ["10.8.0.53"] else { throw DNSJournalError.conflict }
        try journal.publishManagedResolver(tunnel: "utun9999", port: nil)
        do { try check(); throw DNSJournalError.unavailable }
        catch DNSJournalError.conflict { }
        guard cacheFlushes == firstPortFlushes + 1 else { throw DNSJournalError.unavailable }
        let fullDNS = SCDynamicStoreCopyValue(store, key) as? [String: Any]
        guard fullDNS?["ServerAddresses"] as? [String] == ["10.8.0.53"], fullDNS?["ServerPort"] == nil else { throw DNSJournalError.conflict }
        try journal.publishManagedResolver(tunnel: "utun9999", port: 54322)
        SCDynamicStoreSetValue(store, key, other)
        do { try journal.restore(); throw DNSJournalError.unavailable }
        catch DNSJournalError.conflict { }
        guard journal.exists, CFEqual(SCDynamicStoreCopyValue(store, key), other) else { throw DNSJournalError.conflict }
        SCDynamicStoreSetValue(store, key, ["ServerAddresses": ["127.0.0.1"], "ServerPort": 54322, "SearchOrder": 5000] as CFDictionary)
        try journal.restore()
        guard CFEqual(SCDynamicStoreCopyValue(store, key), original), !journal.exists else { throw DNSJournalError.conflict }

        // A pre-VPN user port belongs to the original DNS dictionary, not
        // to a new managed fallback that happens to use the same addresses.
        let customPort = ["ServerAddresses": ["1.1.1.1", "9.9.9.9"], "ServerPort": 5353] as CFDictionary
        SCDynamicStoreSetValue(store, key, customPort)
        try journal.begin(serviceOverride: id)
        _ = try journal.prepareManaged(tunnel: "utun9999", has4: true, has6: false)
        let standardDNS = SCDynamicStoreCopyValue(store, key) as? [String: Any]
        guard standardDNS?["ServerPort"] == nil else { throw DNSJournalError.conflict }
        try journal.restore()
        guard CFEqual(SCDynamicStoreCopyValue(store, key), customPort) else { throw DNSJournalError.conflict }
        SCDynamicStoreSetValue(store, key, original)

        // No DNS push: managed modes publish a VPN-family resolver and undo
        // their own write exactly, without touching an existing network service.
        try journal.begin(serviceOverride: id)
        try journal.confirm(tunnel: "utun9999")
        let fallback = try journal.prepareManaged(tunnel: "utun9999", has4: true, has6: false)
        guard fallback == ["1.1.1.1", "9.9.9.9"] else { throw DNSJournalError.unavailable }
        try journal.confirm(tunnel: "utun9999")
        try journal.restore()
        guard CFEqual(SCDynamicStoreCopyValue(store, key), original), !journal.exists else { throw DNSJournalError.conflict }

        try journal.begin(serviceOverride: id)
        SCDynamicStoreSetValue(store, key, ["ServerAddresses": ["223.5.5.5"]] as CFDictionary)
        try journal.commit(tunnel: "utun9999")
        guard try journal.prepareManaged(tunnel: "utun9999", has4: true, has6: false) == ["223.5.5.5"] else { throw DNSJournalError.unavailable }
        try journal.restore()
        guard CFEqual(SCDynamicStoreCopyValue(store, key), original) else { throw DNSJournalError.conflict }

        let splitKey = "State:/Network/Service/openvpn-utun9999/DNS" as CFString
        defer { SCDynamicStoreRemoveValue(store, splitKey) }
        try journal.begin(serviceOverride: id)
        let split = ["ServerAddresses": ["10.8.0.53"], "SupplementalMatchDomains": ["corp.test"]] as CFDictionary
        SCDynamicStoreSetValue(store, splitKey, split)
        try journal.commit(tunnel: "utun9999")
        let splitServers = try journal.prepareManaged(tunnel: "utun9999", has4: true, has6: false)
        guard Set(splitServers) == Set(["10.8.0.53", "1.1.1.1", "9.9.9.9"]),
              CFEqual(SCDynamicStoreCopyValue(store, splitKey), split) else { throw DNSJournalError.conflict }
        try journal.restore()
        guard CFEqual(SCDynamicStoreCopyValue(store, key), original),
              SCDynamicStoreCopyValue(store, splitKey) == nil else { throw DNSJournalError.conflict }

        try journal.begin(serviceOverride: id)
        SCDynamicStoreSetValue(store, key, applied)
        try journal.commit(tunnel: "utun9999")
        SCDynamicStoreSetValue(store, key, other)
        do { try journal.restore(); throw DNSJournalError.unavailable }
        catch DNSJournalError.conflict { }
        guard journal.exists, CFEqual(SCDynamicStoreCopyValue(store, key), other) else { throw DNSJournalError.unavailable }
        SCDynamicStoreSetValue(store, key, applied)
        try journal.restore()

        try journal.begin(serviceOverride: id)
        SCDynamicStoreSetValue(store, key, other)
        do { try journal.confirm(tunnel: "utun9999"); throw DNSJournalError.unavailable }
        catch DNSJournalError.conflict { }
        guard journal.exists, CFEqual(SCDynamicStoreCopyValue(store, key), other) else { throw DNSJournalError.unavailable }
        SCDynamicStoreSetValue(store, key, original)
        try journal.restore()

        // Reproduce the 0.8.14 regression: optional cache commands fail after
        // DNS has been applied/restored. None may prevent completion or leave
        // a journal that subsequently blocks HelperQuitPolicy.
        var failingFlushes = 0
        let failing = DNSRecoveryJournal(file: folder.appendingPathComponent("cache-failure.journal"), flushCache: {
            failingFlushes += 1
            throw RouteExecutionError.commandFailed("/bin/launchctl")
        })
        try failing.begin(serviceOverride: id)
        try failing.confirm(tunnel: "utun9999")
        _ = try failing.prepareManaged(tunnel: "utun9999", has4: true, has6: false)
        try failing.publishManagedResolver(tunnel: "utun9999", port: 54321)
        try failing.confirm(tunnel: "utun9999")
        try failing.publishManagedResolver(tunnel: "utun9999", port: 54322)
        try failing.restore()
        guard failingFlushes == 4, !failing.exists, failing.primaryService == nil,
              CFEqual(SCDynamicStoreCopyValue(store, key), original) else { throw DNSJournalError.conflict }

        // Optional failure must not weaken conflict protection.
        try failing.begin(serviceOverride: id)
        try failing.applyProvided(tunnel: "utun9999", servers: ["10.8.0.53"], search: [], match: [])
        SCDynamicStoreSetValue(store, key, other)
        do { try failing.restore(); throw DNSJournalError.unavailable }
        catch DNSJournalError.conflict { }
        guard failing.exists, CFEqual(SCDynamicStoreCopyValue(store, key), other), failingFlushes == 4 else { throw DNSJournalError.conflict }
        let idle = SessionReport(state: .failed, message: "fixture", activeProfileID: nil,
                                 receivedBytes: nil, sentBytes: nil, networkRecoveryRequired: false)
        guard !HelperQuitPolicy.mayStop(idle, hasRecoveryEvidence: failing.exists, installationPending: false) else { throw DNSJournalError.conflict }
        SCDynamicStoreSetValue(store, key, ["ServerAddresses": ["10.8.0.53"], "SearchOrder": 5000] as CFDictionary)
        try failing.restore()
        try failing.restore() // already restored: remains idempotent
        guard !failing.exists, failingFlushes == 5, CFEqual(SCDynamicStoreCopyValue(store, key), original) else { throw DNSJournalError.conflict }
        guard HelperQuitPolicy.mayStop(idle, hasRecoveryEvidence: failing.exists, installationPending: false) else { throw DNSJournalError.unavailable }
        print("PASS: failing cache refresh cannot block resolver publication or verified restore; external DNS conflicts remain protected.")
    }
}
#endif
