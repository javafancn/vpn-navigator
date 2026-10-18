import Foundation
import Darwin
import VPNNavigatorCore

@main enum LocalSetup {
    static func main() async {
        do {
            guard BuildChannel.isLocal else { throw LocalInstallError.invalid }
            let args = Array(CommandLine.arguments.dropFirst())
            if args.first == "template", args.count == 4, getuid() != 0 {
                try makeTemplate(app: URL(fileURLWithPath: args[1]), payload: URL(fileURLWithPath: args[2]), version: args[3])
            } else if args.first == "install", getuid() == 0 {
                let uid: UInt32
                if args.count == 3, args[1] == "--owner-uid", let value = UInt32(args[2]), value >= 500 { uid = value }
                else if args.count == 1 {
                    uid = (try FileManager.default.attributesOfItem(atPath: "/dev/console")[.ownerAccountID] as? NSNumber)?.uint32Value ?? 0
                } else { throw LocalInstallError.invalid }
                guard uid >= 500 else { throw LocalInstallError.invalid }
                try install(uid: uid)
                var healthy = false
                for _ in 0..<5 {
                    if await request({ $0.health(reply: $1) }).hasPrefix("VPN Navigator Helper") { healthy = true; break }
                    try await Task.sleep(nanoseconds: 300_000_000)
                }
                guard healthy else { _ = try? run(["bootout", "system/" + LocalInstallation.daemonLabel]); throw LocalInstallError.command }
                print("Local helper installed and authenticated. No Developer ID certificate used.")
            } else if args == ["uninstall"], getuid() == 0 {
                try LocalInstallation.protectedRoot()
                guard !LocalInstallation.hasRecoveryEvidence else { throw LocalInstallError.recoveryRequired }
                // The user process must remove its own login/rule jobs and
                // retire the root service before system payload removal.
                guard !FileManager.default.fileExists(atPath: LocalInstallation.manifest.path) else { throw LocalInstallError.recoveryRequired }
                let approval = try LocalInstallation.decode(LocalInstallation.retired)
                _ = try? run(["bootout", "system/" + LocalInstallation.daemonLabel])
                guard !LocalInstallation.hasRecoveryEvidence else { throw LocalInstallError.recoveryRequired }
                if FileManager.default.fileExists(atPath: LocalInstallation.daemonPlist.path) {
                    try LocalInstallation.protected(LocalInstallation.daemonPlist)
                    guard try Data(contentsOf: LocalInstallation.daemonPlist) == LocalInstallation.daemonData() else { throw LocalInstallError.altered }
                    try FileManager.default.removeItem(at: LocalInstallation.daemonPlist)
                }
                // Remove this app only when it still matches the approved local
                // build; a subsequently installed signed app is never deleted.
                if (try? LocalInstallation.binary(LocalInstallation.executable(.app), role: .app)) == approval.binaries[LocalRole.app.rawValue] {
                    try LocalInstallation.protected(LocalInstallation.app, directory: true)
                    try FileManager.default.removeItem(at: LocalInstallation.app)
                }
                try FileManager.default.removeItem(at: LocalInstallation.root)
                print("Local system service and payload removed. User profiles are preserved.")
            } else if args == ["health"] {
                let result = await request { $0.health(reply: $1) }
                guard result.hasPrefix("VPN Navigator Helper") else { throw LocalInstallError.command }
                print(result)
            } else { throw LocalInstallError.rootRequired }
            exit(0)
        } catch { fputs("Local setup: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func makeTemplate(app: URL, payload: URL, version: String) throws {
        var binaries: [String: LocalBinary] = [:]
        for role in LocalRole.allCases {
            let path = role == .app ? app.appendingPathComponent("Contents/MacOS/\(role.file)") : payload.appendingPathComponent(role.file)
            binaries[role.rawValue] = try LocalInstallation.binary(path, role: role)
        }
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        let approval = LocalApproval(version: version, architecture: arch, ownerUID: 501, binaries: binaries,
                                     dnsSHA256: try LocalInstallation.hash(payload.appendingPathComponent("macos-dns-updown.sh")),
                                     uninstallerSHA256: try LocalInstallation.hash(payload.appendingPathComponent("VPNNavigator-Uninstall.pkg")))
        try approval.validate()
        try JSONEncoder().encode(approval).write(to: payload.appendingPathComponent("approval-template.json"), options: .atomic)
    }
    static func install(uid: UInt32) throws {
        guard !LocalInstallation.hasRecoveryEvidence else { throw LocalInstallError.recoveryRequired }
        try LocalInstallation.protectedRoot()
        var approval = try LocalInstallation.decode(LocalInstallation.template)
        guard approval.architecture == LocalInstallation.nativeArchitecture else { throw LocalInstallError.invalid }
        approval.ownerUID = uid
        for role in LocalRole.allCases {
            let path = LocalInstallation.executable(role); try LocalInstallation.protected(path)
            guard try LocalInstallation.binary(path, role: role) == approval.binaries[role.rawValue] else { throw LocalInstallError.altered }
        }
        let dns = LocalInstallation.payload.appendingPathComponent("macos-dns-updown.sh"); try LocalInstallation.protected(dns)
        try LocalInstallation.protected(LocalInstallation.uninstaller)
        guard try LocalInstallation.hash(dns) == approval.dnsSHA256, try LocalInstallation.hash(LocalInstallation.uninstaller) == approval.uninstallerSHA256 else { throw LocalInstallError.altered }
        // A signed SMAppService deployment cannot be silently replaced.
        if (try? run(["print", "system/" + HelperIdentity.machService])) != nil { throw LocalInstallError.unsafe }
        _ = try? run(["bootout", "system/" + LocalInstallation.daemonLabel])
        try JSONEncoder().encode(approval).write(to: LocalInstallation.manifest, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: LocalInstallation.manifest.path)
        try LocalInstallation.daemonData().write(to: LocalInstallation.daemonPlist, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: LocalInstallation.daemonPlist.path)
        if FileManager.default.fileExists(atPath: LocalInstallation.retired.path) { try LocalInstallation.protected(LocalInstallation.retired); try FileManager.default.removeItem(at: LocalInstallation.retired) }
        _ = try run(["enable", "system/" + LocalInstallation.daemonLabel])
        _ = try run(["bootstrap", "system", LocalInstallation.daemonPlist.path])
    }
    @discardableResult static func run(_ args: [String]) throws -> String {
        let task = Process(), pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl"); task.arguments = args
        task.standardOutput = pipe; task.standardError = pipe
        try task.run()
        let timer = DispatchSource.makeTimerSource(queue: .global()); timer.schedule(deadline: .now() + 8)
        timer.setEventHandler { if task.isRunning { task.terminate() } }; timer.resume()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit(); timer.cancel()
        guard task.terminationStatus == 0 else { throw LocalInstallError.command }
        return String(decoding: data, as: UTF8.self)
    }
    static func request(_ invoke: @escaping (VPNNavigatorHelperAPI, @escaping (String) -> Void) -> Void) async -> String {
        await withCheckedContinuation { continuation in
            let connection = NSXPCConnection(machServiceName: HelperIdentity.machService, options: .privileged)
            let once = Reply { value in connection.invalidate(); continuation.resume(returning: value) }
            guard let requirement = PrivilegedServiceTrust.helperRequirement() else { once.finish("ERROR: identity"); return }
            connection.setCodeSigningRequirement(requirement)
            connection.remoteObjectInterface = NSXPCInterface(with: VPNNavigatorHelperAPI.self)
            connection.invalidationHandler = { once.finish("ERROR: unavailable") }
            connection.interruptionHandler = { once.finish("ERROR: interrupted") }
            connection.resume()
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { once.finish("ERROR: timeout") }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in once.finish("ERROR: rejected") }) as? VPNNavigatorHelperAPI else {
                once.finish("ERROR: proxy"); return
            }
            invoke(proxy) { once.finish($0) }
        }
    }
}
private final class Reply: @unchecked Sendable {
    let lock = NSLock(); var done = false; let block: (String) -> Void
    init(_ block: @escaping (String) -> Void) { self.block = block }
    func finish(_ value: String) { lock.lock(); let first = !done; done = true; lock.unlock(); if first { block(value) } }
}
