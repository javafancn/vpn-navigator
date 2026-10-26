import Foundation

/// Only these allowlisted fields leave the session model. In particular the
/// helper's free-form message and authentication challenge never enter history.
public struct ConnectionObservation: Sendable {
    public let state: TunnelState
    public let profileID: UUID?
    public let attemptID: UUID?
    public let mode: RoutingMode?
    public let stack: TunnelIPStack?
    public let traffic: TunnelTraffic?
    public let failure: DiagnosticCode?
    public let verifiedConnection: Bool
    public init(_ report: SessionReport) {
        state = report.state; profileID = report.activeProfileID; attemptID = report.attemptID
        mode = report.routingMode; stack = report.ipStack; traffic = report.traffic; failure = report.failureCode
        verifiedConnection = report.state == .connected && report.challenge == nil && !report.requiresNetworkRecovery &&
            report.routingMode != nil && (report.routingMode == .original || report.routingRevision != nil)
    }
}
public enum ConnectionHistoryEventKind: String, Codable, Sendable {
    case requested, adopted, connecting, authenticating, connected, reconnecting, stopping, disconnected, failed
    case modeChanged, verificationLost, observationResumed, counterReset, observationGap, observationEnded
    public var title: String {
        switch self {
        case .requested: return L10n.text("已提交连接请求")
        case .adopted: return L10n.text("开始观察现有会话")
        case .connecting: return L10n.text("正在连接")
        case .authenticating: return L10n.text("等待身份验证")
        case .connected: return L10n.text("隧道与路由已核验")
        case .reconnecting: return L10n.text("正在重连")
        case .stopping: return L10n.text("正在断开与恢复")
        case .disconnected: return L10n.text("会话已停止")
        case .failed: return L10n.text("连接失败")
        case .modeChanged: return L10n.text("路由模式已切换")
        case .verificationLost: return L10n.text("助手状态暂时无法核验")
        case .observationResumed: return L10n.text("恢复会话观察")
        case .counterReset: return L10n.text("引擎流量计数重置，已重新采样")
        case .observationGap: return L10n.text("采集间断，已重新采样")
        case .observationEnded: return L10n.text("观察结束，未推断 VPN 是否断开")
        }
    }
}
public struct ConnectionHistoryEvent: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let date: Date
    public let kind: ConnectionHistoryEventKind
    public let mode: RoutingMode?
    public let failure: DiagnosticCode?
    init(date: Date, kind: ConnectionHistoryEventKind, mode: RoutingMode? = nil, failure: DiagnosticCode? = nil) {
        id = UUID(); self.date = date; self.kind = kind; self.mode = mode; self.failure = failure
    }
}
public enum ConnectionHistoryOutcome: String, Codable, Sendable {
    case observing, completed, cancelled, failed, interrupted
    public var title: String {
        switch self {
        case .observing: return L10n.text("观察中")
        case .completed: return L10n.text("已断开")
        case .cancelled: return L10n.text("已取消")
        case .failed: return L10n.text("连接失败")
        case .interrupted: return L10n.text("观察中断")
        }
    }
}
public struct ConnectionHistoryRecord: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let profileID: UUID
    public let attemptID: UUID
    public let beganAt: Date
    public var lastObservedAt: Date
    public var endedAt: Date?
    public var outcome: ConnectionHistoryOutcome = .observing
    public var observedConnectedSeconds: Double = 0
    public var receivedBytes: UInt64 = 0
    public var sentBytes: UInt64 = 0
    public var everConnected = false
    public var events: [ConnectionHistoryEvent] = []
    mutating func add(_ kind: ConnectionHistoryEventKind, at date: Date, mode: RoutingMode? = nil, failure: DiagnosticCode? = nil) {
        if let last = events.last, last.kind == kind, last.mode == mode, last.failure == failure { return }
        events.append(.init(date: date, kind: kind, mode: mode, failure: failure))
        if events.count > 40 { events.removeFirst(events.count - 40) }
    }
}
public struct ConnectionHistoryPreferences: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var retentionDays: Int
    public init(enabled: Bool = true, retentionDays: Int = 7) { self.enabled = enabled; self.retentionDays = retentionDays }
    public var isValid: Bool { [7, 30, 90].contains(retentionDays) }
}
public struct ConnectionHistoryArchive: Codable, Equatable, Sendable {
    public var schema = 1
    public var preferences = ConnectionHistoryPreferences()
    public var records: [ConnectionHistoryRecord] = []
    public init() {}
    public func validate() throws {
        guard schema == 1, preferences.isValid, records.count <= 200, Set(records.map(\.id)).count == records.count else { throw ConnectionHistoryFailure.invalidArchive }
        for row in records {
            guard [row.beganAt, row.lastObservedAt, row.endedAt].compactMap({ $0 }).allSatisfy({ $0.timeIntervalSince1970.isFinite }),
                  row.observedConnectedSeconds.isFinite, (0...10_000_000_000).contains(row.observedConnectedSeconds), row.events.count <= 40,
                  Set(row.events.map(\.id)).count == row.events.count, row.events.allSatisfy({ $0.date.timeIntervalSince1970.isFinite }) else { throw ConnectionHistoryFailure.invalidArchive }
        }
    }
}
public struct ConnectionQualitySnapshot: Equatable, Sendable {
    public var profileID: UUID?
    public var verified = false
    public var receivedPerSecond: Double?
    public var sentPerSecond: Double?
    public var receivedBytes: UInt64 = 0
    public var sentBytes: UInt64 = 0
    public var observedConnectedSeconds: Double = 0
    public init() {}
}
public enum ConnectionHistoryInput: Sendable {
    case begin(profileID: UUID, attemptID: UUID)
    case report(ConnectionObservation)
    case unverified
    case userStop
    case requestFailed(attemptID: UUID)
}

/// A deterministic observer. It has no connection/network mutation capability.
/// Duration and speed use monotonic samples; gaps over 15 seconds are excluded.
public struct ConnectionHistoryTracker: Sendable {
    public private(set) var preferences: ConnectionHistoryPreferences
    public private(set) var quality = ConnectionQualitySnapshot()
    private var finished: [ConnectionHistoryRecord]
    private var active: ConnectionHistoryRecord?
    private var recordingActive = false
    private var lastState: TunnelState?
    private var lastMode: RoutingMode?
    private var verified = false
    private var userStop = false
    private struct Sample: Sendable { let traffic: TunnelTraffic; let uptime: Double; let date: Date }
    private var sample: Sample?
    private struct Tick: Sendable { let uptime: Double; let date: Date }
    private var verifiedTick: Tick?

    public init(archive: ConnectionHistoryArchive = .init(), now: Date = Date()) {
        preferences = archive.preferences; finished = archive.records
        // A persisted observing row only proves observation until its last
        // checkpoint. Do not count the app's absence as connected time.
        for i in finished.indices where finished[i].outcome == .observing {
            finished[i].outcome = .interrupted; finished[i].endedAt = finished[i].lastObservedAt
            finished[i].add(.observationEnded, at: finished[i].lastObservedAt)
        }
        prune(now: now)
    }
    public var records: [ConnectionHistoryRecord] {
        var result = finished
        if recordingActive, let active { result.append(active) }
        return Array(result.sorted { $0.lastObservedAt > $1.lastObservedAt }.prefix(200))
    }
    public var archive: ConnectionHistoryArchive {
        var value = ConnectionHistoryArchive(); value.preferences = preferences; value.records = records; return value
    }
    public mutating func configure(_ value: ConnectionHistoryPreferences, now: Date) throws {
        guard value.isValid else { throw ConnectionHistoryFailure.invalidArchive }
        if value.enabled != preferences.enabled {
            let current = active
            finish(.interrupted, kind: .observationEnded, at: now)
            preferences = value
            if let current { startObservation(profile: current.profileID, attempt: current.attemptID, at: now, adopted: true) }
        } else { preferences = value }
        prune(now: now)
    }
    public mutating func clearAndPause(now: Date) {
        // No hidden session tombstone is retained. Pausing prevents the next
        // poll from immediately recreating what the user just cleared.
        finished = []; preferences.enabled = false; recordingActive = false
        if var active { active.events = []; self.active = active }
        prune(now: now)
    }
    private mutating func startObservation(profile: UUID, attempt: UUID, at now: Date, adopted: Bool) {
        active = .init(id: UUID(), profileID: profile, attemptID: attempt, beganAt: now, lastObservedAt: now)
        recordingActive = preferences.enabled; sample = nil; verifiedTick = nil; lastState = nil; lastMode = nil; verified = false; userStop = false
        quality = .init(); quality.profileID = profile
        active?.add(adopted ? .adopted : .requested, at: now)
    }
    private mutating func finish(_ outcome: ConnectionHistoryOutcome, kind: ConnectionHistoryEventKind, at now: Date, failure: DiagnosticCode? = nil) {
        guard var value = active else { return }
        value.outcome = outcome; value.endedAt = now; value.lastObservedAt = now; value.add(kind, at: now, failure: failure)
        if recordingActive { finished.append(value) }
        active = nil; recordingActive = false; sample = nil; verifiedTick = nil; verified = false; lastState = nil; lastMode = nil
        quality = .init()
    }
    public mutating func consume(_ input: ConnectionHistoryInput, at now: Date, uptime: Double) {
        guard now.timeIntervalSince1970.isFinite, uptime.isFinite, uptime >= 0 else { return }
        defer { prune(now: now) }
        switch input {
        case .begin(let profile, let attempt):
            if active?.attemptID == attempt && active?.profileID == profile { return }
            if let active { finish(.interrupted, kind: .observationEnded, at: active.lastObservedAt) }
            startObservation(profile: profile, attempt: attempt, at: now, adopted: false)
        case .userStop: userStop = true
        case .unverified:
            if verified { active?.add(.verificationLost, at: now) }
            active?.lastObservedAt = now
            verified = false; sample = nil; verifiedTick = nil; quality.verified = false; quality.receivedPerSecond = nil; quality.sentPerSecond = nil
        case .requestFailed(let attempt):
            guard active?.attemptID == attempt else { return }
            finish(.failed, kind: .failed, at: now)
        case .report(let observation):
            let terminal = observation.state == .disconnected || observation.state == .failed
            // Repeated terminal polls do not create new rows, and a terminal
            // response from an older attempt cannot end a newer request.
            if terminal, active == nil { return }
            if terminal, let attempt = observation.attemptID, attempt != active?.attemptID { return }
            if let id = observation.attemptID, let profile = observation.profileID {
                if terminal, profile != active?.profileID { return }
                if active?.attemptID != id || active?.profileID != profile {
                    if let active { finish(.interrupted, kind: .observationEnded, at: active.lastObservedAt) }
                    startObservation(profile: profile, attempt: id, at: now, adopted: true)
                }
            }
            guard let current = active else { return }
            if let attempt = observation.attemptID, attempt != current.attemptID { return }
            if let profile = observation.profileID, profile != current.profileID { return }
            guard observation.attemptID != nil else {
                consume(.unverified, at: now, uptime: uptime); return
            }
            active?.lastObservedAt = now
            if observation.state == .disconnected || observation.state == .failed {
                let outcome: ConnectionHistoryOutcome = observation.state == .failed ? .failed : userStop && !current.everConnected ? .cancelled : .completed
                finish(outcome, kind: observation.state == .failed ? .failed : .disconnected, at: now, failure: observation.failure)
                return
            }
            if observation.state == .connected && !observation.verifiedConnection {
                consume(.unverified, at: now, uptime: uptime); return
            }
            if !verified, lastState != nil { active?.add(.observationResumed, at: now) }
            verified = true
            if observation.state != lastState {
                let kind: ConnectionHistoryEventKind
                switch observation.state {
                case .connecting: kind = .connecting
                case .authenticating: kind = .authenticating
                case .connected: kind = .connected
                case .reconnecting: kind = .reconnecting
                case .stopping: kind = .stopping
                case .failed, .disconnected: return
                }
                active?.add(kind, at: now, mode: observation.mode)
            }
            if observation.state == .connected {
                if let old = lastMode, let next = observation.mode, old != next { active?.add(.modeChanged, at: now, mode: next) }
                lastMode = observation.mode; active?.everConnected = true
                recordDuration(at: now, uptime: uptime)
                record(observation.traffic, at: now, uptime: uptime)
            } else { sample = nil; verifiedTick = nil; quality.verified = false; quality.receivedPerSecond = nil; quality.sentPerSecond = nil }
            lastState = observation.state
        }
    }
    private mutating func recordDuration(at now: Date, uptime: Double) {
        defer { verifiedTick = .init(uptime: uptime, date: now) }
        guard let previous = verifiedTick else { return }
        let elapsed = uptime - previous.uptime, wall = now.timeIntervalSince(previous.date)
        guard elapsed >= 0, elapsed <= 15, wall >= 0, wall <= 15 else { active?.add(.observationGap, at: now); return }
        quality.observedConnectedSeconds += elapsed
        active?.observedConnectedSeconds = quality.observedConnectedSeconds
    }
    private mutating func record(_ counters: TunnelTraffic?, at now: Date, uptime: Double) {
        quality.verified = true
        guard let counters else { sample = nil; quality.receivedPerSecond = nil; quality.sentPerSecond = nil; return }
        guard let previous = sample else { sample = .init(traffic: counters, uptime: uptime, date: now); return }
        let elapsed = uptime - previous.uptime, wall = now.timeIntervalSince(previous.date)
        guard elapsed >= 0, elapsed <= 15, wall >= 0, wall <= 15 else {
            active?.add(.observationGap, at: now); sample = .init(traffic: counters, uptime: uptime, date: now)
            quality.receivedPerSecond = nil; quality.sentPerSecond = nil; return
        }
        guard counters.receivedBytes >= previous.traffic.receivedBytes, counters.sentBytes >= previous.traffic.sentBytes else {
            active?.add(.counterReset, at: now); sample = .init(traffic: counters, uptime: uptime, date: now)
            quality.receivedPerSecond = nil; quality.sentPerSecond = nil; return
        }
        guard elapsed >= 0.5 else { return }
        let receive = counters.receivedBytes - previous.traffic.receivedBytes, send = counters.sentBytes - previous.traffic.sentBytes
        func add(_ old: UInt64, _ delta: UInt64) -> UInt64 { let value = old.addingReportingOverflow(delta); return value.overflow ? UInt64.max : value.partialValue }
        quality.receivedBytes = add(quality.receivedBytes, receive); quality.sentBytes = add(quality.sentBytes, send)
        quality.receivedPerSecond = Double(receive) / elapsed; quality.sentPerSecond = Double(send) / elapsed
        active?.receivedBytes = quality.receivedBytes; active?.sentBytes = quality.sentBytes; active?.observedConnectedSeconds = quality.observedConnectedSeconds
        sample = .init(traffic: counters, uptime: uptime, date: now)
    }
    private mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Double(preferences.retentionDays) * 86_400)
        finished = Array(finished.filter { $0.lastObservedAt >= cutoff }.sorted { $0.lastObservedAt > $1.lastObservedAt }.prefix(recordingActive ? 199 : 200))
    }
}
public enum ConnectionHistoryFailure: Error, LocalizedError {
    case invalidArchive, storage
    public var errorDescription: String? {
        switch self {
        case .invalidArchive: return L10n.text("连接历史无法解析或格式不受支持；请先检查，或明确清空后重新记录。")
        case .storage: return L10n.text("连接历史无法保存，请检查本机目录权限和磁盘空间；VPN 连接不受影响。")
        }
    }
}
