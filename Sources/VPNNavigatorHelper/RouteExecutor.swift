import Foundation
import Darwin
import VPNNavigatorCore

/// Root-only route executor. Bounded batches have durable intents before any
/// mutation and durable receipts before the next batch. An unfinished intent is ambiguous:
/// never delete an unproven route or silently start another VPN.
final class RouteExecutor {
    private var owned = OrderedRouteSet<RouteTarget>()
    private var owned6 = OrderedRouteSet<IPv6RouteTarget>()
    var installed: [RouteTarget] { owned.elements }
    var installed6: [IPv6RouteTarget] { owned6.elements }
    private let encoder = JSONEncoder()
    private let synchronize: (FileHandle) throws -> Void
    private(set) var journalSynchronizations = 0
    private static let batchSize = 64
    private enum Change {
        case ipv4(RouteMutation), ipv6(IPv6RouteMutation)
    }
    private let journal: URL
    private var ambiguous = false
    private let shouldCancel: () -> Bool
    private let run: (String, [String]) throws -> String
    private let usesKernelWriter: Bool
    private var kernelWriter: KernelRouteWriter?
    private var kernelReader: KernelRouteReader?
    private var journalHandle: FileHandle?
    private var journalBytes = 0
    private let compactionInterval: Int
    private var compactAt: Int

    init(journal: URL, shouldCancel: @escaping () -> Bool = { false }, run: ((String, [String]) throws -> String)? = nil,
         compactionInterval: Int = 4_000_000, synchronize: @escaping (FileHandle) throws -> Void = { try $0.synchronize() }) {
        self.journal = journal
        self.synchronize = synchronize
        self.shouldCancel = shouldCancel
        self.run = run ?? RouteExecutor.command
        usesKernelWriter = run == nil
        self.compactionInterval = min(4_000_000, max(4096, compactionInterval))
        compactAt = self.compactionInterval
        guard let data = try? Data(contentsOf: journal) else { return }
        journalBytes = data.count
        let replay = RouteLedgerReplay(data: data)
        owned = .init(replay.installed)
        owned6 = .init(replay.installed6)
        ambiguous = !replay.permitsAutomaticRecovery
        // Legacy JSON arrays and complete final records may have no newline.
        // Replace them before appending, rather than joining two JSON values
        // into a malformed first row during otherwise valid recovery.
        if !ambiguous, !data.isEmpty, data.last != 10 { compactAt = 0 }
        if !ambiguous {
            if owned.isEmpty && owned6.isEmpty {
                try? FileManager.default.removeItem(at: journal)
                if !FileManager.default.fileExists(atPath: journal.path) { journalBytes = 0 }
            } else {
                rollback(verifiedReplay: true)
            }
        }
    }

    deinit { try? journalHandle?.close() }

    private func mutate(_ route: RouteTarget, adding: Bool) throws {
        if usesKernelWriter, case .viaGateway = route.destination {
            if kernelWriter == nil { kernelWriter = try KernelRouteWriter() }
            try kernelWriter!.apply(route, adding: adding)
        } else { _ = try run("/sbin/route", route.arguments(adding: adding)) }
    }
    private func mutate(_ route: IPv6RouteTarget, adding: Bool) throws {
        if usesKernelWriter, case .viaGateway = route.destination {
            if kernelWriter == nil { kernelWriter = try KernelRouteWriter() }
            try kernelWriter!.apply(route, adding: adding)
        } else { _ = try run("/sbin/route", route.arguments(adding: adding)) }
    }

    func apply(_ route: RouteTarget) throws { try apply([route]) }

    func apply(_ routes: [RouteTarget], inheriting: Set<RouteTarget> = []) throws {
        guard !ambiguous else { throw RouteExecutionError.ambiguousJournal }
        guard !shouldCancel() else { throw CancellationError() }
        guard !routes.isEmpty else { return }
        let occupied = Self.occupiedIPv4(try run("/usr/sbin/netstat", ["-rn", "-f", "inet"]))
        var batch: [Change] = []
        for route in routes {
            if occupied.contains(route.prefix) {
                try perform(batch); batch.removeAll(keepingCapacity: true)
                if inheriting.contains(route), route.prefix.prefix == 32,
                   case .interface(let name) = route.destination, DNSRecoveryPolicy.validTunnel(name),
                   try observe(route).isExactly(route) { continue }
                throw RouteExecutionError.existingRoute(route.prefix.description)
            }
            batch.append(.ipv4(.init(action: .add, route: route)))
            if batch.count == Self.batchSize { try perform(batch); batch.removeAll(keepingCapacity: true) }
        }
        try perform(batch)
    }

    // netstat omits /32 on host routes and abbreviates network addresses.
    // Normalize once, before any WAL intent, rather than discovering EEXIST
    // after recording a mutation that must then be treated as uncertain.
    private static func occupiedIPv4(_ snapshot: String) -> Set<IPv4CIDR> {
        Set(snapshot.split(separator: "\n").compactMap { row in
            let fields = row.split(whereSeparator: { $0.isWhitespace })
            guard let first = fields.first else { return nil }
            let destination = String(first)
            if destination == "default" { return try? IPv4CIDR("0.0.0.0/0") }
            let parts = destination.split(separator: "/", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count) else { return nil }
            var octets = parts[0].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard (1...4).contains(octets.count), octets.allSatisfy({ UInt8($0) != nil }) else { return nil }
            let bits: Int
            if parts.count == 2 {
                guard let prefix = Int(parts[1]), (0...32).contains(prefix) else { return nil }
                bits = prefix
            } else {
                bits = fields.count > 2 && fields[2].contains("H") ? 32 : octets.count * 8
            }
            while octets.count < 4 { octets.append("0") }
            return try? IPv4CIDR(octets.joined(separator: ".") + "/\(bits)")
        })
    }

    /// A new process validates/replays once; live rollback revalidates the
    /// journal before cleanup. Never roll back an uncertain kernel mutation.
    func rollback() { rollback(verifiedReplay: false) }
    private func rollback(verifiedReplay: Bool) {
        guard !ambiguous else { return }
        if !verifiedReplay, let data = try? Data(contentsOf: journal),
           !RouteLedgerReplay(data: data).permitsAutomaticRecovery {
            ambiguous = true; return
        }
        do {
            try performChunks(owned6.elements.reversed().map { .ipv6(.init(action: .remove, route: $0)) }, rollback: true)
            try performChunks(owned.elements.reversed().map { .ipv4(.init(action: .remove, route: $0)) }, rollback: true)
        } catch { return }
        if !ambiguous && owned.isEmpty && owned6.isEmpty {
            try? journalHandle?.close(); journalHandle = nil
            try? FileManager.default.removeItem(at: journal)
            if !FileManager.default.fileExists(atPath: journal.path) { journalBytes = 0; compactAt = compactionInterval }
        }
    }

    func refreshDirectRoutes(added: [RouteTarget], removed: [RouteTarget]) throws {
        guard !ambiguous else { throw RouteExecutionError.ambiguousJournal }
        if !added.isEmpty { try apply(added) }
        try performChunks(removed.filter { owned.contains($0) }.map { .ipv4(.init(action: .remove, route: $0)) })
    }

    private func performChunks(_ changes: [Change], rollback: Bool = false) throws {
        for start in stride(from: 0, to: changes.count, by: Self.batchSize) {
            try perform(Array(changes[start..<min(changes.count, start + Self.batchSize)]), rollback: rollback)
        }
    }
    private func encode(_ change: Change, phase: RouteLedgerEvent.Phase, into data: inout Data) throws {
        switch change {
        case .ipv4(let mutation): data.append(try encoder.encode(RouteLedgerEvent(phase: phase, mutation: mutation)))
        case .ipv6(let mutation): data.append(try encoder.encode(IPv6RouteLedgerEvent(phase: phase, ipv6Mutation: mutation)))
        }
        data.append(10)
    }
    private func perform(_ changes: [Change], rollback: Bool = false) throws {
        guard !changes.isEmpty else { return }
        guard !ambiguous else { throw RouteExecutionError.ambiguousJournal }
        if !rollback && shouldCancel() { throw CancellationError() }
        var intents = Data()
        for change in changes { try encode(change, phase: .begun, into: &intents) }
        // Reserve both halves of the batch. A crash after receipts must never
        // leave an otherwise valid journal beyond the recovery reader's cap.
        if journalBytes + intents.count * 2 + 1024 >= compactAt { try compactJournal() }
        // An entire bounded batch is durable BEFORE its first kernel write.
        ambiguous = true
        try writeJournal(intents)
        var receipts = Data(), index = 0, issued = false
        do {
            for (offset, change) in changes.enumerated() {
                index = offset; issued = false
                if !rollback && shouldCancel() { throw CancellationError() }
                switch change {
                case .ipv4(let mutation):
                    let adding = mutation.action == .add
                    let matches = adding ? true : try observe(mutation.route).isExactly(mutation.route)
                    if !adding && !matches && !rollback { throw RouteExecutionError.routeOwnershipLost(mutation.route.prefix.description) }
                    issued = adding || matches
                    if issued { try mutate(mutation.route, adding: adding) }
                    try encode(change, phase: .committed, into: &receipts)
                    if adding { owned.insert(mutation.route) } else { owned.remove(mutation.route) }
                case .ipv6(let mutation):
                    let adding = mutation.action == .add
                    let matches = adding ? true : try observe6(mutation.route).isExactly(mutation.route)
                    if !adding && !matches && !rollback { throw RouteExecutionError.routeOwnershipLost(mutation.route.prefix.description) }
                    issued = adding || matches
                    if issued { try mutate(mutation.route, adding: adding) }
                    try encode(change, phase: .committed, into: &receipts)
                    if adding { owned6.insert(mutation.route) } else { owned6.remove(mutation.route) }
                }
                index = offset + 1; issued = false
            }
        } catch {
            let cause = error
            // Cancel ONLY intents for operations this process never issued.
            // The failing kernel write, if any, remains uncertain. Persist
            // earlier receipts before exposing the error to session teardown.
            do {
                for offset in (index + (issued ? 1 : 0))..<changes.count {
                    try encode(changes[offset], phase: .cancelled, into: &receipts)
                }
                try writeJournal(receipts)
                ambiguous = issued
            } catch { ambiguous = true }
            throw cause
        }
        try writeJournal(receipts)
        ambiguous = false
    }

    private func observe(_ route: RouteTarget) throws -> ObservedIPv4Route {
        if usesKernelWriter {
            if kernelReader == nil { kernelReader = try KernelRouteReader() }
            return try kernelReader!.observe(route)
        }
        let output = try run("/sbin/route",
                                      ["-n", "get", "-net", route.prefix.description])
        return ObservedIPv4Route(commandOutput: output)
    }

    private func writeJournal(_ data: Data) throws {
        guard !data.isEmpty else { return }
        if journalHandle == nil {
            let descriptor = open(journal.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw RouteExecutionError.journalFailure }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_nlink == 1 else {
                close(descriptor); throw RouteExecutionError.journalFailure
            }
            journalHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        }
        guard let handle = journalHandle else { throw RouteExecutionError.journalFailure }
        try handle.write(contentsOf: data)
        try synchronize(handle); journalSynchronizations += 1
        journalBytes += data.count
    }

    private func compactJournal() throws {
        guard !ambiguous else { throw RouteExecutionError.ambiguousJournal }
        let checkpoint = RouteLedgerCheckpoint(installed: installed, installed6: installed6)
        guard checkpoint.isValid else { throw RouteExecutionError.journalFailure }
        var bytes = try encoder.encode(checkpoint)
        bytes.append(10)
        // Leave at least four MB for later begin/commit records beneath the
        // recovery reader's 16 MB ceiling. Realistic maximum dual-stack plans
        // fit in the compact representation, without duplicate mutation IDs.
        guard bytes.count < 12_000_000 else { throw RouteExecutionError.journalFailure }
        try ProfileFileIO.write(bytes, to: journal)
        // The old handle points at the replaced inode. Open the new journal
        // for the next event; never append to an unlinked pre-checkpoint file.
        try? journalHandle?.close(); journalHandle = nil
        journalBytes = bytes.count
        compactAt = journalBytes + compactionInterval
    }

    func applyIPv6(_ routes: [IPv6RouteTarget], inheriting: Set<IPv6RouteTarget> = []) throws {
        guard !ambiguous else { throw RouteExecutionError.ambiguousJournal }
        guard !shouldCancel() else { throw CancellationError() }
        guard !routes.isEmpty else { return }
        let snapshot = try run("/usr/sbin/netstat", ["-rn", "-f", "inet6"])
        let occupied = Set(snapshot.components(separatedBy: .newlines).compactMap { line -> String? in
            guard let first = line.split(whereSeparator: { $0.isWhitespace }).first else { return nil }
            let destination = String(first)
            guard let prefix = try? IPv6CIDR(destination.contains("/") ? destination : destination + "/128") else { return nil }
            return prefix.description
        })
        var batch: [Change] = []
        for route in routes {
            if occupied.contains(route.prefix.description) {
                try perform(batch); batch.removeAll(keepingCapacity: true)
                if inheriting.contains(route), route.prefix.prefix == 128,
                   case .interface(let name) = route.destination, DNSRecoveryPolicy.validTunnel(name),
                   try observe6(route).isExactly(route) { continue }
                throw RouteExecutionError.existingRoute(route.prefix.description)
            }
            batch.append(.ipv6(.init(action: .add, route: route)))
            if batch.count == Self.batchSize { try perform(batch); batch.removeAll(keepingCapacity: true) }
        }
        try perform(batch)
    }
    func refreshIPv6(added: [IPv6RouteTarget], removed: [IPv6RouteTarget]) throws {
        guard !ambiguous else { throw RouteExecutionError.ambiguousJournal }
        if !added.isEmpty { try applyIPv6(added) }
        try performChunks(removed.filter { owned6.contains($0) }.map { .ipv6(.init(action: .remove, route: $0)) })
    }
    private func observe6(_ route: IPv6RouteTarget) throws -> ObservedIPv6Route {
        if usesKernelWriter {
            if kernelReader == nil { kernelReader = try KernelRouteReader() }
            return try kernelReader!.observe(route)
        }
        return ObservedIPv6Route(commandOutput: try run("/sbin/route", ["-n", "get", "-inet6", "-net", route.prefix.description]))
    }
    /// Bounded system-tool invocation: never run a shell or external profile
    /// commands, and never let a stuck route/netstat command hang the root queue.
    @discardableResult
    static func command(_ executable: String, _ arguments: [String]) throws -> String {
        return try autoreleasepool {
        let allowlisted: Set<String> = [
            "/sbin/route", "/usr/sbin/netstat", "/sbin/ifconfig", "/usr/bin/dscacheutil"
        ]
        guard allowlisted.contains(executable) else {
            throw RouteExecutionError.disallowedExecutable
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        // Wait for completion directly rather than polling this worker's run loop
        // once for each of the thousands of short-lived routing commands.
        let terminated = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in terminated.signal() }
        let output = Pipe()
        defer {
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
        }
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = output
        task.standardError = output
        do { try task.run() }
        catch { throw RouteExecutionError.commandLaunchFailed((error as NSError).code) }

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
        terminated.wait()
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
}

enum RouteExecutionError: Error, LocalizedError {
    case existingRoute(String), commandFailed(String), routeOwnershipLost(String)
    case commandLaunchFailed(Int)
    case kernelRouteFailed(Int)
    case ambiguousJournal, journalFailure, disallowedExecutable, commandOutputTooLarge

    var errorDescription: String? {
        switch self {
        case .kernelRouteFailed(let code):
            return "Kernel routing operation failed (errno \(code)); recovery evidence has been preserved."
        case .existingRoute(let prefix):
            return "An existing system route already covers \(prefix)."
        case .commandLaunchFailed(let code):
            return L10n.format("系统路由命令启动失败（错误 {0}），已保留恢复记录。", [String(code)])
        case .commandFailed(let command):
            return "The system network command failed: \(command)."
        case .routeOwnershipLost(let prefix):
            return "Cannot verify ownership of route \(prefix); refusing to delete it."
        case .ambiguousJournal:
            return "A previous route mutation may be incomplete. Manual network verification is required."
        case .journalFailure:
            return "Cannot durably record route changes. Recovery evidence has been preserved."
        case .disallowedExecutable:
            return "System tool is not permitted for privileged route execution."
        case .commandOutputTooLarge:
            return "Unexpectedly large system routing output; operation aborted."
        }
    }
}

