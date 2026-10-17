import Foundation
import Darwin
import VPNNavigatorCore

/// Owns one anchor and one PF enable token. Never reloads the main ruleset,
/// flushes unrelated anchors, disables PF globally, or guesses a missing token.
/// Strict opt-in resets existing PF states when protection changes; new pass
/// states are bound to their interface so a dead tunnel cannot float outward.
final class PacketFilterGuard {
    private struct Record: Codable { var token: String?; var enabled: Bool; var resetsStates: Bool? }
    private let folder = URL(fileURLWithPath: "/var/run/vpn-navigator")
    private var journal: URL { folder.appendingPathComponent("pf-guard.json") }
    private var rulesFile: URL { folder.appendingPathComponent("pf-guard.conf") }
    private var receipt: URL { folder.appendingPathComponent("pf-enable.receipt") }
    private var expectedRules: String?
    private var expectedTable: String?
    private(set) var active = false
    var requiresRecovery: Bool { FileManager.default.fileExists(atPath: journal.path) }

    func activate(_ rules: String, resetExistingStates: Bool = true) throws {
        guard !requiresRecovery else { throw LeakGuardError.unresolved }
        try preflight()
        try prepareDirectory()
        try save(.init(token: nil, enabled: false, resetsStates: resetExistingStates))
        try load(rules)
        // Persist the enable intent before the child runs. If it exits after
        // enabling but before a usable receipt, retain ambiguous recovery evidence.
        try save(.init(token: nil, enabled: true, resetsStates: resetExistingStates))
        let response = try enableWithReceipt()
        guard let token = LeakGuardPolicy.enableToken(response) else {
            // Own rules remain fail-closed. An unknown enable reference is not
            // permission to run pfctl -d; recovery can remove only our rules.
            throw LeakGuardError.unresolved
        }
        try save(.init(token: token, enabled: true, resetsStates: resetExistingStates))
        active = true
        if resetExistingStates { _ = try Self.command(["-F", "states"]) }
        try verify()
    }
    func replaceRules(_ rules: String, resetExistingStates: Bool = false) throws {
        guard active else { throw LeakGuardError.notActive }
        try preflight(); try load(rules)
        // Tightening exceptions or rebuilding the protected session invalidates
        // existing states. The explicit opt-in UI discloses this network reset.
        if resetExistingStates { _ = try Self.command(["-F", "states"]) }
        try verify()
    }
    func verify() throws {
        guard active, let expectedRules else { throw LeakGuardError.notActive }
        try preflight()
        let status = try Self.command(["-s", "info"])
        let rules = try Self.command(["-a", LeakGuardPolicy.anchor, "-sr"])
        guard status.contains("Status: Enabled"), rules == expectedRules else { throw LeakGuardError.notActive }
        if let expectedTable {
            guard try Self.command(["-a", LeakGuardPolicy.anchor, "-t", "vpnnav_direct4", "-T", "show"]) == expectedTable else { throw LeakGuardError.notActive }
        }
    }
    func release() throws {
        guard requiresRecovery else { active = false; return }
        let record = try read()
        _ = try Self.command(["-a", LeakGuardPolicy.anchor, "-F", "rules"])
        let remaining = try Self.command(["-a", LeakGuardPolicy.anchor, "-sr"])
        guard Self.cleaned(remaining).isEmpty else { throw LeakGuardError.unresolved }
        let receiptToken = (try? String(contentsOf: receipt)).flatMap(LeakGuardPolicy.enableToken)
        if record.resetsStates == true { _ = try Self.command(["-F", "states"]) }
        if let token = record.token ?? receiptToken {
            guard !token.isEmpty, token.allSatisfy({ $0.isASCII && $0.isNumber }), UInt64(token) != nil else { throw LeakGuardError.unresolved }
            _ = try Self.command(["-X", token])
        }
        // A crash between -E and recording its token may leave an unknown
        // reference. Never disable someone else's PF; surface it in diagnostics.
        if record.enabled && record.token == nil && receiptToken == nil { throw LeakGuardError.unresolved }
        try FileManager.default.removeItem(at: journal)
        try? FileManager.default.removeItem(at: rulesFile)
        try? FileManager.default.removeItem(at: receipt)
        active = false; expectedRules = nil; expectedTable = nil
    }
    private func preflight() throws {
        guard getuid() == 0,
              LeakGuardPolicy.compatibleRootRules(try Self.command(["-sr"])) else { throw LeakGuardError.incompatibleHost }
        let anchors = Self.cleaned(try Self.command(["-a", "com.apple", "-s", "Anchors"]))
            .components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.map { $0.components(separatedBy: "/").last ?? $0 }
        guard anchors.allSatisfy({ $0 >= "000.vpn-navigator" }) else { throw LeakGuardError.incompatibleHost }
        let interfaces = try Self.command(["-v", "-s", "Interfaces"])
        // A skipped interface bypasses filtering. Reject this host layout
        // rather than presenting a guard that cannot cover all physical paths.
        guard !interfaces.lowercased().contains("skip") else { throw LeakGuardError.incompatibleHost }
    }
    private func load(_ rules: String) throws {
        guard rules.utf8.count < 2_000_000 else { throw LeakGuardError.invalid }
        try rules.write(to: rulesFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rulesFile.path)
        _ = try Self.command(["-n", "-a", LeakGuardPolicy.anchor, "-f", rulesFile.path])
        _ = try Self.command(["-a", LeakGuardPolicy.anchor, "-f", rulesFile.path])
        expectedRules = try Self.command(["-a", LeakGuardPolicy.anchor, "-sr"])
        expectedTable = rules.contains("table <vpnnav_direct4>") ? try Self.command(["-a", LeakGuardPolicy.anchor, "-t", "vpnnav_direct4", "-T", "show"]) : nil
        guard !Self.cleaned(expectedRules ?? "").isEmpty else { throw LeakGuardError.notActive }
    }
    private func enableWithReceipt() throws -> String {
        // Give pfctl its own root-private output file before enabling. A helper
        // crash after -E can still recover the token written by the child.
        try Data().write(to: receipt, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receipt.path)
        let handle = try FileHandle(forWritingTo: receipt)
        defer { try? handle.close() }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/sbin/pfctl"); task.arguments = ["-E"]
        task.standardOutput = handle; task.standardError = handle
        try task.run()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 8)
        timer.setEventHandler { [weak task] in if let task, task.isRunning { task.terminate() } }
        timer.resume(); task.waitUntilExit(); timer.cancel()
        try handle.synchronize()
        guard task.terminationStatus == 0 else { throw LeakGuardError.incompatibleHost }
        return try String(contentsOf: receipt)
    }
    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let attrs = try FileManager.default.attributesOfItem(atPath: folder.path)
        guard attrs[.type] as? FileAttributeType == .typeDirectory,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == 0,
              ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0 else { throw LeakGuardError.unresolved }
    }
    private func save(_ record: Record) throws {
        try JSONEncoder().encode(record).write(to: journal, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
    }
    private func read() throws -> Record {
        try prepareDirectory()
        let attrs = try FileManager.default.attributesOfItem(atPath: journal.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == 0,
              ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0,
              ((attrs[.size] as? NSNumber)?.intValue ?? Int.max) < 4096 else { throw LeakGuardError.unresolved }
        return try JSONDecoder().decode(Record.self, from: Data(contentsOf: journal))
    }
    private static func cleaned(_ text: String) -> String {
        text.components(separatedBy: .newlines).filter { !$0.hasPrefix("No ALTQ") && !$0.hasPrefix("ALTQ") }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    @discardableResult
    static func command(_ arguments: [String]) throws -> String {
        let task = Process(), pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/sbin/pfctl"); task.arguments = arguments
        task.standardOutput = pipe; task.standardError = pipe
        try task.run()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 8)
        timer.setEventHandler { [weak task] in if let task, task.isRunning { task.terminate() } }
        timer.resume()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit(); timer.cancel()
        guard task.terminationStatus == 0, data.count < 2_000_000 else { throw LeakGuardError.incompatibleHost }
        return String(decoding: data, as: UTF8.self)
    }
}
