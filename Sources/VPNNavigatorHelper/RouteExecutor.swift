import Foundation
import VPNNavigatorCore

/// Execute only validated routes. No shell, no user-supplied executable/argv.
final class RouteExecutor {
    private(set) var installed: [RouteTarget] = []
    private let journal: URL
    init(journal: URL) {
        self.journal = journal
        // Recover and clean up routes left by an unexpected helper termination.
        if let data = try? Data(contentsOf: journal),
           let previous = try? JSONDecoder().decode([RouteTarget].self, from: data) {
            self.installed = previous
            rollback()
        }
    }

    func apply(_ route: RouteTarget) throws {
        // Abort if another tunnel already owns this exact network (idempotence protects shared routes).
        let output = try Self.command("/usr/sbin/netstat", ["-rn", "-f", "inet"])
        let prefixName = route.prefix.description
        if output.split(separator: "\n").contains(where: {
            $0.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) == prefixName
        }) { throw RouteExecutionError.existingRoute(prefixName) }
        try Self.command("/sbin/route", route.arguments(adding: true))
        installed.append(route)
        try persistJournal()
    }
    func apply(_ routes: [RouteTarget]) throws {
        do { for route in routes { try apply(route) } }
        catch { rollback(); throw error }
    }
    func rollback() {
        for route in installed.reversed() {
            _ = try? Self.command("/sbin/route", route.arguments(adding: false))
        }
        installed.removeAll()
        try? FileManager.default.removeItem(at: journal)
    }
    func refreshDirectRoutes(added: [RouteTarget], removed: [RouteTarget]) throws {
        // Addition first avoids temporarily losing direct routes during an update.
        var created: [RouteTarget] = []
        do {
            for route in added {
                try apply(route)
                created.append(route)
            }
        } catch {
            for route in created.reversed() {
                _ = try? Self.command("/sbin/route", route.arguments(adding: false))
                installed.removeAll { $0 == route }
            }
            try? persistJournal()
            throw error
        }
        for route in removed {
            guard installed.contains(route) else { continue }
            try Self.command("/sbin/route", route.arguments(adding: false))
            installed.removeAll { $0 == route }
        }
        try persistJournal()
    }

    private func persistJournal() throws {
        let data = installed.map { "\($0.prefix.description) \($0.arguments(adding: true).joined(separator: " "))" }
            .joined(separator: "\n").data(using: .utf8)!
        try data.write(to: journal, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
    }

    @discardableResult
    static func command(_ executable: String, _ arguments: [String]) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        let output = Pipe()
        task.standardOutput = output
        task.standardError = output
        try task.run()
        // Bounded use: route/netstat/ifconfig commands terminate quickly.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw RouteExecutionError.commandFailed(executable) }
        return String(decoding: data, as: UTF8.self)
    }
}
enum RouteExecutionError: Error { case existingRoute(String), commandFailed(String) }
