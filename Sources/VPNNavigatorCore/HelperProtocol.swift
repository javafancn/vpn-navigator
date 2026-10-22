import Foundation

/// IPC contract shared by the unprivileged app and the privileged macOS launch daemon.
/// No file paths or arbitrary shell commands are accepted from the GUI.
@objc public protocol VPNNavigatorHelperAPI {
    func prepareLocalMaintenance(reply: @escaping (String) -> Void)
    func health(reply: @escaping (String) -> Void)
    func connect(profile: String, profileID: String, mode: String, rules: String,
                 username: String, password: String, preferences: String, attemptID: String,
                 reply: @escaping (String) -> Void)
    func submitChallenge(id: String, response: String, reply: @escaping (String) -> Void)
    func diagnosticEvents(reply: @escaping (String) -> Void)
    func disconnect(cancelAttemptID: String, reply: @escaping (String) -> Void)
    func disconnectSession(expectedProfileID: String, expectedAttemptID: String, reply: @escaping (String) -> Void)
    func connectionStatus(reply: @escaping (String) -> Void)
    func sessionSnapshot(reply: @escaping (String) -> Void)
    func activeProfile(reply: @escaping (String) -> Void)
    func trafficStatus(reply: @escaping (String) -> Void)
    func updateRules(_ text: String, reply: @escaping (String) -> Void)
    func switchRoutingMode(mode: String, rules: String, expectedProfileID: String, expectedAttemptID: String,
                           expectedMode: String, expectedRevision: String, reply: @escaping (String) -> Void)
    func explainRoute(_ request: String, reply: @escaping (String) -> Void)
    func recoverOrphanedRoutes(reply: @escaping (String) -> Void)
}

public enum HelperIdentity {
    public static let machService = "com.javafancn.vpn-navigator.helper"
    public static let plistName = "com.javafancn.vpn-navigator.helper.plist"
}

