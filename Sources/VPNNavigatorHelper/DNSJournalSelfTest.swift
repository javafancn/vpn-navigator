#if DEBUG
import Foundation
import SystemConfiguration

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
        let journal = DNSRecoveryJournal(file: folder.appendingPathComponent("dns.journal"))
        guard SCDynamicStoreSetValue(store, key, original) else { throw DNSJournalError.unavailable }
        try journal.begin(serviceOverride: id)
        guard SCDynamicStoreSetValue(store, key, applied) else { throw DNSJournalError.unavailable }
        try journal.commit(tunnel: "utun9999")
        try journal.confirm(tunnel: "utun9999")
        try journal.restore()
        guard CFEqual(SCDynamicStoreCopyValue(store, key), original), !journal.exists else { throw DNSJournalError.conflict }

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
    }
}
#endif
