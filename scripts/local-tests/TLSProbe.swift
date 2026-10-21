import Foundation
import Darwin

// Disposable CI only; never bundled in the app or installed as a root tool.
// The installer fixture explicitly approves this client's CDHash temporarily.
@objc protocol TLSHelper {
    func connect(profile: String, profileID: String, mode: String, rules: String,
                 username: String, password: String, preferences: String, attemptID: String,
                 reply: @escaping (String) -> Void)
    func disconnect(cancelAttemptID: String, reply: @escaping (String) -> Void)
    func disconnectSession(expectedProfileID: String, expectedAttemptID: String, reply: @escaping (String) -> Void)
    func recoverOrphanedRoutes(reply: @escaping (String) -> Void)
    func connectionStatus(reply: @escaping (String) -> Void)
    func sessionSnapshot(reply: @escaping (String) -> Void)
    func diagnosticEvents(reply: @escaping (String) -> Void)
    func submitChallenge(id: String, response: String, reply: @escaping (String) -> Void)
}
final class Reply: @unchecked Sendable {
    let lock = NSLock(); var done = false; let finish: (String) -> Void
    init(_ finish: @escaping (String) -> Void) { self.finish = finish }
    func send(_ value: String) { lock.lock(); let first = !done; done = true; lock.unlock(); if first { finish(value) } }
}
func ask(_ block: @escaping (TLSHelper, @escaping (String) -> Void) -> Void) async -> String {
    await withCheckedContinuation { continuation in
        let connection = NSXPCConnection(machServiceName: "com.javafancn.vpn-navigator.helper", options: .privileged)
        let once = Reply { value in connection.invalidate(); continuation.resume(returning: value) }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: "/Library/Application Support/VPNNavigator/Local/manifest.json"))
            let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let binaries = object["binaries"] as! [String: [String: String]]
            let hash = binaries["helper"]!["cdhash"]!
            guard hash.count == 40 && hash.allSatisfy({ $0.isHexDigit }) else { throw NSError(domain: "fixture", code: 1) }
            connection.setCodeSigningRequirement("identifier \"com.javafancn.vpn-navigator.helper\" and cdhash H\"\(hash)\"")
        } catch { once.send("ERROR: fixture approval"); return }
        connection.remoteObjectInterface = NSXPCInterface(with: TLSHelper.self)
        connection.invalidationHandler = { once.send("ERROR: unavailable") }
        connection.interruptionHandler = { once.send("ERROR: interrupted") }
        connection.resume()
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) { once.send("ERROR: timeout") }
        guard let api = connection.remoteObjectProxyWithErrorHandler({ _ in once.send("ERROR: rejected") }) as? TLSHelper else {
            once.send("ERROR: proxy"); return
        }
        block(api) { once.send($0) }
    }
}
func disconnect() async -> Bool {
    await ask { $0.disconnect(cancelAttemptID: "", reply: $1) } == "Disconnected"
}
struct Factor: Decodable {
    let kind: String
    let response: String
}
struct Scenario: Decodable {
    let name: String
    let profilePath: String
    let username: String
    let password: String
    let outcome: String
    let factors: [Factor]
    let forbidden: [String]
}
func scenario(_ test: Scenario) async -> Bool {
    guard ["connected", "failed", "cancelled"].contains(test.outcome),
          let profile = try? String(contentsOfFile: test.profilePath) else { return false }
    let attempt = UUID().uuidString
    let preferences = #"{"connectionTimeout":30,"reconnectOriginal":false,"killSwitch":false,"reconnectManaged":false}"#
    let started = await ask {
        $0.connect(profile: profile, profileID: UUID().uuidString, mode: "Original", rules: "",
                   username: test.username, password: test.password, preferences: preferences, attemptID: attempt, reply: $1)
    }
    guard !started.hasPrefix("ERROR:") else { return false }
    var seen = Set<String>(), replies = 0, matched = false
    var previousState = ""
    var cancelledID: String?
    for _ in 0..<160 {
        let raw = await ask { $0.sessionSnapshot(reply: $1) }
        guard !test.forbidden.contains(where: { !$0.isEmpty && raw.contains($0) }),
              let data = raw.data(using: .utf8),
              let report = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let state = report["state"] as? String else { return false }
        if state != previousState { print("Authentication fixture state: " + state); previousState = state }
        if let factor = report["challenge"] as? [String: Any],
           let id = factor["id"] as? String, seen.insert(id).inserted {
            guard replies < test.factors.count,
                  factor["kind"] as? String == test.factors[replies].kind else { return false }
            if test.outcome == "cancelled", replies == test.factors.count - 1 {
                cancelledID = id
                let result = await ask { $0.disconnect(cancelAttemptID: attempt, reply: $1) }
                matched = result == "Disconnected"
                replies += 1
                break
            }
            let result = await ask { $0.submitChallenge(id: id, response: test.factors[replies].response, reply: $1) }
            guard result == "Accepted" else { return false }
            replies += 1
            // Every accepted prompt is single use, even before the next state.
            let duplicate = await ask { $0.submitChallenge(id: id, response: "fixture-duplicate", reply: $1) }
            guard duplicate.hasPrefix("ERROR:") else { return false }
        }
        if state == "connected" || state == "failed" {
            // Active sessions intentionally retain their PID/DNS evidence.
            // Recovery must be clear only after failure or explicit disconnect.
            matched = state == test.outcome && (state == "connected" || report["networkRecoveryRequired"] as? Bool == false)
            break
        }
        try? await Task.sleep(nanoseconds: 250_000_000)
    }
    guard matched, replies == test.factors.count else { print("Terminal/factor mismatch"); return false }
    if let id = cancelledID {
        let stale = await ask { $0.submitChallenge(id: id, response: "fixture-stale", reply: $1) }
        guard stale.hasPrefix("ERROR:") else { return false }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let status = await ask { $0.connectionStatus(reply: $1) }
        guard status.hasPrefix("disconnected:") else { return false }
    }
    let events = await ask { $0.diagnosticEvents(reply: $1) }
    guard !test.forbidden.contains(where: { !$0.isEmpty && events.contains($0) }) else { print("Secret in diagnostic events"); return false }
    let stopped = await disconnect()
    guard stopped else { print("Disconnect was not confirmed"); return false }
    for _ in 0..<3 {
      try? await Task.sleep(nanoseconds: 200_000_000)
      let cleaned = await ask { $0.sessionSnapshot(reply: $1) }
      guard let cleanData = cleaned.data(using: .utf8),
          let cleanReport = (try? JSONSerialization.jsonObject(with: cleanData)) as? [String: Any],
          cleanReport["state"] as? String == "disconnected",
          cleanReport["networkRecoveryRequired"] as? Bool == false else {
        // Only controlled enum/bool fields; never print raw reports or secrets.
        if let cleanData = cleaned.data(using: .utf8),
           let report = (try? JSONSerialization.jsonObject(with: cleanData)) as? [String: Any] {
            print("Cleanup state: \(report["state"] as? String ?? "missing"); recovery: \(String(describing: report["networkRecoveryRequired"] as? Bool))")
        } else { print("Cleanup snapshot unavailable") }
        return false
      }
    }
    print("PASS: authentication scenario " + test.name)
    return true
}
func expectFailure() async -> Bool {
    for _ in 0..<80 {
        let raw = await ask { $0.sessionSnapshot(reply: $1) }
        if let data = raw.data(using: .utf8),
           let report = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           report["state"] as? String == "failed",
           report["networkRecoveryRequired"] as? Bool == false {
            return await disconnect()
        }
        try? await Task.sleep(nanoseconds: 250_000_000)
    }
    return false
}
func exercise(_ profile: String, shouldConnect: Bool, disconnectAtEnd: Bool = true) async -> Bool {
    let preferences = #"{"connectionTimeout":20,"reconnectOriginal":false,"killSwitch":false,"reconnectManaged":false}"#
    let profileID = UUID().uuidString, attemptID = UUID().uuidString
    let result = await ask {
        $0.connect(profile: profile, profileID: profileID, mode: "Original", rules: "",
                   username: "", password: "", preferences: preferences, attemptID: attemptID, reply: $1)
    }
    guard !result.hasPrefix("ERROR:") else { print(result); _ = await disconnect(); return false }
    var matched = false
    var previousStatus = ""
    for _ in 0..<60 {
        let status = await ask { $0.connectionStatus(reply: $1) }
        if status != previousStatus { print("Observed: " + status); previousStatus = status }
        if status.hasPrefix("connected:") { matched = shouldConnect; break }
        if status.hasPrefix("failed:") { matched = !shouldConnect; break }
        if shouldConnect && status.hasPrefix("disconnected:") { break }
        if status.hasPrefix("ERROR:") { print(status); break }
        try? await Task.sleep(nanoseconds: 500_000_000)
    }
    if matched && shouldConnect {
        for (expectedProfile, expectedAttempt) in [(profileID, UUID().uuidString), (UUID().uuidString, attemptID), ("invalid", attemptID)] {
            let refused = await ask { $0.disconnectSession(expectedProfileID: expectedProfile, expectedAttemptID: expectedAttempt, reply: $1) }
            guard refused.hasPrefix("ERROR:"), (await ask { $0.connectionStatus(reply: $1) }).hasPrefix("connected:") else { return false }
        }
        print("PASS: stale/malformed switch identities leave the real TLS session connected.")
    }
    if !disconnectAtEnd { return matched }
    let cleaned: Bool
    if matched && shouldConnect {
        cleaned = await ask { $0.disconnectSession(expectedProfileID: profileID, expectedAttemptID: attemptID, reply: $1) } == "Disconnected"
    } else { cleaned = await disconnect() }
    if !cleaned { print("Disconnect did not confirm cleanup") }
    return matched && cleaned
}
Task {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.count == 2, arguments[0] == "--scenario",
       let data = try? Data(contentsOf: URL(fileURLWithPath: arguments[1])),
       let test = try? JSONDecoder().decode(Scenario.self, from: data) {
        let passed = await scenario(test)
        if !passed { _ = await disconnect(); print("FAIL: authentication fixture (secrets omitted)") }
        exit(passed ? 0 : 1)
    }
    if arguments == ["--expect-failed"] { exit(await expectFailure() ? 0 : 1) }
    if arguments == ["--disconnect"] { exit(await disconnect() ? 0 : 1) }
    if arguments == ["--recover"] {
        let result = await ask { $0.recoverOrphanedRoutes(reply: $1) }
        guard !result.hasPrefix("ERROR:") else { print(result); exit(1) }
        let status = await ask { $0.connectionStatus(reply: $1) }
        print("Recovered: " + status)
        exit(status.hasPrefix("disconnected:") ? 0 : 1)
    }
    if arguments.count == 2, arguments[0] == "--connect-only",
       let profile = try? String(contentsOfFile: arguments[1]) {
        exit(await exercise(profile, shouldConnect: true, disconnectAtEnd: false) ? 0 : 1)
    }
    guard arguments.count == 2, let valid = try? String(contentsOfFile: arguments[0]),
          let invalid = try? String(contentsOfFile: arguments[1]) else { exit(1) }
    for _ in 0..<2 {
        guard await exercise(valid, shouldConnect: true) else { print("Real TLS/utun connection or cleanup failed"); exit(1) }
    }
    guard await exercise(invalid, shouldConnect: false) else { print("Wrong-CA session did not reach a clean rejected state"); exit(1) }
    print("PASS: real certificate TLS, utun, disconnect/reconnect and wrong-CA rejection through installed helper.")
    exit(0)
}
RunLoop.current.run()
