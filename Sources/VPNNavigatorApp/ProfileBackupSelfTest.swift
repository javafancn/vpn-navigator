import Foundation
import VPNNavigatorCore

@MainActor
enum ProfileBackupSelfTest {
    static func run() async throws {
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" else { throw Failure.check }
        let suite = "VPNNavBackupCI-" + UUID().uuidString
        guard let isolated = UserDefaults(suiteName: suite) else { throw Failure.check }
        defer { isolated.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(backgroundServiceDefaults: isolated, profileStoreRoot: root.appendingPathComponent("profiles"), libraryDefaults: isolated, smartDefaults: isolated)
        defer { model.smartConnection.stop(); model.quickAccess.shutdown() }
        let file = root.appendingPathComponent("fixture.ovpn")
        try "client\ndev tun\nremote fixture.example 1194\n<ca>\nFAKE_CA\n</ca>\n".write(to: file, atomically: true, encoding: .utf8)
        await model.importFile(file); model.clearImportReport()
        guard let original = model.selected, model.canUseProfileBackup else { throw Failure.check }
        let controller = ProfileBackupController(model: model)
        controller.password = "correct horse backup key"; controller.confirmation = "different"; controller.acknowledged = true
        guard !controller.canExport else { throw Failure.check }
        controller.confirmation = controller.password
        guard controller.canExport else { throw Failure.check }
        controller.clearSecrets()
        guard controller.password.isEmpty, controller.confirmation.isEmpty else { throw Failure.check }
        model.showingProfileBackup = true
        guard model.smartConnectionContext().occupied, model.quickAccessAction(for: original.id) == .blocked else { throw Failure.check }
        let archive = root.appendingPathComponent("fixture.vpnnavbackup"), password = "correct horse backup key"
        guard try await model.createEncryptedBackup(password: password, to: archive) == 1 else { throw Failure.check }
        let preview = try await model.previewEncryptedBackup(at: archive, password: password)
        guard preview.snapshot.entries.count == 1, preview.existing == model.profiles else { throw Failure.check }
        let active = SessionReport(state: .connected, message: "synthetic", activeProfileID: original.id,
            receivedBytes: nil, sentBytes: nil, attemptID: UUID(), networkRecoveryRequired: false, routingMode: .original)
        model.applyVerifiedSessionReport(active)
        guard !model.canRestoreProfileBackup else { throw Failure.check }
        do { _ = try await model.restoreEncryptedBackup(preview); throw Failure.check }
        catch is Failure { throw Failure.check }
        catch { }
        guard model.activeProfileID == original.id, model.profiles.count == 1 else { throw Failure.check }
        model.applyVerifiedSessionReport(.init(state: .disconnected, message: "synthetic", activeProfileID: nil,
            receivedBytes: nil, sentBytes: nil, networkRecoveryRequired: false))
        let restored = try await model.restoreEncryptedBackup(preview)
        guard restored == 1, model.profiles.count == 2, Set(model.profiles.map(\.id)).count == 2 else { throw Failure.check }
        do { _ = try await model.restoreEncryptedBackup(preview); throw Failure.check }
        catch is Failure { throw Failure.check }
        catch { }
        guard model.profiles.count == 2 else { throw Failure.check }
        let cancelledFile = root.appendingPathComponent("cancelled.vpnnavbackup")
        let work = Task { try await model.createEncryptedBackup(password: password, to: cancelledFile) }
        for _ in 0..<100 { if model.profileBackupInProgress { break }; await Task.yield() }
        guard model.profileBackupInProgress, !model.canQuit, !model.canUseProfileBackup else { work.cancel(); throw Failure.check }
        work.cancel()
        do { _ = try await work.value; throw Failure.check }
        catch is CancellationError { }
        guard !model.profileBackupInProgress, !FileManager.default.fileExists(atPath: cancelledFile.path) else { throw Failure.check }
        print("PASS encrypted backup: native password/confirmation gates, secret clearing, smart/quick access exclusion, real encrypted export/decrypt, active-session refusal, append-only restore, stale preview refusal, cancellation and Quit barrier; no VPN requests")
    }
    enum Failure: Error { case check }
}
