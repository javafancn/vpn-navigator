import Foundation
import VPNNavigatorCore

@MainActor
enum ProfileHealthSelfTest {
    static func run() async throws {
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" else { throw Failure.check }
        let suite = "VPNNavHealthCI-" + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { throw Failure.check }
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(backgroundServiceDefaults: defaults, profileStoreRoot: root.appendingPathComponent("profiles"), libraryDefaults: defaults, smartDefaults: defaults)
        defer { model.profileHealth.stop(); model.smartConnection.stop(); model.quickAccess.shutdown() }
        let config = "client\ndev tun\nremote fixture.example 1194\n<ca>\nSYNTHETIC_CA\n</ca>\nauth-user-pass\n"
        let originalFile = root.appendingPathComponent("old.ovpn")
        try config.write(to: originalFile, atomically: true, encoding: .utf8)
        await model.importFile(originalFile); model.clearImportReport()
        guard let original = model.selected else { throw Failure.check }
        model.showProfileHealth(original.id, updating: true)
        guard model.profileHealthTarget?.id == original.id, model.smartConnectionContext().occupied,
              model.quickAccessAction(for: original.id) == .blocked else { throw Failure.check }
        let newFile = root.appendingPathComponent("new.ovpn")
        try config.replacingOccurrences(of: "fixture.example", with: "new.example").write(to: newFile, atomically: true, encoding: .utf8)
        let controller = ProfileUpdateController(model: model, id: original.id)
        controller.read(newFile)
        for _ in 0..<300 { if !controller.busy { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        guard let preview = controller.preview, preview.identityChanged, !controller.canApply else { throw Failure.check }
        controller.confirmed = true
        guard !controller.canApply else { throw Failure.check }
        controller.identityConfirmed = true
        guard !controller.canApply else { throw Failure.check } // synthetic CA requires acknowledgement
        controller.healthConfirmed = true
        guard controller.canApply else { throw Failure.check }
        model.applyVerifiedSessionReport(.init(state: .connected, message: "synthetic", activeProfileID: original.id,
            receivedBytes: nil, sentBytes: nil, attemptID: UUID(), networkRecoveryRequired: false, routingMode: .original))
        guard !controller.canApply else { throw Failure.check }
        do { try await model.applyProfileUpdate(preview); throw Failure.check } catch is Failure { throw Failure.check } catch { }
        model.applyVerifiedSessionReport(.init(state: .disconnected, message: "synthetic", activeProfileID: nil,
            receivedBytes: nil, sentBytes: nil, networkRecoveryRequired: false))
        model.username = "draft-user"; model.password = "synthetic-draft"
        let apply = Task { try await model.applyProfileUpdate(preview) }
        for _ in 0..<300 { if model.profileUpdateInProgress { break }; await Task.yield() }
        guard model.profileUpdateInProgress, !model.canQuit else { throw Failure.check }
        try await apply.value
        guard model.profiles.count == 1, let updated = model.selected, updated.id == original.id,
              updated.credentialID != original.credentialID, updated.sourceFilename == "new.ovpn",
              model.username.isEmpty, model.password.isEmpty else { throw Failure.check }
        let history = await model.revisions(for: updated); guard history.count == 1 else { throw Failure.check }
        do { try await model.applyProfileUpdate(preview); throw Failure.check } catch is Failure { throw Failure.check } catch { }
        controller.reset(); guard controller.preview == nil, !controller.canApply else { throw Failure.check }
        guard !model.profileHealth.remindersEnabled else { throw Failure.check }
        print("PASS profile health: native preview and acknowledgement gates, active-session refusal, stale confirmation, stable profile ID, history, credential isolation and draft clearing, smart/quick exclusion and Quit barrier; no VPN or notification permission requests")
    }
    enum Failure: Error { case check }
}
