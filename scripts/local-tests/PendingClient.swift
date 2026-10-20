import Foundation
import Darwin

// Disposable fixture: deliberately bypasses the app's local preflight so the
// server's OS-enforced pending-install peer policy is tested independently.
@objc protocol PendingHealth { func health(reply: @escaping (String) -> Void) }
do {
    let data = try Data(contentsOf: URL(fileURLWithPath: "/Library/Application Support/VPNNavigator/Local/manifest.json"))
    let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let binaries = object["binaries"] as! [String: [String: String]]
    let hash = binaries["helper"]!["cdhash"]!
    guard hash.count == 40, hash.allSatisfy({ $0.isHexDigit }) else { exit(1) }
    let connection = NSXPCConnection(machServiceName: "com.javafancn.vpn-navigator.helper", options: .privileged)
    connection.setCodeSigningRequirement("identifier \"com.javafancn.vpn-navigator.helper\" and cdhash H\"\(hash)\"")
    connection.remoteObjectInterface = NSXPCInterface(with: PendingHealth.self)
    connection.invalidationHandler = { exit(1) }
    connection.interruptionHandler = { exit(1) }
    DispatchQueue.global().asyncAfter(deadline: .now() + 5) { exit(1) }
    connection.resume()
    let proxy = connection.remoteObjectProxyWithErrorHandler { _ in exit(1) } as! PendingHealth
    proxy.health { value in exit(value.hasPrefix("VPN Navigator Helper") ? 0 : 1) }
    RunLoop.current.run()
} catch { exit(1) }
