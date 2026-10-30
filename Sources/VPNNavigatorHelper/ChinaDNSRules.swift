import Foundation
import CryptoKit
import VPNNavigatorCore

enum ChinaDNSRules {
    static let sha256 = "054412fa9661dd7db76a24f55364bf86603e2b337b55534694784849c0146999"
    static func load() throws -> ChinaDNSDomains {
        let engine = try ExecutableTrust.trustedOpenVPN()
        let file = engine.deletingLastPathComponent().appendingPathComponent("china-dns-domains.txt")
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        guard (attrs[.ownerAccountID] as? NSNumber)?.intValue == 0 else { throw DNSJournalError.unavailable }
        return try read(file)
    }
    static func read(_ file: URL) throws -> ChinaDNSDomains {
        let path = file.standardizedFileURL
        guard path.resolvingSymlinksInPath() == path,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o022 == 0,
              ((attrs[.size] as? NSNumber)?.intValue ?? Int.max) <= 4_000_000 else { throw DNSJournalError.unavailable }
        // Production also verifies root-owned parents through trustedOpenVPN.
        let data = try Data(contentsOf: path)
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha256,
              let text = String(data: data, encoding: .utf8) else { throw DNSJournalError.unavailable }
        return try ChinaDNSDomains(text: text)
    }
}
