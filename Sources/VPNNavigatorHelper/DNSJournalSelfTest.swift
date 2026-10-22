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
