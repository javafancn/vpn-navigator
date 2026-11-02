import Foundation
import Darwin
import VPNNavigatorCore

@main struct ProfileSafetyRegression {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }
    static func rules() throws {
        let base = "client\ndev tun\nremote fixture.example\n<ca>\nTEST_CA\n</ca>\n"
        for option in ["remote-cert-tls server", "remote-cert-tls\tserver # role", "\"remote-cert-tls\" \"server\"", "verify-x509-name expected name", "verify-x509-name 'CN=expected' subject", "verify-x509-name 'CN=expected'"] {
            let source = base + option + "\n"
            require(try! ProfileSafety.validateForConnection(source).text == source, "Valid identity constraint changed")
        }
        for suffix in ["", "# remote-cert-tls server", "; verify-x509-name expected name", "<cert>\nremote-cert-tls server\n</cert>", "verify-x509-name expected name-prefix", "verify-x509-name expected name\nverify-x509-name broad name-prefix"] {
            do { _ = try ProfileSafety.validateForConnection(base + suffix); fatalError("Missing identity was accepted") }
            catch ServerIdentityError.missing {}
        }
        for suffix in ["remote-cert-tls client", "remote-cert-tls server\nremote-cert-tls client", "remote-cert-tls client\nremote-cert-tls server"] {
            do { _ = try ProfileSafety.validateForConnection(base + suffix); fatalError("Client role was accepted") }
            catch ServerIdentityError.wrongRole {}
        }
        for suffix in ["remote-cert-tls server extra", "verify-x509-name ''", "verify-x509-name expected invalid"] {
            do { _ = try ProfileSafety.validateForConnection(base + suffix); fatalError("Invalid identity option accepted") }
            catch ServerIdentityError.invalid {}
        }
        _ = try ProfileSafety.validate(base)
        require(ProfileHealth.inspect(runtime: base).issues.contains { $0.id == "server-identity" && $0.severity == .error }, "Missing health error")
        let legacy = HealthCertificateFixture.config.replacingOccurrences(of: "remote-cert-tls server\n", with: "")
        let now = HealthCertificateFixture.start.addingTimeInterval(100 * 86_400)
        let report = ProfileHealth.inspect(runtime: legacy, now: now)
        require(report.certificates.count == 1 && report.issues.map(\.id) == ["server-identity"], "Valid CA hid missing identity constraint")
        require(ProfileHealth.inspect(runtime: HealthCertificateFixture.config, now: now).issues.isEmpty, "Constrained valid fixture should be healthy")
        print("PASS identity: server role/exact names, whitespace, inline/comments, wrong roles, repeated options, prefixes, malformed options, legacy repair")
    }
    static func main() async throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--hold-lock" {
            let lock = URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("profiles.lock")
            let fd = open(lock.path, O_RDWR | O_CLOEXEC)
            require(fd >= 0 && flock(fd, LOCK_EX) == 0, "Child lock unavailable")
            print("LOCKED"); fflush(stdout)
            var byte: UInt8 = 0
            _ = Darwin.read(STDIN_FILENO, &byte, 1)
            // Skip Swift cleanup deliberately: process exit itself must
            // release the kernel lock, including after an interrupted owner.
            _exit(0)
        }
        if CommandLine.arguments.count == 5, CommandLine.arguments[1] == "--writer", let count = Int(CommandLine.arguments[4]) {
            let store = ProfileStore(root: URL(fileURLWithPath: CommandLine.arguments[2]))
            for _ in 0..<count { _ = try await store.importProfile(from: URL(fileURLWithPath: CommandLine.arguments[3])) }
            print("writer committed \(count)"); return
        }
        try rules()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vpnnav-profile-regression-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("fixture.ovpn"), root = folder.appendingPathComponent("Profiles")
        let source = "client\ndev tun\nremote fixture.example\nremote-cert-tls server\n<ca>\nTEST_CA\n</ca>\n"
        try source.write(to: input, atomically: true, encoding: .utf8)
        let first = ProfileStore(root: root), second = ProfileStore(root: root)
        let profile = try await first.importProfile(from: input)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<40 {
                let store = i % 2 == 0 ? first : second
                group.addTask { _ = try await store.importProfile(from: input) }
            }
            try await group.waitForAll()
        }
        let afterActors = try await first.list()
        require(afterActors.count == 41, "Successful imports lost across actor instances")
        print("PASS actors: 41 successful imports, 41 indexed profiles")

        var children: [(Process, Pipe)] = []
        for _ in 0..<4 {
            let task = Process(), output = Pipe()
            task.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            task.arguments = ["--writer", root.path, input.path, "10"]
            task.standardInput = FileHandle.nullDevice; task.standardOutput = output; task.standardError = output
            try task.run(); children.append((task, output))
        }
        for (task, output) in children {
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            task.waitUntilExit(); require(task.terminationStatus == 0, "Child writer failed: " + text)
        }
        let afterProcesses = try await second.list(), backup = try await first.indexBackupInfo()
        require(afterProcesses.count == 81 && Set(afterProcesses.map(\.id)).count == 81, "Cross-process imports lost")
        require(backup.matchesCurrentIndex && backup.profileCount == 81, "Index checkpoint diverged")
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        require(files.filter { $0.pathExtension == "ovpn" && !$0.lastPathComponent.contains(".runtime.") }.count == 81, "Source/index count differs")
        print("PASS processes: 4 concurrent writers; 81 successful imports, 81 indexed profiles and matching checkpoint")

        try await first.revise(profile, text: source + "# revision\n")
        let snapshot = try await second.backupSnapshot(profileIDs: [profile.id])
        require(snapshot.revisionCount == 1, "Revision transaction was interrupted")
        let current = try await first.list(), restored = try await second.restoreBackup(snapshot, expecting: current)
        require(restored.count == 1, "Nested restore failed")
        let restoredCount = try await first.list().count
        require(restoredCount == 82, "Restore lost existing profiles")
        print("PASS transactions: revisions, snapshots and nested restore preserve all existing profiles")

        do {
            let fd = open(root.appendingPathComponent("profiles.lock").path, O_RDWR | O_CLOEXEC)
            require(fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0, "Fixture lock unavailable")
            defer { flock(fd, LOCK_UN); close(fd) }
            let pending = Task { try await second.list() }
            try await Task.sleep(nanoseconds: 30_000_000); pending.cancel()
            do { _ = try await pending.value; fatalError("Lock wait ignored cancellation") } catch is CancellationError {}
        }
        let afterCancellation = try await first.list().count
        require(afterCancellation == 82, "Cancellation damaged library")
        print("PASS cancellation: waiting for a foreign lock cancels promptly and preserves data")

        let owner = Process(), ownerOutput = Pipe(), ownerInput = Pipe()
        owner.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]); owner.arguments = ["--hold-lock", root.path]
        owner.standardInput = ownerInput; owner.standardOutput = ownerOutput; owner.standardError = ownerOutput
        try owner.run()
        let ready = String(decoding: ownerOutput.fileHandleForReading.availableData, as: UTF8.self)
        require(ready.contains("LOCKED"), "Child lock readiness failed: " + ready)
        let waiting = Task { try await second.list() }
        try await Task.sleep(nanoseconds: 30_000_000)
        try ownerInput.fileHandleForWriting.write(contentsOf: Data([1]))
        owner.waitUntilExit(); require(owner.terminationStatus == 0, "Child owner failed")
        let released = try await waiting.value
        require(released.count == 82, "Exited owner did not release transaction lock")
        print("PASS owner exit: pending reader proceeds after process exit without explicit lock cleanup")

        let unsafe = folder.appendingPathComponent("Unsafe")
        try FileManager.default.createDirectory(at: unsafe, withIntermediateDirectories: true)
        let unrelated = folder.appendingPathComponent("unrelated"), lock = unsafe.appendingPathComponent("profiles.lock")
        try Data().write(to: unrelated)
        try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: unrelated)
        do { _ = try await ProfileStore(root: unsafe).list(); fatalError("Symlink lock accepted") } catch ProfileStoreLockError.unsafe {}
        try FileManager.default.removeItem(at: lock)
        try FileManager.default.linkItem(at: unrelated, to: lock)
        do { _ = try await ProfileStore(root: unsafe).list(); fatalError("Hardlinked lock accepted") } catch ProfileStoreLockError.unsafe {}
        require(try! Data(contentsOf: unrelated).isEmpty, "Unrelated file changed")
        print("PASS lock integrity: symlinks and hardlinks refused without changing unrelated files")
    }
}
