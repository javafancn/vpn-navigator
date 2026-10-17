import Foundation
import Network
import VPNNavigatorCore

struct LocalNetworkSnapshot: Sendable {
    let gateway: String
    let interface: String
    let health: NetworkHealthSummary
}
struct TCPProbeResult: Sendable {
    let reachable: Bool
    let milliseconds: Double
    let summary: String
}
enum NetworkProbes {
    static func localSnapshot(target: String) async throws -> LocalNetworkSnapshot {
        guard IPv4CIDR.parseAddress(target) != nil else { throw ProbeError.invalidTarget }
        async let route = BoundedProbeCommand.run("/sbin/route", ["-n", "get", target])
        async let ipv6 = BoundedProbeCommand.run("/usr/sbin/netstat", ["-rn", "-f", "inet6"])
        async let defaultRoute = BoundedProbeCommand.run("/sbin/route", ["-n", "get", "default"])
        async let dns = BoundedProbeCommand.run("/usr/sbin/scutil", ["--dns"])
        let values = try await (route, ipv6, defaultRoute, dns)
        return .init(gateway: field("gateway", values.0), interface: field("interface", values.0),
                     health: NetworkHealthSummary(ipv6Table: values.1, defaultIPv4Route: values.2, dnsSummary: values.3))
    }
    private static func field(_ key: String, _ text: String) -> String {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix(key + ":") }?.split(separator: ":", maxSplits: 1).last
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }
    static func dns(_ hostname: String) async throws -> String {
        guard DiagnosticTargetPolicy.validHostname(hostname) else { throw ProbeError.invalidTarget }
        let output = try await BoundedProbeCommand.run("/usr/bin/dscacheutil", ["-q", "host", "-a", "name", hostname])
        let addresses = output.components(separatedBy: .newlines).filter {
            $0.hasPrefix("ip_address:") || $0.hasPrefix("ipv6_address:")
        }.prefix(20)
        guard !addresses.isEmpty else { throw ProbeError.noDNSAnswer }
        return addresses.joined(separator: "\n")
    }
    static func ping(_ address: String) async throws -> PingSummary {
        guard IPv4CIDR.parseAddress(address) != nil else { throw ProbeError.invalidTarget }
        let output = try await BoundedProbeCommand.run("/sbin/ping", ["-n", "-c", "3", "-W", "1000", address], timeout: 8, allowNonzero: true)
        guard let result = PingSummary.parse(output) else { throw ProbeError.noPingAnswer }
        return result
    }
    static func trace(_ address: String) async throws -> String {
        guard IPv4CIDR.parseAddress(address) != nil else { throw ProbeError.invalidTarget }
        return try await BoundedProbeCommand.run("/usr/sbin/traceroute", ["-n", "-m", "8", "-q", "1", "-w", "1", address], timeout: 12, allowNonzero: true)
    }
    static func tcp(_ address: String, port: UInt16) async throws -> TCPProbeResult {
        guard IPv4CIDR.parseAddress(address) != nil, port > 0 else { throw ProbeError.invalidTarget }
        let request = TCPProbeRequest()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                request.start(address: address, port: port, continuation: continuation)
            }
        } onCancel: { request.finish(.failure(CancellationError())) }
    }
}

private final class TCPProbeRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var completed: Result<TCPProbeResult, Error>?
    private var continuation: CheckedContinuation<TCPProbeResult, Error>?
    private var connection: NWConnection?
    private var timer: DispatchSourceTimer?
    func start(address: String, port: UInt16, continuation: CheckedContinuation<TCPProbeResult, Error>) {
        lock.lock()
        if let completed { lock.unlock(); continuation.resume(with: completed); return }
        self.continuation = continuation
        let connection = NWConnection(host: .init(address), port: .init(rawValue: port)!, using: .tcp)
        let began = Date()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        self.connection = connection; self.timer = timer
        connection.stateUpdateHandler = { [weak self] state in
            let elapsed = Date().timeIntervalSince(began) * 1000
            switch state {
            case .ready: self?.finish(.success(.init(reachable: true, milliseconds: elapsed, summary: "TCP 连接成功")))
            case .failed: self?.finish(.success(.init(reachable: false, milliseconds: elapsed, summary: "TCP 连接失败")))
            default: break
            }
        }
        timer.schedule(deadline: .now() + 5)
        timer.setEventHandler { [weak self] in
            self?.finish(.success(.init(reachable: false, milliseconds: 5000, summary: "TCP 连接超时")))
        }
        connection.start(queue: .global(qos: .utility)); timer.resume()
        lock.unlock()
    }
    func finish(_ result: Result<TCPProbeResult, Error>) {
        lock.lock()
        guard completed == nil else { lock.unlock(); return }
        completed = result
        let reply = continuation; continuation = nil
        let task = connection; connection = nil
        let timeout = timer; timer = nil
        lock.unlock()
        timeout?.cancel(); task?.stateUpdateHandler = nil; task?.cancel()
        reply?.resume(with: result)
    }
}

enum ProbeError: Error, LocalizedError {
    case invalidTarget, timedOut, commandFailed, noDNSAnswer, noPingAnswer
    var errorDescription: String? {
        switch self {
        case .invalidTarget: return "请输入有效的 IPv4 地址、端口或域名。"
        case .timedOut: return "探测超时，可更换目标后重试。"
        case .commandFailed: return "系统探测未成功，请检查网络与诊断目标。"
        case .noDNSAnswer: return "系统解析器未返回地址。"
        case .noPingAnswer: return "未取得可解析的 ICMP 结果。目标也可能禁用 ICMP。"
        }
    }
}

private final class ProbeCommandCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private(set) var cancelled = false
    private(set) var expired = false
    func launch(_ task: Process) throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        try task.run(); process = task
    }
    func cancel(expired: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        cancelled = true; self.expired = expired
        if let process, process.isRunning { process.terminate() }
    }
    func result() -> (cancelled: Bool, expired: Bool) {
        lock.lock(); defer { lock.unlock() }
        process = nil
        return (cancelled, expired)
    }
}
enum BoundedProbeCommand {
    static func run(_ executable: String, _ arguments: [String], timeout: Int = 6, allowNonzero: Bool = false) async throws -> String {
        let allowed: Set<String> = ["/sbin/route", "/usr/sbin/netstat", "/usr/sbin/scutil", "/usr/bin/dscacheutil", "/sbin/ping", "/usr/sbin/traceroute"]
        guard allowed.contains(executable) else { throw ProbeError.commandFailed }
        let cancellation = ProbeCommandCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let task = Process(), output = Pipe()
                    task.executableURL = URL(fileURLWithPath: executable); task.arguments = arguments
                    task.standardOutput = output; task.standardError = output
                    do {
                        try cancellation.launch(task)
                        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                        timer.schedule(deadline: .now() + .seconds(timeout))
                        timer.setEventHandler { cancellation.cancel(expired: true) }
                        timer.resume()
                        let bytes = output.fileHandleForReading.readDataToEndOfFile()
                        task.waitUntilExit(); timer.cancel()
                        let status = cancellation.result()
                        if status.expired { throw ProbeError.timedOut }
                        if status.cancelled { throw CancellationError() }
                        guard bytes.count < 2_000_000, allowNonzero || task.terminationStatus == 0 else { throw ProbeError.commandFailed }
                        continuation.resume(returning: String(decoding: bytes, as: UTF8.self))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { cancellation.cancel() }
    }
}
