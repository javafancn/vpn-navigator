import Foundation
import Darwin

public struct ProfileUpdatePreview: Sendable {
    public let profile: VPNProfile
    public let filename: String
    public let identityChanged: Bool
    public let contentChanged: Bool
    public let health: ProfileHealthReport
    public var sourceByteCount: Int { source.count }
    // Kept in memory, never rendered as a raw diff containing private keys.
    let source: Data
    let runtime: Data
    let oldSource: Data
    let oldRuntime: Data?
}
public enum ProfileUpdateFailure: Error, LocalizedError {
    case stale, unsafe, pending, unchanged
    public var errorDescription: String? {
        switch self {
        case .stale: return "配置或设置已改变，请重新选择文件并预览。"
        case .unsafe: return "更新文件不兼容、材料缺失，或配置存储状态无法核验。"
        case .pending: return "请先断开 VPN、完成网络恢复并等待其它操作结束。"
        case .unchanged: return "新文件与当前配置相同，无需更新。"
        }
    }
}
struct ProfileUpdateReceipt: Codable {
    var schema = 1
    let previous: VPNProfile
    let updated: VPNProfile
    let source: Data
    let runtime: Data?
    let revision: UUID
    var committed = false
}

extension ProfileStore {
    func reviseTransaction(_ profile: VPNProfile, text: String) throws {
        guard let current = try list().first(where: { $0.id == profile.id }) else { throw StoreError.notFound }
        _ = try ProfileSafety.validate(text)
        let source = try ProfileFileIO.read(root.appendingPathComponent(current.relativePath))
        guard source != Data(text.utf8) else { return }
        let runtime = try optionalUpdateFile(root.appendingPathComponent("\(current.id.uuidString).runtime.ovpn"))
        let previous = String(decoding: runtime ?? source, as: UTF8.self)
        let preview = ProfileUpdatePreview(profile: current, filename: current.sourceFilename,
            identityChanged: ProfileHealth.credentialContext(previous) != ProfileHealth.credentialContext(text), contentChanged: true,
            health: ProfileHealth.inspect(runtime: text, mode: current.mode), source: Data(text.utf8), runtime: Data(text.utf8), oldSource: source, oldRuntime: runtime)
        _ = try applyUpdate(preview)
    }
    public func healthReports(now: Date = Date()) throws -> [UUID: ProfileHealthReport] {
        let profiles = try list()
        guard profiles.count <= 1000 else { throw ProfileUpdateFailure.unsafe }
        var result: [UUID: ProfileHealthReport] = [:]
        for profile in profiles {
            try Task.checkCancellation()
            do {
                var report = ProfileHealth.inspect(runtime: try runtimeConfig(for: profile), mode: profile.mode, now: now)
                if (try? CustomRuleSet(profile.customRules)) == nil {
                    report = .init(checkedAt: now, issues: report.issues + [.init(id: "custom-rules", severity: .error, message: "自定义分流规则无效，请检查后再连接。")], certificates: report.certificates)
                }
                result[profile.id] = report
            } catch is CancellationError { throw CancellationError() }
            catch { result[profile.id] = .init(checkedAt: now, issues: [.init(id: "storage", severity: .error, message: "无法读取本机配置，请检查文件权限或恢复备份。")], certificates: []) }
        }
        return result
    }
    public func previewUpdate(id: UUID, from file: URL, now: Date = Date()) throws -> ProfileUpdatePreview {
        guard let profile = try list().first(where: { $0.id == id }), file.pathExtension.lowercased() == "ovpn" else { throw ProfileUpdateFailure.stale }
        let data = try ProfileFileIO.read(file, followSymlinks: true)
        guard !data.isEmpty, String(data: data, encoding: .utf8) != nil else { throw ProfileUpdateFailure.unsafe }
        var text = String(decoding: data, as: UTF8.self)
        if text.first == "\u{FEFF}" { text.removeFirst() }
        let runtime = try ProfileMaterializer.materialize(text: text, directory: file.deletingLastPathComponent())
        let validated = try ProfileSafety.validate(runtime)
        try ManagedRoutingPolicy.validate(validated, mode: profile.mode)
        let oldSource = try ProfileFileIO.read(root.appendingPathComponent(profile.relativePath))
        let oldRuntime = try optionalUpdateFile(root.appendingPathComponent("\(id.uuidString).runtime.ovpn"))
        let previousRuntime = String(decoding: oldRuntime ?? oldSource, as: UTF8.self)
        return .init(profile: profile, filename: String(file.lastPathComponent.prefix(255)),
            identityChanged: ProfileHealth.credentialContext(previousRuntime) != ProfileHealth.credentialContext(runtime),
            contentChanged: oldSource != data || oldRuntime != Data(runtime.utf8),
            health: ProfileHealth.inspect(runtime: runtime, mode: profile.mode, now: now),
            source: data, runtime: Data(runtime.utf8), oldSource: oldSource, oldRuntime: oldRuntime)
    }
    /// The receipt is the commit point. Until it is marked committed, failure or
    /// process interruption restores the previous bytes, metadata and history.
    public func applyUpdate(_ preview: ProfileUpdatePreview) throws -> VPNProfile {
        try applyUpdate(preview, checkpoint: { _ in })
    }
    func applyUpdate(_ preview: ProfileUpdatePreview, checkpoint: (Int) throws -> Void) throws -> VPNProfile {
        var profiles = try list()
        guard let position = profiles.firstIndex(where: { $0.id == preview.profile.id }), profiles[position] == preview.profile,
              try ProfileFileIO.read(root.appendingPathComponent(preview.profile.relativePath)) == preview.oldSource,
              try optionalUpdateFile(root.appendingPathComponent("\(preview.profile.id.uuidString).runtime.ovpn")) == preview.oldRuntime else { throw ProfileUpdateFailure.stale }
        guard preview.contentChanged else { throw ProfileUpdateFailure.unchanged }
        _ = try ProfileSafety.validate(String(decoding: preview.runtime, as: UTF8.self))
        try Task.checkCancellation()
        var updated = preview.profile
        updated.sourceFilename = preview.filename
        if preview.identityChanged { updated.credentialID = UUID() }
        var receipt = ProfileUpdateReceipt(previous: preview.profile, updated: updated, source: preview.oldSource, runtime: preview.oldRuntime, revision: UUID())
        let receiptURL = root.appendingPathComponent("profile-update.json")
        let history = try updateHistoryDirectory(id: updated.id, create: true)
        try ProfileFileIO.write(JSONEncoder().encode(receipt), to: receiptURL, beforeCommit: { try Task.checkCancellation() })
        do {
            try ProfileFileIO.write(preview.oldRuntime ?? preview.oldSource, to: history.appendingPathComponent(receipt.revision.uuidString + ".ovpn"))
            try ProfileFileIO.write(preview.oldSource, to: history.appendingPathComponent(receipt.revision.uuidString + ".source.ovpn"))
            try ProfileFileIO.write(preview.source, to: root.appendingPathComponent(updated.relativePath))
            try checkpoint(1); try Task.checkCancellation()
            try ProfileFileIO.write(preview.runtime, to: root.appendingPathComponent("\(updated.id.uuidString).runtime.ovpn"))
            try checkpoint(2); try Task.checkCancellation()
            profiles[position] = updated; try index.save(profiles)
            try checkpoint(3); try Task.checkCancellation()
            receipt.committed = true
            try ProfileFileIO.write(JSONEncoder().encode(receipt), to: receiptURL, beforeCommit: { try Task.checkCancellation() })
        } catch {
            // Recovery deliberately ignores task cancellation: rollback must
            // finish, or leave its receipt to block subsequent reads/mutations.
            try recoverProfileUpdate()
            throw error
        }
        // No throwing work after publication. Committed cleanup is repeatable.
        try? FileManager.default.removeItem(at: receiptURL)
        return updated
    }
    func recoverProfileUpdate() throws {
        let receiptURL = root.appendingPathComponent("profile-update.json")
        guard let data = try optionalUpdateFile(receiptURL, maximumBytes: 6_000_000) else { return }
        guard let value = try? JSONDecoder().decode(ProfileUpdateReceipt.self, from: data), value.schema == 1,
              value.previous.id == value.updated.id,
              value.previous.relativePath == value.previous.id.uuidString + ".ovpn",
              value.updated.relativePath == value.previous.relativePath,
              value.source.count <= 2_000_000, (value.runtime?.count ?? 0) <= 2_000_000 else { throw ProfileUpdateFailure.unsafe }
        var profiles = try index.list()
        guard let position = profiles.firstIndex(where: { $0.id == value.previous.id }),
              profiles[position] == value.previous || profiles[position] == value.updated else { throw ProfileUpdateFailure.unsafe }
        if !value.committed {
            try ProfileFileIO.write(value.source, to: root.appendingPathComponent(value.previous.relativePath))
            let runtimeURL = root.appendingPathComponent("\(value.previous.id.uuidString).runtime.ovpn")
            if let runtime = value.runtime { try ProfileFileIO.write(runtime, to: runtimeURL) }
            else if try optionalUpdateFile(runtimeURL) != nil { try FileManager.default.removeItem(at: runtimeURL) }
            profiles[position] = value.previous; try index.save(profiles)
            if let directory = try existingUpdateHistory(id: value.previous.id) {
                for suffix in [".ovpn", ".source.ovpn"] {
                    let file = directory.appendingPathComponent(value.revision.uuidString + suffix)
                    if try optionalUpdateFile(file) != nil { try FileManager.default.removeItem(at: file) }
                }
            }
        } else { guard profiles[position] == value.updated else { throw ProfileUpdateFailure.unsafe } }
        try FileManager.default.removeItem(at: receiptURL)
    }
    private func optionalUpdateFile(_ url: URL, maximumBytes: Int = 2_000_000) throws -> Data? {
        var info = stat()
        if lstat(url.path, &info) != 0 { if errno == ENOENT { return nil }; throw ProfileUpdateFailure.unsafe }
        guard info.st_uid == getuid(), info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw ProfileUpdateFailure.unsafe }
        return try ProfileFileIO.read(url, maximumBytes: maximumBytes)
    }
    private func existingUpdateHistory(id: UUID) throws -> URL? {
        let directory = root.appendingPathComponent("History").appendingPathComponent(id.uuidString)
        var info = stat()
        if lstat(root.appendingPathComponent("History").path, &info) != 0 { if errno == ENOENT { return nil }; throw ProfileUpdateFailure.unsafe }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), info.st_uid == getuid() else { throw ProfileUpdateFailure.unsafe }
        if lstat(directory.path, &info) != 0 { if errno == ENOENT { return nil }; throw ProfileUpdateFailure.unsafe }
        return try updateHistoryDirectory(id: id, create: false)
    }
    private func updateHistoryDirectory(id: UUID, create: Bool) throws -> URL {
        var directory = root
        for component in ["History", id.uuidString] {
            directory.appendPathComponent(component)
            var info = stat()
            if lstat(directory.path, &info) != 0 {
                guard errno == ENOENT, create else { throw ProfileUpdateFailure.unsafe }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                guard lstat(directory.path, &info) == 0 else { throw ProfileUpdateFailure.unsafe }
            }
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), info.st_uid == getuid() else { throw ProfileUpdateFailure.unsafe }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        return directory
    }
}
