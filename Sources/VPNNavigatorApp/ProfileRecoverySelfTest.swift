import Foundation
import Combine
import AppKit
import VPNNavigatorCore

@MainActor
enum ProfileRecoverySelfTest {
    static func run() async throws {
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" else { throw Failure.check }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vpnnav-index-model-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("工作网络.ovpn"), folder = root.appendingPathComponent("profiles")
        try "client\ndev tun\nremote fixture.example 1194\n<ca>\nFAKE\n</ca>\n".write(to: source, atomically: true, encoding: .utf8)
        let model = AppModel(profileStoreRoot: folder)
        await model.importFile(source); model.clearImportReport(); model.message = nil
        guard let original = model.selected else { throw Failure.check }
        let index = folder.appendingPathComponent("profiles.json")
        try Data("damage A".utf8).write(to: index)
        await model.inspectProfileIndex()
        guard model.showingProfileIndexRecovery, model.profileIndexIssue != nil, model.profiles.isEmpty,
              model.selectedID == nil, !model.canChooseProfileFiles,
              model.profileIndexRecovery?.profiles == [original], model.canRecoverProfileIndex else { throw Failure.check }
        model.activeProfileID = original.id; model.connectionStatus = "connected: isolated fixture"
        await model.recoverProfileIndex()
        guard !model.canRecoverProfileIndex, try Data(contentsOf: index) == Data("damage A".utf8) else { throw Failure.check }
        model.activeProfileID = nil; model.connectionStatus = "disconnected: fixture"
        try Data("damage B".utf8).write(to: index)
        await model.recoverProfileIndex()
        guard model.profileIndexRecovery == nil, !model.canRecoverProfileIndex,
              model.profileIndexRecoveryProblem?.contains("重新检查") == true,
              try Data(contentsOf: index) == Data("damage B".utf8) else { throw Failure.check }
        await model.inspectProfileIndex()
        var exitBlocked = false
        let lifecycle = ApplicationLifecycle(); lifecycle.model = model
        let observation = model.$profiles.sink { values in
            if !values.isEmpty && model.profileIndexRecoveryInProgress {
                exitBlocked = !model.canQuit && lifecycle.applicationShouldTerminate(NSApplication.shared) == .terminateCancel
            }
        }
        await model.recoverProfileIndex(); observation.cancel()
        guard exitBlocked, model.profileIndexIssue == nil, model.profiles == [original],
              model.selectedID == original.id, !model.profileTransferInProgress,
              model.profileIndexRecoveryProblem?.contains("已恢复") == true else { throw Failure.check }
        model.showingProfileIndexRecovery = false
        guard model.canChooseProfileFiles else { throw Failure.check }
        // Healthy metadata remains usable if the secondary checkpoint is broken.
        try Data("invalid backup".utf8).write(to: folder.appendingPathComponent("profiles.backup.json"))
        await model.inspectProfileIndex()
        guard model.profileIndexIssue == nil, model.profiles == [original], !model.canRecoverProfileIndex,
              model.profileIndexBackupStatus.contains("暂无可用备份") else { throw Failure.check }
        await model.refreshProfileIndexBackup()
        guard model.profileIndexBackupStatus.contains("已备份"), model.profileIndexRecoveryProblem?.contains("备份已更新") == true else { throw Failure.check }
        print("PASS: production profile index recovery model previews metadata, blocks active-session restore and Quit during writes, rejects stale confirmation and preserves healthy-primary access after backup damage; no VPN requests.")
    }
    enum Failure: Error { case check }
}
