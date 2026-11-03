#if DEBUG
import Foundation
import VPNNavigatorCore

enum RouteExecutionSelfTest {
    static func run() throws {
        try testRoutingDiagnostics()
        try RouteBatchSelfTest.run()
        try ProcessExitSelfTest.run()
        try RouteCompactionSelfTest.run()
        try RouteCommandPressureSelfTest.observeLegacyBehavior()
        try RouteCommandPressureSelfTest.run()
        try RouteJournalRecoverySelfTest.run()
        try DualStackRouteSelfTest.run()
        try RouteSwitchSelfTest.run()
        try RulePlanningSelfTest.run()
        try testOccupiedIPv4Prefixes()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var calls: [[String]] = []
        let first = RouteTarget(try IPv4CIDR("223.5.5.0/24"), .viaGateway("192.168.1.1"))
        let occupied = RouteTarget(try IPv4CIDR("223.5.6.0/24"), .viaGateway("192.168.1.1"))
        let executor = RouteExecutor(journal: folder.appendingPathComponent("routes"), run: { executable, args in
            calls.append(args)
            if executable == "/usr/sbin/netstat" { return "223.5.6.0/24 192.168.1.1 en0\n" }
            if args.contains("get") { return "destination: 223.5.5.0\nmask: 255.255.255.0\ngateway: 192.168.1.1\ninterface: en0" }
            return ""
        })
        do { try executor.apply([first, occupied]); throw RouteExecutionError.journalFailure }
        catch RouteExecutionError.existingRoute { }
        guard executor.installed == [first], !calls.contains(where: { $0.contains("delete") || $0.contains("get") }) else {
            throw RouteExecutionError.journalFailure
        }
        // The caller now confirms the child has exited, then explicitly rolls back.
        executor.rollback()
        guard executor.installed.isEmpty, calls.contains(where: { $0.contains("delete") }) else { throw RouteExecutionError.journalFailure }
        let cancelled = RouteExecutor(journal: folder.appendingPathComponent("cancelled"), shouldCancel: { true }, run: { _, _ in
            throw RouteExecutionError.disallowedExecutable
        })
        do { try cancelled.apply(first); throw RouteExecutionError.journalFailure }
        catch is CancellationError { }
        let hostJournal = folder.appendingPathComponent("occupied-host")
        let host = RouteTarget(try IPv4CIDR("223.5.5.5/32"), .interface("utun4"))
        let hostExecutor = RouteExecutor(journal: hostJournal, run: { executable, _ in
            guard executable == "/usr/sbin/netstat" else { throw RouteExecutionError.disallowedExecutable }
            return "Internet:\nDestination Gateway Flags Netif\n223.5.5.5 192.168.1.1 UGHS en0\n"
        })
        do { try hostExecutor.apply([host]); throw RouteExecutionError.journalFailure }
        catch RouteExecutionError.existingRoute { }
        guard hostExecutor.installed.isEmpty, !FileManager.default.fileExists(atPath: hostJournal.path) else { throw RouteExecutionError.journalFailure }
        let inherited = RouteExecutor(journal: hostJournal, run: { executable, args in
            if executable == "/usr/sbin/netstat" {
                return "Internet:\nDestination Gateway Flags Netif\n223.5.5.5 link#5 UH utun4\n"
            }
            guard args.contains("get") else { throw RouteExecutionError.disallowedExecutable }
            return "destination: 223.5.5.5\ninterface: utun4\n"
        })
        try inherited.apply([host], inheriting: [host])
        guard inherited.installed.isEmpty, !FileManager.default.fileExists(atPath: hostJournal.path) else { throw RouteExecutionError.journalFailure }
    }

    private static func testRoutingDiagnostics() throws {
        let legacy = Data(#"{"id":"00000000-0000-0000-0000-000000000001","date":0,"code":"route"}"#.utf8)
        let decoded = try JSONDecoder().decode(DiagnosticEvent.self, from: legacy)
        guard decoded.code == .route, decoded.routingStage == nil, decoded.systemError == nil else {
            throw RouteExecutionError.journalFailure
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("events.json")
        try JSONEncoder().encode([decoded]).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let store = DiagnosticEventStore(file: file)
        store.append(.route, routingStage: .ipv4Routes, systemError: 60)
        store.append(.route, routingStage: .ipv4Routes, systemError: 60)
        store.append(.route, routingStage: .ipv6Routes, systemError: 60)
        store.append(.recovery); store.append(.starting)
        let events = DiagnosticEventStore(file: file).events()
        guard events.count == 5, events[1].routingStage == .ipv4Routes, events[1].systemError == 60,
              events[2].routingStage == .ipv6Routes, events.last?.code == .starting else {
            throw RouteExecutionError.journalFailure
        }
        let data = try JSONEncoder().encode(events[1])
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let object, Set(object.keys) == ["id", "date", "code", "routingStage", "systemError"] else {
            throw RouteExecutionError.journalFailure
        }
        print("PASS: switch failure stage/errno survives recovery and reconnect, preserves legacy events and deduplicates only identical failures; no raw error text.")
    }

    private static func testOccupiedIPv4Prefixes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for (destination, prefix, flags) in [
            ("1.0.1/24", "1.0.1.0/24", "UGSc"),
            ("11/8", "11.0.0.0/8", "UGSc"),
            ("192.168/16", "192.168.0.0/16", "UCS"),
            ("11", "11.0.0.0/8", "UGSc"),
            ("1.0.1.0/24", "1.0.1.0/24", "UGSc"),
            ("1.0.1.2", "1.0.1.2/32", "UGHS"),
            ("default", "0.0.0.0/0", "UGSc")
        ] {
            for batch in [false, true] {
                let journal = folder.appendingPathComponent(UUID().uuidString)
                var mutationAttempted = false
                let executor = RouteExecutor(journal: journal, run: { executable, _ in
                    if executable == "/usr/sbin/netstat" {
                        return "Internet:\nDestination Gateway Flags Netif\n\(destination) 192.168.1.1 \(flags) en0\n"
                    }
                    mutationAttempted = true
                    throw RouteExecutionError.disallowedExecutable
                })
                let target = RouteTarget(try IPv4CIDR(prefix), .viaGateway("192.168.1.1"))
                do {
                    if batch { try executor.apply([target]) } else { try executor.apply(target) }
                    throw RouteExecutionError.journalFailure
                } catch RouteExecutionError.existingRoute { }
                guard !mutationAttempted, executor.installed.isEmpty,
                      !FileManager.default.fileExists(atPath: journal.path) else { throw RouteExecutionError.journalFailure }
            }
        }
        print("PASS: existing abbreviated IPv4 prefixes are rejected before mutation or journal creation in single and batch routing.")
    }
}
#endif
