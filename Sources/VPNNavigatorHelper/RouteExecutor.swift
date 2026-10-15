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
        // Take a single route-table snapshot instead of running netstat for every CIDR.
        let snapshot = try Self.command("/usr/sbin/netstat", ["-rn", "-f", "inet"])
        let occupied = Set(snapshot.split(separator: "\n").compactMap {
            $0.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
        })
        do {
            for route in routes {
                if occupied.contains(route.prefix.description) {
                    throw RouteExecutionError.existingRoute(route.prefix.description)
                }
                try Self.command("/sbin/route", route.arguments(adding: true))
                installed.append(route)
                try persistJournal()
            }
        } catch { rollback(); throw error }
    }
    /// Remove only routes that still point at our own expected destination.
    /// If route lookup fails, retain the journal for a later recovery attempt.
    func rollback() {
        var unresolved: [RouteTarget] = []
        for route in installed.reversed() {
            do {
                let observation = try observe(route)
                // A different gateway/interface means another owner took over;
                // never delete that route.
                guard observation.isExactly(route) else { continue }
                try Self.command("/sbin/route", route.arguments(adding: false))
            } catch {
                unresolved.append(route)
            }
        }
        installed = unresolved.reversed()
        if installed.isEmpty {
            try? FileManager.default.removeItem(at: journal)
        } else {
            try? persistJournal()
        }
    }

    func refreshDirectRoutes(added: [RouteTarget], removed: [RouteTarget]) throws {
        var newlyAdded: [RouteTarget] = []
        var deleted: [RouteTarget] = []
        do {
            for route in added {
                try apply(route)
                newlyAdded.append(route)
            }
            for route in removed {
                guard installed.contains(route) else { continue }
                guard try observe(route).isExactly(route) else {
                    throw RouteExecutionError.routeOwnershipLost(route.prefix.description)
                }
                try Self.command("/sbin/route", route.arguments(adding: false))
                installed.removeAll { $0 == route }
                deleted.append(route)
                try persistJournal()
            }
        } catch {
            // Restore the last-known-good routing policy, best-effort.
            for route in deleted.reversed() {
                if (try? Self.command("/sbin/route", route.arguments(adding: true))) != nil {
                    installed.append(route)
                }
            }
            for route in newlyAdded.reversed() {
                if let observation = try? observe(route), observation.isExactly(route),
                   (try? Self.command("/sbin/route", route.arguments(adding: false))) != nil {
                    installed.removeAll { $0 == route }
                }
            }
            try? persistJournal()
            throw error
        }
    }

    private func observe(_ route: RouteTarget) throws -> ObservedIPv4Route {
        let output = try Self.command("/sbin/route",
                                      ["-n", "get", "-net", route.prefix.description])
        return ObservedIPv4Route(commandOutput: output)
    }

    private func persistJournal() throws {
        let data = try JSONEncoder().encode(installed)
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
enum RouteExecutionError: Error { case existingRoute(String), commandFailed(String), routeOwnershipLost(String) }
