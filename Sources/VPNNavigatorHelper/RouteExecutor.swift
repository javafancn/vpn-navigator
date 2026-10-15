import Foundation
import Darwin
import VPNNavigatorCore

/// Root-only route executor. Every OS mutation is bracketed by durable
/// begin/commit records. A crash between them is considered ambiguous:
/// never delete an unproven route or silently start another VPN.
final class RouteExecutor {
    private(set) var installed: [RouteTarget] = []
    private let journal: URL
    private var ambiguous = false

    init(journal: URL) {
        self.journal = journal
        guard let data = try? Data(contentsOf: journal) else { return }
        let replay = RouteLedgerReplay(data: data)
        installed = replay.installed
        ambiguous = !replay.permitsAutomaticRecovery
        if !ambiguous {
            if installed.isEmpty {
                try? FileManager.default.removeItem(at: journal)
            } else {
                rollback()
            }
        }
    }

    func apply(_ route: RouteTarget) throws {
        guard !ambiguous else { throw RouteExecutionError.ambiguousJournal }
        let output = try Self.command("/usr/sbin/netstat", ["-rn", "-f", "inet"])
        let prefix = route.prefix.description
        if output.split(separator: "\n").contains(where: {
            $0.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) == prefix
        }) {
            throw RouteExecutionError.existingRoute(prefix)
        }
        try install(route)
    }

    func apply(_ routes: [RouteTarget]) throws {
        guard !ambiguous else { throw RouteExecutionError.ambiguousJournal }
        let snapshot = try Self.command("/usr/sbin/netstat", ["-rn", "-f", "inet"])
        let occupied = Set(snapshot.split(separator: "\n").compactMap {
            $0.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
        })
        do {
            for route in routes {
                if occupied.contains(route.prefix.description) {
                    throw RouteExecutionError.existingRoute(route.prefix.description)
                }
                try install(route)
            }
        } catch {
            rollback()
            throw error
        }
    }

    private func install(_ route: RouteTarget) throws {
        let mutation = RouteMutation(action: .add, route: route)
        try append(.init(phase: .begun, mutation: mutation))
        ambiguous = true
        try Self.command("/sbin/route", route.arguments(adding: true))
        try append(.init(phase: .committed, mutation: mutation))
        installed.append(route)
        ambiguous = false
    }

    /// Always verify route ownership before deleting. If a mutation was left
    /// incomplete, leave the journal intact rather than guessing OS state.
    func rollback() {
        guard !ambiguous else { return }
        if let data = try? Data(contentsOf: journal),
           !RouteLedgerReplay(data: data).permitsAutomaticRecovery {
            ambiguous = true
            return
        }
        for route in installed.reversed() {
            do {
                let observation = try observe(route)
                try release(route, deleteSystemRoute: observation.isExactly(route))
            } catch {
                // No further cleanup is safe until the failing operation
                // and its journal records can be inspected by an operator.
                break
            }
        }
        if !ambiguous && installed.isEmpty {
            try? FileManager.default.removeItem(at: journal)
        }
    }

    func refreshDirectRoutes(added: [RouteTarget], removed: [RouteTarget]) throws {
        guard !ambiguous else { throw RouteExecutionError.ambiguousJournal }
        // The owning tunnel is disconnected by the caller if any mutation fails.
        for route in added { try apply(route) }
        for route in removed {
            guard installed.contains(route) else { continue }
            let actual = try observe(route)
            guard actual.isExactly(route) else {
                throw RouteExecutionError.routeOwnershipLost(route.prefix.description)
            }
            try release(route, deleteSystemRoute: true)
        }
    }

    private func release(_ route: RouteTarget, deleteSystemRoute: Bool) throws {
        let mutation = RouteMutation(action: .remove, route: route)
        try append(.init(phase: .begun, mutation: mutation))
        ambiguous = true
        if deleteSystemRoute {
            try Self.command("/sbin/route", route.arguments(adding: false))
        }
        try append(.init(phase: .committed, mutation: mutation))
        installed.removeAll { $0 == route }
        ambiguous = false
    }

    private func observe(_ route: RouteTarget) throws -> ObservedIPv4Route {
        let output = try Self.command("/sbin/route",
                                      ["-n", "get", "-net", route.prefix.description])
        return ObservedIPv4Route(commandOutput: output)
    }

    private func append(_ event: RouteLedgerEvent) throws {
        var data = try JSONEncoder().encode(event)
        data.append(10)
        if !FileManager.default.fileExists(atPath: journal.path) {
            guard FileManager.default.createFile(atPath: journal.path, contents: Data(),
                                                  attributes: [.posixPermissions: 0o600]) else {
                throw RouteExecutionError.journalFailure
            }
        }
        let handle = try FileHandle(forWritingTo: journal)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    /// Bounded system-tool invocation: never run a shell or external profile
    /// commands, and never let a stuck route/netstat command hang the root queue.
    @discardableResult
    static func command(_ executable: String, _ arguments: [String]) throws -> String {
        let allowlisted: Set<String> = [
            "/sbin/route", "/usr/sbin/netstat", "/sbin/ifconfig"
        ]
        guard allowlisted.contains(executable) else {
            throw RouteExecutionError.disallowedExecutable
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        let output = Pipe()
        task.standardOutput = output
        task.standardError = output
        try task.run()

        let timeout = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timeout.schedule(deadline: .now() + .seconds(12))
        timeout.setEventHandler { [weak task] in
            guard let task, task.isRunning else { return }
            // Do not send SIGKILL to a numeric PID after a delay. If the
            // original command exited and the OS reused its PID, a delayed
            // kill could target an unrelated process.
            task.terminate()
        }
        timeout.resume()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        timeout.cancel()
        guard data.count <= 8_000_000 else {
            throw RouteExecutionError.commandOutputTooLarge
        }
        guard task.terminationStatus == 0 else {
            throw RouteExecutionError.commandFailed(executable)
        }
        return String(decoding: data, as: UTF8.self)
    }
}

enum RouteExecutionError: Error, LocalizedError {
    case existingRoute(String), commandFailed(String), routeOwnershipLost(String)
    case ambiguousJournal, journalFailure, disallowedExecutable, commandOutputTooLarge

    var errorDescription: String? {
        switch self {
        case .existingRoute(let prefix):
            return "An existing system route already covers \(prefix)."
        case .commandFailed(let command):
            return "The system network command failed: \(command)."
        case .routeOwnershipLost(let prefix):
            return "Cannot verify ownership of route \(prefix); refusing to delete it."
        case .ambiguousJournal:
            return "A previous route mutation may be incomplete. Manual network verification is required."
        case .journalFailure:
            return "Cannot durably record route changes. System routing has not been modified."
        case .disallowedExecutable:
            return "System tool is not permitted for privileged route execution."
        case .commandOutputTooLarge:
            return "Unexpectedly large system routing output; operation aborted."
        }
    }
}
