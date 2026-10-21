import Foundation
import ServiceManagement
import Darwin

/// User jobs are installed by the user process, never by a root installer
/// following a user-controlled home directory or accepting an arbitrary path.
public enum UserServices {
    private static let ruleLabel = "com.javafancn.vpn-navigator.local-rules"
    private static let loginLabel = "com.javafancn.vpn-navigator.local-login"
    private static var folder: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents", isDirectory: true) }
    public static var rulesStatus: SMAppService.Status {
        BuildChannel.isLocal ? localStatus(ruleLabel) : SMAppService.agent(plistName: "com.javafancn.vpn-navigator.rules.plist").status
    }
    public static var loginStatus: SMAppService.Status { BuildChannel.isLocal ? localStatus(loginLabel) : SMAppService.mainApp.status }
    public static func enableRules() throws {
        if BuildChannel.isLocal { try register(ruleLabel) }
        else { try SMAppService.agent(plistName: "com.javafancn.vpn-navigator.rules.plist").register() }
    }
    public static func disableRules() async throws {
        if BuildChannel.isLocal { try unregister(ruleLabel) }
        else { let service = SMAppService.agent(plistName: "com.javafancn.vpn-navigator.rules.plist"); if service.status != .notRegistered && service.status != .notFound { try await service.unregister() } }
    }
    public static func setLogin(_ enabled: Bool) throws {
        if BuildChannel.isLocal {
            if enabled { try register(loginLabel) }
            else { try unregister(loginLabel) }
        } else if enabled { try SMAppService.mainApp.register() }
        else {
            let service = SMAppService.mainApp
            if service.status != .notRegistered && service.status != .notFound { try service.unregister() }
        }
    }
    private static func localStatus(_ label: String) -> SMAppService.Status {
        let path = folder.appendingPathComponent(label + ".plist")
        guard FileManager.default.fileExists(atPath: path.path) else { return .notRegistered }
        do {
            try checked(folder); try checked(path)
            guard try Data(contentsOf: path) == jobData(label) else { return .requiresApproval }
            _ = try launchctl(["print", "gui/\(getuid())/\(label)"])
            return .enabled
        } catch { return .requiresApproval }
    }
    private static func checked(_ path: URL) throws {
        guard path.resolvingSymlinksInPath() == path.standardizedFileURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o022 == 0 else { throw LocalInstallError.unsafe }
    }
    private static func register(_ label: String) throws {
        guard getuid() != 0 else { throw LocalInstallError.unsafe }
        let approval = try LocalInstallation.load(); guard approval.ownerUID == getuid() else { throw LocalInstallError.unsafe }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try checked(folder)
        let path = folder.appendingPathComponent(label + ".plist")
        let data = try jobData(label)
        if FileManager.default.fileExists(atPath: path.path) { try checked(path) }
        try stop(label)
        try data.write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        _ = try launchctl(["enable", "gui/\(getuid())/\(label)"])
        _ = try launchctl(["bootstrap", "gui/\(getuid())", path.path])
    }
    private static func jobData(_ label: String) throws -> Data {
        let arguments = label == ruleLabel ? [LocalInstallation.executable(.agent).path] : ["/usr/bin/open", "-j", "-a", LocalInstallation.app.path]
        var plist: [String: Any] = ["Label": label, "ProgramArguments": arguments, "RunAtLoad": true, "LimitLoadToSessionType": "Aqua"]
        if label == ruleLabel { plist["StartInterval"] = 86400 }
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }
    private static func unregister(_ label: String) throws {
        let path = folder.appendingPathComponent(label + ".plist")
        if FileManager.default.fileExists(atPath: folder.path) { try checked(folder) }
        if FileManager.default.fileExists(atPath: path.path) { try checked(path) }
        try stop(label)
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }
    private static func stop(_ label: String) throws {
        let job = "gui/\(getuid())/\(label)"
        guard (try? launchctl(["print", job])) != nil else { return }
        _ = try? launchctl(["bootout", job])
        for _ in 0..<30 {
            if (try? launchctl(["print", job])) == nil { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw LocalInstallError.command
    }
    @discardableResult public static func launchctl(_ arguments: [String]) throws -> String {
        let task = Process(), pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl"); task.arguments = arguments
        task.standardOutput = pipe; task.standardError = pipe
        try task.run()
        let timer = DispatchSource.makeTimerSource(queue: .global()); timer.schedule(deadline: .now() + 8)
        timer.setEventHandler { if task.isRunning { task.terminate() } }; timer.resume()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit(); timer.cancel()
        guard task.terminationStatus == 0 else { throw LocalInstallError.command }
        return String(decoding: data, as: UTF8.self)
    }
}
