import XCTest
import Darwin
@testable import VPNNavigatorCore

final class ProfileUpdateTests: XCTestCase {
    private let config = "client\ndev tun\nremote fixture.example 1194\n<ca>\nSYNTHETIC_CA\n</ca>\nauth-user-pass\n"
    private func fixture() async throws -> (URL, ProfileStore, VPNProfile) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("update-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("old.ovpn")
        try Data(config.utf8).write(to: file)
        let store = ProfileStore(root: root.appendingPathComponent("profiles"))
        var profile = try await store.importProfile(from: file)
        profile.name = "Work"; profile.group = "团队"; profile.notes = "keep notes"; profile.isFavorite = true; profile.mode = .fullVPN
        profile.customRules = [.init(cidr: "10.0.0.0/8", action: .direct)]
        try await store.update(profile)
        return (root, store, profile)
    }
    private func candidate(_ root: URL, text: String? = nil) throws -> URL {
        let file = root.appendingPathComponent("new.ovpn")
        try Data((text ?? config.replacingOccurrences(of: "fixture.example", with: "new.example")).utf8).write(to: file)
        return file
    }
    func testPreviewDoesNotWriteAndSuccessfulUpdatePreservesMetadataAndArchives() async throws {
        let (root, store, original) = try await fixture()
        let preview = try await store.previewUpdate(id: original.id, from: candidate(root))
        XCTAssertTrue(preview.identityChanged)
        let before = try await store.original(for: original); XCTAssertEqual(before, config)
        let beforeHistory = try await store.revisions(for: original); XCTAssertTrue(beforeHistory.isEmpty)
        let updated = try await store.applyUpdate(preview)
        var expected = original; expected.sourceFilename = "new.ovpn"; expected.credentialID = updated.credentialID
        XCTAssertEqual(updated, expected); XCTAssertNotEqual(updated.credentialID, original.credentialID)
        let history = try await store.revisions(for: updated); XCTAssertEqual(history.count, 1)
        let runtime = try await store.runtimeConfig(for: updated); XCTAssertTrue(runtime.contains("new.example"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("profiles/profile-update.json").path))
    }
    func testCommentOnlyUpdateRetainsCredentialNamespace() async throws {
        let (root, store, original) = try await fixture()
        let preview = try await store.previewUpdate(id: original.id, from: candidate(root, text: config + "# comment\n"))
        XCTAssertFalse(preview.identityChanged)
        let updated = try await store.applyUpdate(preview); XCTAssertEqual(updated.credentialID, original.credentialID)
    }
    func testNewExternalMaterialsRemainSelfContainedAfterSourceRemoval() async throws {
        let (root, store, profile) = try await fixture()
        let input = root.appendingPathComponent("materials")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: false)
        try Data("SYNTHETIC_NEW_CA".utf8).write(to: input.appendingPathComponent("ca.pem"))
        let file = input.appendingPathComponent("new.ovpn")
        try Data("client\ndev tun\nremote new.example\nca ca.pem\n".utf8).write(to: file)
        let preview = try await store.previewUpdate(id: profile.id, from: file)
        try FileManager.default.removeItem(at: input)
        let updated = try await store.applyUpdate(preview)
        let runtime = try await store.runtimeConfig(for: updated); XCTAssertTrue(runtime.contains("SYNTHETIC_NEW_CA")); XCTAssertFalse(runtime.contains("ca ca.pem"))
    }
    func testStaleMetadataAndSourceRefuseConfirmation() async throws {
        let (root, store, profile) = try await fixture()
        let preview = try await store.previewUpdate(id: profile.id, from: candidate(root))
        var changed = profile; changed.notes = "edited after preview"; try await store.update(changed)
        do { _ = try await store.applyUpdate(preview); XCTFail() } catch ProfileUpdateFailure.stale { }
        try await store.update(profile)
        try Data((config + "# changed\n").utf8).write(to: root.appendingPathComponent("profiles/" + profile.relativePath))
        do { _ = try await store.applyUpdate(preview); XCTFail() } catch ProfileUpdateFailure.stale { }
    }
    func testUnsafeOrMissingExternalMaterialNeverTouchesCurrentProfile() async throws {
        let (root, store, profile) = try await fixture()
        for text in [config + "up /unsafe/script", "client\nremote new.example\nca absent.pem\n"] {
            do { _ = try await store.previewUpdate(id: profile.id, from: candidate(root, text: text)); XCTFail() } catch { }
        }
        let source = try await store.original(for: profile); XCTAssertEqual(source, config)
    }
    func testEveryPublicationFailureRollsBackFilesMetadataAndHistory() async throws {
        let (root, store, original) = try await fixture()
        let preview = try await store.previewUpdate(id: original.id, from: candidate(root))
        enum Injected: Error { case failure }
        for point in 1...3 {
            do { _ = try await store.applyUpdate(preview, checkpoint: { if $0 == point { throw Injected.failure } }); XCTFail() }
            catch Injected.failure { }
            let listed = try await store.list(); XCTAssertEqual(listed, [original])
            let source = try await store.original(for: original); XCTAssertEqual(source, config)
            let revisions = try await store.revisions(for: original); XCTAssertTrue(revisions.isEmpty)
        }
    }
    func testCancellationBeforeCommitRestoresPreviousBytes() async throws {
        let (root, store, original) = try await fixture()
        let preview = try await store.previewUpdate(id: original.id, from: candidate(root))
        do { _ = try await store.applyUpdate(preview, checkpoint: { if $0 == 3 { throw CancellationError() } }); XCTFail() } catch is CancellationError { }
        let listed = try await store.list(); XCTAssertEqual(listed, [original])
        let source = try await store.original(for: original); XCTAssertEqual(source, config)
    }
    func testInterruptedPreparedReceiptRecoversAndCommittedReceiptKeepsUpdate() async throws {
        let (root, store, original) = try await fixture()
        let preview = try await store.previewUpdate(id: original.id, from: candidate(root))
        let updated = try await store.applyUpdate(preview)
        let receiptURL = root.appendingPathComponent("profiles/profile-update.json")
        var receipt = ProfileUpdateReceipt(previous: original, updated: updated, source: preview.oldSource, runtime: preview.oldRuntime, revision: UUID())
        receipt.committed = true; try ProfileFileIO.write(JSONEncoder().encode(receipt), to: receiptURL)
        let kept = try await store.list(); XCTAssertEqual(kept, [updated])
        receipt.committed = false; try ProfileFileIO.write(JSONEncoder().encode(receipt), to: receiptURL)
        let reverted = try await store.list(); XCTAssertEqual(reverted, [original])
        let source = try await store.original(for: original); XCTAssertEqual(source, config)
    }
    func testMalformedReceiptBlocksRatherThanDeletingEvidence() async throws {
        let (root, store, _) = try await fixture()
        let receipt = root.appendingPathComponent("profiles/profile-update.json")
        try Data("broken".utf8).write(to: receipt)
        do { _ = try await store.list(); XCTFail() } catch { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.path))
    }
    func testHistorySymlinkRefusedBeforeStartingTransaction() async throws {
        let (root, store, original) = try await fixture()
        let preview = try await store.previewUpdate(id: original.id, from: candidate(root))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("profiles/History"), withDestinationURL: root)
        do { _ = try await store.applyUpdate(preview); XCTFail() } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("profiles/profile-update.json").path))
        let listed = try await store.list(); XCTAssertEqual(listed, [original])
    }
    func testBOMCRLFAndPrivateFilePermissions() async throws {
        let (root, store, profile) = try await fixture()
        let text = "\u{FEFF}" + config.replacingOccurrences(of: "\n", with: "\r\n") + "# updated\r\n"
        let preview = try await store.previewUpdate(id: profile.id, from: candidate(root, text: text))
        let updated = try await store.applyUpdate(preview)
        let file = root.appendingPathComponent("profiles/" + updated.relativePath)
        XCTAssertEqual(try Data(contentsOf: file), Data(text.utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testUnchangedDoesNotArchiveAndLegacyCredentialsDefaultToProfileID() async throws {
        let (root, store, profile) = try await fixture()
        let preview = try await store.previewUpdate(id: profile.id, from: candidate(root, text: config))
        XCTAssertFalse(preview.contentChanged)
        do { _ = try await store.applyUpdate(preview); XCTFail() } catch ProfileUpdateFailure.unchanged { }
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any]); json.removeValue(forKey: "credentialID")
        let old = try JSONDecoder().decode(VPNProfile.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(old.credentialID, profile.id)
    }
}
