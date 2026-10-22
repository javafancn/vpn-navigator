import Foundation
import Combine
import AppKit
import VPNNavigatorCore

@MainActor
enum ProfileLibrarySelfTest {
    static func run() async throws {
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" else { throw Failure.check }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vpnnav-library-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "vpnnav-library-" + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { throw Failure.check }
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let folder = root.appendingPathComponent("profiles")
        let model = AppModel(profileStoreRoot: folder, libraryDefaults: defaults)
        for name in ["first", "second"] {
            let file = root.appendingPathComponent(name + ".ovpn")
            try "client\ndev tun\nremote fixture.example 1194\n<ca>\nFAKE\n</ca>\n".write(to: file, atomically: true, encoding: .utf8)
            await model.importFile(file); model.clearImportReport(); model.message = nil
        }
        guard model.profiles.count == 2 else { throw Failure.check }
        let a = model.profiles[0].id, b = model.profiles[1].id
        await model.updateMetadata(name: "Work 10", group: "研发", notes: "A note", favorite: false, for: a)
        await model.updateMetadata(name: "Work 2", group: "家庭", notes: "B note", favorite: true, for: b)
        model.selectedID = a
        model.profileLibrary.scope = .favorites
        guard model.libraryProfiles.map(\.id) == [b], model.selectedID == a,
              model.profileLibrary.selectedProfile(model.selectedID, in: model.profiles) == nil else { throw Failure.check }
        model.profileLibrary.query = "家庭 ＷＯＲＫ"
        guard model.libraryProfiles.map(\.id) == [b] else { throw Failure.check }
        model.profileLibrary.clearFilters(); model.profileLibrary.sort = .name
        guard model.libraryProfiles.map(\.id) == [b, a], model.selectedID == a else { throw Failure.check }
        let restored = AppModel(profileStoreRoot: root.appendingPathComponent("unused"), libraryDefaults: defaults)
        guard restored.profileLibrary.sort == .name, restored.profileLibrary.scope == .all,
              restored.profileLibrary.query.isEmpty else { throw Failure.check }
        await model.setMode(.fullVPN, for: b)
        var exitBlocked = false
        let lifecycle = ApplicationLifecycle(); lifecycle.model = model
        let observation = model.$profiles.sink { _ in
            if model.profileMetadataInProgress {
                exitBlocked = !model.canQuit && lifecycle.applicationShouldTerminate(NSApplication.shared) == .terminateCancel
            }
        }
        // Selection changed before this delayed inspector action: only B changes.
        await model.updateMetadata(name: "Renamed B", group: "研发", notes: "B updated", favorite: true, for: b)
        observation.cancel()
        guard exitBlocked, model.selectedID == a,
              model.profiles.first(where: { $0.id == a })?.name == "Work 10",
              model.profiles.first(where: { $0.id == b })?.mode == .fullVPN,
              model.libraryGroups.first(where: { $0.name == "研发" })?.count == 2 else { throw Failure.check }
        model.selectedID = b
        await model.setProfileFavorite(true, for: a)
        guard let favorite = model.profiles.first(where: { $0.id == a }), favorite.isFavorite,
              favorite.name == "Work 10", favorite.notes == "A note", favorite.group == "研发" else { throw Failure.check }
        model.applyVerifiedSessionReport(SessionReport(state: .connected, message: "fixture", activeProfileID: b,
            receivedBytes: 123, sentBytes: 456, attemptID: UUID(), routingMode: .fullVPN, routingRevision: UUID()))
        await model.deleteProfile(a)
        guard model.profiles.count == 2, model.activeProfileID == b, model.connected,
              model.traffic?.receivedBytes == 123 else { throw Failure.check }
        model.applyVerifiedSessionReport(SessionReport(state: .disconnected, message: "fixture", activeProfileID: nil,
            receivedBytes: nil, sentBytes: nil))
        model.message = nil; model.selectedID = b
        await model.deleteProfile(a)
        guard model.profiles.map(\.id) == [b], model.selectedID == b else { throw Failure.check }
        model.profileLibrary.scope = .group("研发")
        await model.updateMetadata(name: "Renamed B", group: "新组", notes: "B updated", favorite: true, for: b)
        guard model.profileLibrary.scope == .all,
              ProfileLibraryQuery.groupChoices(model.profiles).contains("新组") else { throw Failure.check }
        let before = model.profiles
        await model.updateMetadata(name: "", group: "新组", notes: "invalid", favorite: false, for: b)
        guard model.profiles == before, !model.profileMetadataInProgress else { throw Failure.check }
        let checkpoint = try await ProfileStore(root: folder).indexBackupInfo()
        guard checkpoint.matchesCurrentIndex else { throw Failure.check }
        print("PASS: production library filters, sort preference, group reuse, hidden selection, pinned metadata/favorite/delete, preserved routing preference, blocked active-session deletion and Quit during writes; no VPN requests.")
    }
    enum Failure: Error { case check }
}
