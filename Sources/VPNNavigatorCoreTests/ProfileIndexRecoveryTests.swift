import XCTest
import Darwin
@testable import VPNNavigatorCore

final class ProfileIndexRecoveryTests: XCTestCase {
    private func fixture() throws -> (URL, URL, ProfileStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("index-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("work.ovpn")
        try "client\ndev tun\nremote fixture.example 1194\n<ca>\nFAKE CA\n</ca>\n".write(to: source, atomically: true, encoding: .utf8)
        let folder = root.appendingPathComponent("profiles")
        return (folder, source, ProfileStore(root: folder))
    }
    private func corrupt(_ folder: URL, text: String = "{damaged") throws {
        try Data(text.utf8).write(to: folder.appendingPathComponent("profiles.json"))
    }
    private func reject(_ action: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await action(); XCTFail("Unexpected success", file: file, line: line) } catch {}
    }
    func testRecoveryPreservesMetadataSourceHistoryAndDamagedBytes() async throws {
        let (folder, source, store) = try fixture()
        var profile = try await store.importProfile(from: source)
        profile.name = "工作网络"; profile.group = "公司"; profile.notes = "内部备注"; profile.isFavorite = true; profile.mode = .chinaDirect
        try await store.update(profile)
        let old = try await store.original(for: profile)
        let updated = old.replacingOccurrences(of: "fixture.example", with: "new.example")
        var expected = profile
        try await store.revise(profile, text: updated)
        let revised = try await store.list()
        profile = try XCTUnwrap(revised.first)
        XCTAssertNotEqual(profile.credentialID, expected.credentialID)
        expected.credentialID = profile.credentialID
        XCTAssertEqual(profile, expected)
        let info = try await store.indexBackupInfo()
        XCTAssertTrue(info.matchesCurrentIndex); XCTAssertEqual(info.profileCount, 1)
        try corrupt(folder)
        await reject { _ = try await store.list() }
        let preview = try await store.indexRecoveryPreview()
        XCTAssertEqual(preview.profiles, [profile])
        try await store.recoverIndex(preview)
        let restored = try await store.list()
        let runtime = try await store.runtimeConfig(for: profile)
        let revisions = try await store.revisions(for: profile)
        XCTAssertEqual(restored, [profile]); XCTAssertEqual(runtime, updated); XCTAssertEqual(revisions.count, 1)
        let archived = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("profiles-damaged-") }
        XCTAssertEqual(archived.count, 1)
        XCTAssertEqual(try String(contentsOf: archived[0], encoding: .utf8), "{damaged")
        for file in archived + [folder.appendingPathComponent("profiles.json"), folder.appendingPathComponent("profiles.backup.json")] {
            let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode?.intValue, 0o600)
        }
        let backup = try String(contentsOf: folder.appendingPathComponent("profiles.backup.json"), encoding: .utf8)
        XCTAssertFalse(backup.contains("FAKE CA"))
    }
    func testMissingIndexRequiresExplicitRecoveryAndBlocksImport() async throws {
        let (folder, source, store) = try fixture()
        let profile = try await store.importProfile(from: source)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("profiles.json"))
        await reject { _ = try await store.list() }
        await reject { _ = try await store.importProfile(from: source) }
        let preview = try await store.indexRecoveryPreview()
        try await store.recoverIndex(preview)
        let profiles = try await store.list()
        XCTAssertEqual(profiles, [profile])
    }
    func testChangedDamageInvalidatesConfirmation() async throws {
        let (folder, source, store) = try fixture()
        _ = try await store.importProfile(from: source); try corrupt(folder)
        let preview = try await store.indexRecoveryPreview()
        try corrupt(folder, text: "different damage")
        await reject { try await store.recoverIndex(preview) }
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("profiles.json"), encoding: .utf8), "different damage")
    }
    func testChangedBackupInvalidatesConfirmation() async throws {
        let (folder, source, store) = try fixture()
        _ = try await store.importProfile(from: source); try corrupt(folder)
        let preview = try await store.indexRecoveryPreview()
        let backup = folder.appendingPathComponent("profiles.backup.json")
        var bytes = try Data(contentsOf: backup); bytes.append(0x20); try bytes.write(to: backup)
        await reject { try await store.recoverIndex(preview) }
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("profiles.json"), encoding: .utf8), "{damaged")
    }
    func testHealthyIndexCannotBeRolledBack() async throws {
        let (_, source, store) = try fixture()
        _ = try await store.importProfile(from: source)
        await reject { _ = try await store.indexRecoveryPreview() }
    }
    func testRejectDuplicateAndTraversalIndexAndBackup() async throws {
        let (folder, source, store) = try fixture()
        let profile = try await store.importProfile(from: source)
        let validBackup = try Data(contentsOf: folder.appendingPathComponent("profiles.backup.json"))
        for entries in [[profile, profile], [VPNProfile(id: profile.id, name: "bad", sourceFilename: "x.ovpn", relativePath: "../x.ovpn")]] {
            let bytes = try JSONEncoder().encode(entries)
            try bytes.write(to: folder.appendingPathComponent("profiles.json"))
            await reject { _ = try await store.list() }
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: validBackup) as? [String: Any])
            object["profiles"] = try JSONSerialization.jsonObject(with: bytes)
            try JSONSerialization.data(withJSONObject: object).write(to: folder.appendingPathComponent("profiles.backup.json"))
            await reject { _ = try await store.indexRecoveryPreview() }
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("profiles.json")), bytes)
        }
    }
    func testMissingOrUnsafeConfigurationRefusesWholeRecovery() async throws {
        let (folder, source, store) = try fixture()
        let profile = try await store.importProfile(from: source); try corrupt(folder)
        let canonical = folder.appendingPathComponent(profile.relativePath)
        try FileManager.default.removeItem(at: canonical)
        await reject { _ = try await store.indexRecoveryPreview() }
        try FileManager.default.createSymbolicLink(at: canonical, withDestinationURL: source)
        await reject { _ = try await store.indexRecoveryPreview() }
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("profiles.json"), encoding: .utf8), "{damaged")
    }
    func testUnsafeRuntimeRefusesRecovery() async throws {
        let (folder, source, store) = try fixture()
        let profile = try await store.importProfile(from: source); try corrupt(folder)
        let runtime = folder.appendingPathComponent("\(profile.id.uuidString).runtime.ovpn")
        try FileManager.default.removeItem(at: runtime)
        XCTAssertEqual(mkfifo(runtime.path, mode_t(0o600)), 0)
        await reject { _ = try await store.indexRecoveryPreview() }
    }
    func testIndexAndBackupRejectSymlinksFIFOAndOversize() async throws {
        let (folder, source, store) = try fixture()
        _ = try await store.importProfile(from: source)
        for name in ["profiles.json", "profiles.backup.json"] {
            let target = folder.appendingPathComponent(name)
            let saved = try Data(contentsOf: target)
            try FileManager.default.removeItem(at: target)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: source)
            if name == "profiles.json" { await reject { _ = try await store.list() } }
            else { await reject { _ = try await store.indexBackupInfo() } }
            try FileManager.default.removeItem(at: target)
            XCTAssertEqual(mkfifo(target.path, mode_t(0o600)), 0)
            if name == "profiles.json" { await reject { _ = try await store.list() } }
            else { await reject { _ = try await store.indexBackupInfo() } }
            try FileManager.default.removeItem(at: target)
            try Data(repeating: 0x20, count: 16_000_001).write(to: target)
            if name == "profiles.json" { await reject { _ = try await store.list() } }
            else { await reject { _ = try await store.indexBackupInfo() } }
            try saved.write(to: target)
        }
    }
    func testCheckpointFailureDoesNotRollBackCommittedImport() async throws {
        let (folder, source, store) = try fixture()
        let first = try await store.importProfile(from: source)
        let backup = folder.appendingPathComponent("profiles.backup.json")
        try FileManager.default.removeItem(at: backup)
        try FileManager.default.createSymbolicLink(at: backup, withDestinationURL: source)
        let original = try Data(contentsOf: source)
        let profile = try await store.importProfile(from: source)
        let profiles = try await store.list(), runtime = try await store.runtimeConfig(for: profile)
        XCTAssertEqual(profiles, [first, profile]); XCTAssertFalse(runtime.isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), original)
        await reject { _ = try await store.indexBackupInfo() }
    }
    func testLegacyIndexIsCheckpointedAndDeletedEntriesStayDeleted() async throws {
        let (folder, source, store) = try fixture()
        let profile = try await store.importProfile(from: source)
        let backup = folder.appendingPathComponent("profiles.backup.json")
        try FileManager.default.removeItem(at: backup)
        _ = try await store.list()
        let info = try await store.indexBackupInfo(); XCTAssertTrue(info.matchesCurrentIndex)
        try await store.delete(id: profile.id); try corrupt(folder)
        let preview = try await store.indexRecoveryPreview(); XCTAssertTrue(preview.profiles.isEmpty)
        try await store.recoverIndex(preview)
        let profiles = try await store.list(); XCTAssertTrue(profiles.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(profile.relativePath).path))
    }
    func testCorruptAndUnknownVersionBackupsPreserveDamage() async throws {
        let (folder, source, store) = try fixture()
        _ = try await store.importProfile(from: source); try corrupt(folder)
        let backup = folder.appendingPathComponent("profiles.backup.json")
        let valid = try Data(contentsOf: backup)
        for replacement in [Data("bad".utf8), Data(String(decoding: valid, as: UTF8.self).replacingOccurrences(of: "\"schemaVersion\" : 1", with: "\"schemaVersion\" : 2").utf8)] {
            try replacement.write(to: backup)
            await reject { _ = try await store.indexRecoveryPreview() }
            XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("profiles.json"), encoding: .utf8), "{damaged")
        }
    }
    func testRebuildCheckpointRequiresHealthyPrimary() async throws {
        let (folder, source, store) = try fixture()
        let profile = try await store.importProfile(from: source)
        let backup = folder.appendingPathComponent("profiles.backup.json")
        try Data("bad backup".utf8).write(to: backup)
        try await store.refreshIndexBackup()
        let info = try await store.indexBackupInfo(); XCTAssertTrue(info.matchesCurrentIndex)
        let saved = try Data(contentsOf: backup)
        try corrupt(folder)
        await reject { try await store.refreshIndexBackup() }
        XCTAssertEqual(try Data(contentsOf: backup), saved)
        let preview = try await store.indexRecoveryPreview(); XCTAssertEqual(preview.profiles, [profile])
    }
    func testOlderCheckpointIsReportedAndCannotRestoreMissingDeletedFile() async throws {
        let (folder, source, store) = try fixture()
        let profile = try await store.importProfile(from: source)
        let backup = folder.appendingPathComponent("profiles.backup.json")
        let old = try Data(contentsOf: backup)
        try await store.delete(id: profile.id)
        try old.write(to: backup)
        let info = try await store.indexBackupInfo(); XCTAssertFalse(info.matchesCurrentIndex)
        try corrupt(folder)
        await reject { _ = try await store.indexRecoveryPreview() }
        XCTAssertEqual(try Data(contentsOf: backup), old)
    }

    func testExplicitBackupOfNewEmptyRepositoryAndMissingPrimaryFence() async throws {
        let (folder, _, store) = try fixture()
        try await store.refreshIndexBackup()
        let info = try await store.indexBackupInfo()
        XCTAssertEqual(info.profileCount, 0); XCTAssertTrue(info.matchesCurrentIndex)
        let saved = try Data(contentsOf: folder.appendingPathComponent("profiles.backup.json"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("profiles.json"))
        await reject { try await store.refreshIndexBackup() }
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("profiles.backup.json")), saved)
        let preview = try await store.indexRecoveryPreview(); XCTAssertTrue(preview.profiles.isEmpty)
    }

}
