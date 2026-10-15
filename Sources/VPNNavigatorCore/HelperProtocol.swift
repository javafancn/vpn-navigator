import Foundation

/// IPC contract shared by the unprivileged app and the privileged macOS launch daemon.
/// No file paths or arbitrary shell commands are accepted from the GUI.
@objc public protocol VPNNavigatorHelperAPI {
    func health(reply: @escaping (String) -> Void)
    func connect(profile: String, mode: String, rules: String,
                 username: String, password: String,
                 reply: @escaping (String) -> Void)
    func disconnect(reply: @escaping (String) -> Void)
    func connectionStatus(reply: @escaping (String) -> Void)
    func trafficStatus(reply: @escaping (String) -> Void)
    func updateRules(_ text: String, reply: @escaping (String) -> Void)
    func recoverOrphanedRoutes(reply: @escaping (String) -> Void)
}

public enum HelperIdentity {
    public static let machService = "com.javafancn.vpn-navigator.helper"
    public static let plistName = "com.javafancn.vpn-navigator.helper.plist"
}
