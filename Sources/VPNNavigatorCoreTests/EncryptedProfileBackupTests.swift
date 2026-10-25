import XCTest
import Darwin
@testable import VPNNavigatorCore

final class EncryptedProfileBackupTests: XCTestCase {
    private let configuration = "client\ndev tun\nremote fixture.example 1194\n<ca>\nFAKE_CA\n</ca>\n<key>\nFAKE_PRIVATE_MATERIAL\n</key>\nauth-user-pass\n"
    private let password = "test-correct-horse-key"
    private func payload() -> ProfileBackupSnapshot {
        let id = UUID()
        let profile = VPNProfile(id: id, name: "Private fixture", sourceFilename: "fixture.ovpn", relativePath: id.uuidString + ".ovpn",
            mode: .fullVPN, group: "工作", notes: "private notes", isFavorite: true, customRules: [.init(cidr: "9.9.9.9", action: .direct), .init(cidr: "fd12::/16", action: .vpn)])
        return .init(createdAt: Date(timeIntervalSince1970: 1000), entries: [.init(profile: profile, source: configuration, runtime: configuration,
            revisions: [.init(id: UUID(), createdAt: Date(timeIntervalSince1970: 900), runtime: configuration, source: configuration)])])
    }
    private func folder() throws -> URL {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent("backup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); return result
    }
    func testIndependentPythonPBKDF2AndGCMVector() throws {
        // Produced with hashlib.pbkdf2_hmac('sha256', ..., 600000, 32)
        // and cryptography.AESGCM; salt 00..0f, nonce 00..0b.
        let archive = Data(base64Encoded: "VlBOTkFWQksBAAknwAABAgMEBQYHCAkKCwwNDg8AAQIDBAUGBwgJCgvlLLKb205ZykZ191dagklaB3138zf5234SRZ2Qz9PhBeaj10eHfwZaGI6WM/YxlLKbEgkMxIDW0ZRY/4hs0A==")!
        let result = try EncryptedProfileBackup.open(archive, password: password)
        XCTAssertEqual(result.entries.count, 0); XCTAssertEqual(result.createdAt, Date(timeIntervalSinceReferenceDate: 0))
    }
    func testRoundTripRandomizationAndNoPlaintextMetadataOrKey() throws {
        let value = payload(), first = try EncryptedProfileBackup.seal(value, password: password), second = try EncryptedProfileBackup.seal(value, password: password)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try EncryptedProfileBackup.open(first, password: password), value)
        for secret in ["Private fixture", "FAKE_PRIVATE_MATERIAL", "private notes", password] { XCTAssertNil(first.range(of: Data(secret.utf8))) }
    }
    func testWrongPasswordAndAuthenticatedHeaderNonceCiphertextTagTampering() throws {
        let archive = try EncryptedProfileBackup.seal(payload(), password: password)
        XCTAssertThrowsError(try EncryptedProfileBackup.open(archive, password: "a different password"))
        for offset in [13, 29, 42, archive.count - 1] {
            var changed = archive; changed[offset] ^= 1
            XCTAssertThrowsError(try EncryptedProfileBackup.open(changed, password: password))
        }
    }
    func testUnicodePasswordAndLengthPolicy() throws {
        let value = payload(), secret = "备份迁移🔐-independent-password"
        XCTAssertEqual(try EncryptedProfileBackup.open(EncryptedProfileBackup.seal(value, password: secret), password: secret), value)
        let decomposed = "independent-Cafe\u{301}-备份-key", composed = decomposed.precomposedStringWithCanonicalMapping
        let normalized = try EncryptedProfileBackup.seal(value, password: decomposed)
        XCTAssertEqual(try EncryptedProfileBackup.open(normalized, password: composed), value)
        for invalid in ["", "short", String(repeating: "a", count: 1025)] { XCTAssertThrowsError(try EncryptedProfileBackup.seal(value, password: invalid)) }
    }
    func testUnknownVersionKDFTruncationAndOversizeFailBeforeWork() throws {
        let archive = try EncryptedProfileBackup.seal(payload(), password: password)
        for offset in [0, 8, 9, 12] { var changed = archive; changed[offset] ^= 1; XCTAssertThrowsError(try EncryptedProfileBackup.open(changed, password: password)) }
        for count in [0, 8, 29, 56] { XCTAssertThrowsError(try EncryptedProfileBackup.open(Data(archive.prefix(count)), password: password)) }
        XCTAssertThrowsError(try EncryptedProfileBackup.open(Data(count: EncryptedProfileBackup.maximumBytes + 1), password: password))
    }
    func testUnsafeRuntimeAndArchivePathsRejectedBeforeRestore() async throws {
        let value = payload(), old = value.entries[0]
        let invalidRuntime = ProfileBackupSnapshot(entries: [.init(profile: old.profile, source: old.source, runtime: "client\ndev tun\nremote fixture.example\nca /etc/passwd\n")])
        XCTAssertThrowsError(try invalidRuntime.validate())
        var profile = old.profile; profile.relativePath = "../../escape.ovpn"
        let invalidPath = ProfileBackupSnapshot(entries: [.init(profile: profile, source: old.source, runtime: old.runtime)])
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(root: root)
        do { _ = try await store.restoreBackup(invalidPath, expecting: []); XCTFail() } catch { }
        let listed = try await store.list(); XCTAssertTrue(listed.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("backup-restore.json").path))
    }
    func testLimitsDuplicateIDsAndInvalidDates() throws {
        let value = payload(), entry = value.entries[0]
        XCTAssertThrowsError(try ProfileBackupSnapshot(entries: [entry, entry]).validate())
        XCTAssertThrowsError(try ProfileBackupSnapshot(entries: Array(repeating: entry, count: 1001)).validate())
        let revisions = [entry.revisions[0], entry.revisions[0]]
        XCTAssertThrowsError(try ProfileBackupSnapshot(entries: [.init(profile: entry.profile, source: entry.source, runtime: entry.runtime, revisions: revisions)]).validate())
        XCTAssertThrowsError(try ProfileBackupSnapshot(createdAt: Date(timeIntervalSince1970: .infinity), entries: []).validate())
    }
    func testRestorePreservesMetadataHistoryAndUsesNewIDsWithoutOverwriting() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fixture.ovpn"); try configuration.write(to: file, atomically: true, encoding: .utf8)
        let store = ProfileStore(root: root.appendingPathComponent("store")), original = try await store.importProfile(from: file)
        let snapshot = payload()
        let first = try await store.restoreBackup(snapshot, expecting: [original])
        XCTAssertEqual(first.count, 1); XCTAssertNotEqual(first[0].id, snapshot.entries[0].profile.id)
        XCTAssertEqual(first[0].customRules, snapshot.entries[0].profile.customRules); XCTAssertTrue(first[0].isFavorite)
        XCTAssertEqual(first[0].group, "工作"); XCTAssertEqual(first[0].notes, "private notes"); XCTAssertEqual(first[0].mode, .fullVPN)
        let text = try await store.original(for: original); XCTAssertEqual(text, configuration)
        let versions = try await store.revisions(for: first[0]); XCTAssertEqual(versions.count, 1)
        XCTAssertEqual(versions[0].createdAt.timeIntervalSince1970, 900, accuracy: 0.01)
        let current = try await store.list(); let second = try await store.restoreBackup(snapshot, expecting: current)
        XCTAssertNotEqual(second[0].id, first[0].id)
        let all = try await store.list(); XCTAssertEqual(all.count, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("store/backup-restore.json").path))
        let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("store/" + first[0].relativePath).path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testExternalMaterialAndOriginalBytesSurviveMigrationAndHistoryRestore() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("input"); try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try "FAKE_CA".write(to: input.appendingPathComponent("ca.pem"), atomically: true, encoding: .utf8)
        let original = "client\ndev tun\nremote fixture.example\nca ca.pem\nauth-user-pass account.txt\n"
        let file = input.appendingPathComponent("source.ovpn"); try original.write(to: file, atomically: true, encoding: .utf8)
        let store = ProfileStore(root: root.appendingPathComponent("source")); var profile = try await store.importProfile(from: file)
        profile.group = "公司"; try await store.update(profile)
        try await store.revise(profile, text: configuration)
        try FileManager.default.removeItem(at: input)
        let snapshot = try await store.backupSnapshot()
        XCTAssertEqual(snapshot.entries[0].revisions[0].source, original)
        let other = ProfileStore(root: root.appendingPathComponent("other")), restored = try await other.restoreBackup(snapshot, expecting: [])
        let source = try await other.original(for: restored[0]); XCTAssertEqual(source, configuration)
        let history = try await other.revisions(for: restored[0])
        try await other.restore(restored[0], revision: history[0].filename)
        let runtime = try await other.runtimeConfig(for: restored[0]); XCTAssertTrue(runtime.contains("FAKE_CA")); XCTAssertFalse(runtime.contains("account.txt"))
    }
    func testStaleConfirmationRejectsWithoutCreatingFiles() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(root: root.appendingPathComponent("store")), file = root.appendingPathComponent("new.ovpn")
        try configuration.write(to: file, atomically: true, encoding: .utf8); let existing = try await store.importProfile(from: file)
        do { _ = try await store.restoreBackup(payload(), expecting: []); XCTFail() } catch { }
        let profiles = try await store.list(); XCTAssertEqual(profiles, [existing])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("store/backup-restore.json").path))
    }
    func testCancelledRestoreHasNoPublication() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(root: root), value = payload()
        let operation = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await store.restoreBackup(value, expecting: []) }
        let result = await operation.result
        if case .success = result { XCTFail() }
        let profiles = try await store.list(); XCTAssertTrue(profiles.isEmpty)
    }
    func testCancelledAtomicPublicationPreservesExistingDestination() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("existing.vpnnavbackup"), original = Data("original fixture".utf8)
        try ProfileFileIO.write(original, to: destination)
        var checks = 0
        XCTAssertThrowsError(try ProfileFileIO.write(Data(repeating: 1, count: 200_000), to: destination, beforeCommit: {
            checks += 1
            if checks == 3 { throw CancellationError() }
        }))
        XCTAssertEqual(try Data(contentsOf: destination), original)
        let leftovers = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertEqual(leftovers.map(\.lastPathComponent), [destination.lastPathComponent])
    }
    func testInterruptedRestoreRemovesOnlyUncommittedIDsAndPrivateStage() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(root: root), pending = UUID(), stageID = UUID()
        _ = try await store.list()
        try ProfileFileIO.write(Data(configuration.utf8), to: root.appendingPathComponent(pending.uuidString + ".ovpn"))
        let stage = root.appendingPathComponent("BackupRestore-" + stageID.uuidString)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try ProfileFileIO.write(Data("partial fixture".utf8), to: stage.appendingPathComponent(".vpnnav-export-" + UUID().uuidString))
        let journal: [String: Any] = ["schemaVersion": 1, "ids": [pending.uuidString], "stageID": stageID.uuidString]
        try ProfileFileIO.write(JSONSerialization.data(withJSONObject: journal), to: root.appendingPathComponent("backup-restore.json"))
        let profiles = try await store.list(); XCTAssertTrue(profiles.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path)); XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(pending.uuidString + ".ovpn").path))
    }
    func testCommittedRestoreRecoveryRetainsReferencedConfiguration() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.ovpn"); try configuration.write(to: file, atomically: true, encoding: .utf8)
        let store = ProfileStore(root: root), existing = try await store.importProfile(from: file)
        let journal: [String: Any] = ["schemaVersion": 1, "ids": [existing.id.uuidString]]
        try ProfileFileIO.write(JSONSerialization.data(withJSONObject: journal), to: root.appendingPathComponent("backup-restore.json"))
        let profiles = try await store.list(); XCTAssertEqual(profiles, [existing])
        let contents = try await store.original(for: existing); XCTAssertEqual(contents, configuration)
    }
    func testUnknownRecoveryMarkerPreservesEvidence() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(root: root), marker = root.appendingPathComponent("backup-restore.json")
        try ProfileFileIO.write(Data("{\"schemaVersion\":999,\"ids\":[]}".utf8), to: marker)
        do { _ = try await store.list(); XCTFail() } catch { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }
    func testBackupRejectsHistorySymlinkEvenWithinTheStore() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("source.ovpn"); try configuration.write(to: file, atomically: true, encoding: .utf8)
        let store = ProfileStore(root: root), profile = try await store.importProfile(from: file)
        try await store.revise(profile, text: configuration + "# revision\n")
        let history = root.appendingPathComponent("History"), moved = root.appendingPathComponent("OtherHistory")
        try FileManager.default.moveItem(at: history, to: moved)
        try FileManager.default.createSymbolicLink(at: history, withDestinationURL: moved)
        do { _ = try await store.backupSnapshot(); XCTFail() } catch { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
    }
    func testHistorySymlinkRefusedAndFailedRestoreCanRecoverWithoutTouchingOutside() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside"), target = root.appendingPathComponent("store")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("untouched"); try Data("private sentinel".utf8).write(to: sentinel)
        let store = ProfileStore(root: target); _ = try await store.list()
        try FileManager.default.createSymbolicLink(at: target.appendingPathComponent("History"), withDestinationURL: outside)
        do { _ = try await store.restoreBackup(payload(), expecting: []); XCTFail() } catch { }
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("private sentinel".utf8))
        try FileManager.default.removeItem(at: target.appendingPathComponent("History"))
        let profiles = try await store.list(); XCTAssertTrue(profiles.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("backup-restore.json").path))
    }
}
