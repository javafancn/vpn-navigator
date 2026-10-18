import Foundation
import Darwin

// Disposable CI only; never bundled in the app or installed as a root tool.
// The installer fixture explicitly approves this client's CDHash temporarily.
@objc protocol TLSHelper {
    func connect(profile: String, profileID: String, mode: String, rules: String,
                 username: String, password: String, preferences: String, attemptID: String,
                 reply: @escaping (String) -> Void)
    func disconnect(cancelAttemptID: String, reply: @escaping (String) -> Void)
    func connectionStatus(reply: @escaping (String) -> Void)
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
func exercise(_ profile: String, shouldConnect: Bool) async -> Bool {
    let preferences = #"{"connectionTimeout":20,"reconnectOriginal":false,"killSwitch":false,"reconnectManaged":false}"#
    let result = await ask {
        $0.connect(profile: profile, profileID: UUID().uuidString, mode: "Original", rules: "",
                   username: "", password: "", preferences: preferences, attemptID: UUID().uuidString, reply: $1)
    }
    guard !result.hasPrefix("ERROR:") else { print(result); _ = await disconnect(); return false }
    var matched = false
    var previousStatus = ""
    for _ in 0..<60 {
        let status = await ask { $0.connectionStatus(reply: $1) }
        if status != previousStatus { print("Observed: " + status); previousStatus = status }
        if status.hasPrefix("connected:") { matched = shouldConnect; break }
        if status.hasPrefix("failed:") || status.hasPrefix("disconnected:") { matched = !shouldConnect; break }
        if status.hasPrefix("ERROR:") { print(status); break }
        try? await Task.sleep(nanoseconds: 500_000_000)
    }
    let cleaned = await disconnect()
    if !cleaned { print("Disconnect did not confirm cleanup") }
    return matched && cleaned
}
Task {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["--disconnect"] { exit(await disconnect() ? 0 : 1) }
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
