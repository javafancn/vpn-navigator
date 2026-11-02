import XCTest
import Darwin
@testable import VPNNavigatorCore

final class ProfileStoreConcurrencyTests: XCTestCase {
    private func fixture() throws -> (URL, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("profile-lock-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("fixture.ovpn")
        try "client\ndev tun\nremote fixture.example\nremote-cert-tls server\n<ca>\nTEST_CA\n</ca>\n".write(to: source, atomically: true, encoding: .utf8)
        return (folder.appendingPathComponent("Profiles"), source)
    }
    func testIndependentActorsCannotLoseSuccessfulImports() async throws {
        let (root, source) = try fixture()
        let a = ProfileStore(root: root), b = ProfileStore(root: root)
        _ = try await a.importProfile(from: source)
        var imported = Set<UUID>()
        try await withThrowingTaskGroup(of: UUID.self) { group in
            for i in 0..<40 { let store = i % 2 == 0 ? a : b; group.addTask { try await store.importProfile(from: source).id } }
            for try await id in group { imported.insert(id) }
        }
        let profiles = try await b.list()
        XCTAssertEqual(imported.count, 40); XCTAssertEqual(profiles.count, 41)
        XCTAssertTrue(imported.isSubset(of: Set(profiles.map(\.id))))
        let checkpoint = try await a.indexBackupInfo()
        XCTAssertTrue(checkpoint.matchesCurrentIndex); XCTAssertEqual(checkpoint.profileCount, 41)
    }
    func testSnapshotRevisionAndRestoreCanNestWithoutDeadlock() async throws {
        let (root, source) = try fixture(), store = ProfileStore(root: root)
        let profile = try await store.importProfile(from: source)
        let text = try await store.runtimeConfig(for: profile)
        try await store.revise(profile, text: text + "# revised\n")
        let snapshot = try await store.backupSnapshot()
        XCTAssertEqual(snapshot.revisionCount, 1)
        let current = try await store.list()
        let added = try await store.restoreBackup(snapshot, expecting: current)
        XCTAssertEqual(added.count, 1)
        let profiles = try await store.list(); XCTAssertEqual(profiles.count, 2)
    }
    func testWaitingForAnotherOwnerCanBeCancelled() async throws {
        let (root, _) = try fixture()
        let owner = try ProfileStoreTransactionLock(root: root)
        defer { withExtendedLifetime(owner) {} }
        let store = ProfileStore(root: root)
        let pending = Task { try await store.list() }
        try await Task.sleep(nanoseconds: 30_000_000); pending.cancel()
        do { _ = try await pending.value; XCTFail("Cancellation ignored") } catch is CancellationError {}
    }
    func testReadCannotRollBackAnotherInstancesLiveUpdate() async throws {
        let (root, source) = try fixture()
        let owner = ProfileStore(root: root), observer = ProfileStore(root: root)
        let profile = try await owner.importProfile(from: source)
        let updated = try String(contentsOf: source, encoding: .utf8) + "# new version\n"
        try updated.write(to: source, atomically: true, encoding: .utf8)
        let preview = try await owner.previewUpdate(id: profile.id, from: source)
        let started = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        defer { resume.signal() }
        let applying = Task {
            try await owner.applyUpdate(preview, checkpoint: { phase in
                if phase == 1 { started.signal(); _ = resume.wait(timeout: .now() + 3) }
            })
        }
        let began = await Task.detached { started.wait(timeout: .now() + 3) }.value
        XCTAssertEqual(began, .success)
        let reading = Task { try await observer.list() }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("profile-update.json").path), "Reader rolled back a live transaction")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(profile.relativePath), encoding: .utf8), updated)
        resume.signal()
        _ = try await applying.value; _ = try await reading.value
        let original = try await observer.original(for: profile), runtime = try await observer.runtimeConfig(for: profile)
        XCTAssertEqual(original, updated); XCTAssertEqual(runtime, updated)
    }
    func testSymlinkAndHardlinkedLocksAreRefusedWithoutTouchingTarget() async throws {
        let (root, _) = try fixture()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.deletingLastPathComponent().appendingPathComponent("unrelated")
        try Data().write(to: target)
        let lock = root.appendingPathComponent(ProfileStoreTransactionLock.filename)
        try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: target)
        do { _ = try await ProfileStore(root: root).list(); XCTFail() } catch ProfileStoreLockError.unsafe {}
        try FileManager.default.removeItem(at: lock)
        try FileManager.default.linkItem(at: target, to: lock)
        do { _ = try await ProfileStore(root: root).list(); XCTFail() } catch ProfileStoreLockError.unsafe {}
        XCTAssertEqual(try Data(contentsOf: target), Data())
    }
}
