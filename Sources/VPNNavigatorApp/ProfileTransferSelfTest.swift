import Foundation
import Combine
import VPNNavigatorCore

@MainActor
enum ProfileTransferSelfTest {
    static func run() async throws {
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" else { throw Failure.check }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vpnnav-transfer-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let sample = "client\ndev tun\nremote fixture.example 1194\n<ca>\nFAKE-CA\n</ca>\n"
        let first = root.appendingPathComponent("first.ovpn"), bad = root.appendingPathComponent("bad.ovpn"), second = root.appendingPathComponent("second.ovpn")
        try sample.write(to: first, atomically: true, encoding: .utf8)
        try "INVALID".write(to: bad, atomically: true, encoding: .utf8)
        try sample.write(to: second, atomically: true, encoding: .utf8)
        let model = AppModel(profileStoreRoot: root.appendingPathComponent("profiles"))
        var sawExitBlocked = false
        let observation = model.$importResults.sink { results in
            if !results.isEmpty && model.profileImportInProgress { sawExitBlocked = !model.canQuit }
        }
        await model.importFiles([first, bad, second])
        observation.cancel()
        guard sawExitBlocked, !model.profileImportInProgress, model.showingImportReport,
              model.importResults.count == 3, model.profiles.count == 2,
              model.importResults[1].status == .failed(.invalidFile) else { throw Failure.check }
        guard case .imported = model.importResults[0].status,
              case .imported = model.importResults[2].status else { throw Failure.check }
        model.clearImportReport()
        guard model.importResults.isEmpty, !model.showingImportReport else { throw Failure.check }
        let active = model.profiles[0].id
        model.activeProfileID = active
        model.connectionStatus = "connected: in-memory fixture only"
        let cancellation = model.$importResults.sink { results in
            if let first = results.first, case .imported = first.status { model.cancelProfileImport() }
        }
        await model.importFiles([first, root.appendingPathComponent("never-read.ovpn")])
        cancellation.cancel()
        guard model.profiles.count == 3, model.activeProfileID == active, model.connected,
              model.importResults.last?.status == .cancelled,
              !model.profileImportInProgress else { throw Failure.check }
        model.clearImportReport()
        print("PASS: production import model preserves mixed results, blocks Quit during writes, cancels between files and leaves active session identity unchanged; no VPN requests.")
    }
    enum Failure: Error { case check }
}
