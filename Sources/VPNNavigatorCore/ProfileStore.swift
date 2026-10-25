import Foundation
import Darwin

/// A private profile repository with version history.
public struct ProfileRevision: Identifiable, Sendable {
    public let filename: String
    public let createdAt: Date
    public var id: String { filename }
}
/// The initially imported source is saved to history on the first edit.
public actor ProfileStore {
    private let root: URL
    private var index: ProfileIndexRepository { ProfileIndexRepository(root: root) }
    public init(root: URL) { self.root = root }
    private func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }
    public func list() throws -> [VPNProfile] {
        try prepare()
        try recoverBackupRestore()
        return try index.list()
    }
    public func indexBackupInfo() throws -> ProfileIndexBackupInfo {
        try prepare(); return try index.backupInfo()
    }
    public func refreshIndexBackup() throws {
        try prepare(); try index.refreshBackup()
    }
    public func indexRecoveryPreview() throws -> ProfileIndexRecoveryPreview {
        try prepare(); return try index.recoveryPreview()
    }
    public func recoverIndex(_ preview: ProfileIndexRecoveryPreview) throws {
        try prepare(); try index.recover(preview)
    }
    public func importProfile(from file: URL) throws -> VPNProfile {
        try prepare()
        guard file.pathExtension.lowercased() == "ovpn" else { throw StoreError.invalidFile }
        let contents = try ProfileFileIO.read(file, followSymlinks: true)
        guard !contents.isEmpty, contents.count <= 2_000_000,
              let string = String(data: contents, encoding: .utf8),
              string.contains("remote ") || string.contains("\nremote ") else { throw StoreError.invalidFile }
        // Normalize external inline-capable certificates into a private runtime copy.
        // Preserve the user's original bytes as the canonical source.
        let runtime = try ProfileMaterializer.materialize(text: string, directory: file.deletingLastPathComponent())
        var profiles = try list()
        let id = UUID()
        let filename = "\(id.uuidString).ovpn"
        let destination = root.appendingPathComponent(filename)
        let runtimeURL = root.appendingPathComponent("\(id.uuidString).runtime.ovpn")
        let profile = VPNProfile(id: id, name: file.deletingPathExtension().lastPathComponent,
                                 sourceFilename: file.lastPathComponent, relativePath: filename)
        profiles.append(profile)
        var created: [URL] = []
        do {
            try ProfileFileIO.write(contents, to: destination); created.append(destination)
            try ProfileFileIO.write(Data(runtime.utf8), to: runtimeURL); created.append(runtimeURL)
            try save(profiles)
        } catch {
            for path in created { try? FileManager.default.removeItem(at: path) }
            throw error
        }
        return profile
    }
    public func update(_ profile: VPNProfile) throws {
        var profiles = try list()
        guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else { throw StoreError.notFound }
        profiles[idx] = profile
        try save(profiles)
    }
    public func fileSize(for profile: VPNProfile) throws -> Int {
        guard profile.relativePath == "\(profile.id.uuidString).ovpn" else { throw StoreError.invalidFile }
        return (try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(profile.relativePath).path)[.size] as? NSNumber)?.intValue ?? 0
    }
    public func original(for profile: VPNProfile) throws -> String {
        // Never allow untrusted persisted paths to escape the store.
        guard profile.relativePath == "\(profile.id.uuidString).ovpn" else { throw StoreError.invalidFile }
        guard let text = String(data: try ProfileFileIO.read(root.appendingPathComponent(profile.relativePath)), encoding: .utf8) else { throw StoreError.invalidFile }
        return text
    }
    public func runtimeConfig(for profile: VPNProfile) throws -> String {
        guard profile.relativePath == "\(profile.id.uuidString).ovpn" else { throw StoreError.invalidFile }
        let normalized = root.appendingPathComponent("\(profile.id.uuidString).runtime.ovpn")
        guard FileManager.default.fileExists(atPath: normalized.path) else { return try original(for: profile) }
        guard let text = String(data: try ProfileFileIO.read(normalized), encoding: .utf8) else { throw StoreError.invalidFile }
        return text
    }
    private func historyDirectory(for id: UUID) -> URL {
        root.appendingPathComponent("History", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public func revisions(for profile: VPNProfile) throws -> [ProfileRevision] {
        let folder = historyDirectory(for: profile.id)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])
            .filter {
                $0.pathExtension == "ovpn" &&
                UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil
            }
            .map {
                let attr = try $0.resourceValues(forKeys: [.contentModificationDateKey])
                return ProfileRevision(filename: $0.lastPathComponent,
                                       createdAt: attr.contentModificationDate ?? Date.distantPast)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Save a safe, self-contained profile while preserving its prior source.
    public func revise(_ profile: VPNProfile, text: String) throws {
        try prepare()
        guard (try list()).contains(where: { $0.id == profile.id }),
              profile.relativePath == "\(profile.id.uuidString).ovpn" else {
            throw StoreError.notFound
        }
        _ = try ProfileSafety.validate(text)
        let oldSource = try original(for: profile)
        let oldRuntime = try runtimeConfig(for: profile)
        guard oldSource != text else { return }
        let history = historyDirectory(for: profile.id)
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: history.path)
        let archived = history.appendingPathComponent(UUID().uuidString + ".ovpn")
        // Revisions restore from self-contained runtime copies, even when the
        // imported source referenced certificates outside the profile store.
        try ProfileFileIO.write(Data(oldRuntime.utf8), to: archived)
        let originalArchive = history.appendingPathComponent(
            archived.deletingPathExtension().lastPathComponent + ".source.ovpn")
        try ProfileFileIO.write(Data(oldSource.utf8), to: originalArchive)
        let sourceURL = root.appendingPathComponent(profile.relativePath)
        let runtimeURL = root.appendingPathComponent("\(profile.id.uuidString).runtime.ovpn")
        do {
            try ProfileFileIO.write(Data(text.utf8), to: sourceURL)
            try ProfileFileIO.write(Data(text.utf8), to: runtimeURL)
        } catch {
            try? ProfileFileIO.write(Data(oldSource.utf8), to: sourceURL)
            try? ProfileFileIO.write(Data(oldRuntime.utf8), to: runtimeURL)
            throw error
        }
    }

    public func restore(_ profile: VPNProfile, revision filename: String) throws {
        guard filename == URL(fileURLWithPath: filename).lastPathComponent,
              filename.hasSuffix(".ovpn"),
              UUID(uuidString: String(filename.dropLast(5))) != nil else {
            throw StoreError.invalidFile
        }
        guard let old = String(data: try ProfileFileIO.read(historyDirectory(for: profile.id)
            .appendingPathComponent(filename)), encoding: .utf8) else { throw StoreError.invalidFile }
        try revise(profile, text: old)
    }

    public func delete(id: UUID) throws {
        var profiles = try list()
        guard let item = profiles.first(where: { $0.id == id }) else { throw StoreError.notFound }
        profiles.removeAll { $0.id == id }
        try save(profiles)
        try FileManager.default.removeItem(at: root.appendingPathComponent("\(item.id.uuidString).ovpn"))
        try? FileManager.default.removeItem(at: root.appendingPathComponent("\(item.id.uuidString).runtime.ovpn"))
        try? FileManager.default.removeItem(at: historyDirectory(for: item.id))
    }
    private func save(_ profiles: [VPNProfile]) throws {
        try index.save(profiles)
    }
}
public enum StoreError: Error { case invalidFile, notFound }


/// Backup snapshots and append-only restores share the actor's serialization.
/// A restore journal records only newly allocated IDs. Publication of the index
/// is the commit point; restart removes unreferenced staged files, retains all
/// committed configurations and never follows a history directory symlink.
extension ProfileStore {
    private struct BackupRestoreJournal: Codable {
        let schemaVersion: Int
        let ids: [UUID]
        let stageID: UUID?
    }
    private var restoreJournal: URL { root.appendingPathComponent("backup-restore.json") }
    private func privateDirectory(_ directory: URL, create: Bool = false) throws {
        if create { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_uid == getuid(),
              directory.resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().path ||
                directory.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { throw ProfileBackupFailure.pendingRecovery }
        if info.st_mode & 0o077 != 0 {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
    }
    private func backupText(_ url: URL) throws -> String {
        let data = try ProfileFileIO.read(url)
        guard String(data: data, encoding: .utf8) != nil else { throw ProfileBackupFailure.invalidContents }
        // The UTF-8 collection decoder retains a leading BOM as a scalar;
        // Foundation's encoding detector may consume it as a byte-order mark.
        return String(decoding: data, as: UTF8.self)
    }
    private func backupHistory(_ profile: VPNProfile) throws -> [ProfileBackupRevision] {
        let parent = root.appendingPathComponent("History", isDirectory: true)
        guard FileManager.default.fileExists(atPath: parent.path) else { return [] }
        try privateDirectory(parent)
        let directory = historyDirectory(for: profile.id)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        try privateDirectory(directory)
        let revisions = try revisions(for: profile)
        guard revisions.count <= 1000 else { throw ProfileBackupFailure.limits }
        return try revisions.map { revision in
            try Task.checkCancellation()
            let id = UUID(uuidString: String(revision.filename.dropLast(5)))!
            let runtime = try ProfileFileIO.read(directory.appendingPathComponent(revision.filename))
            let sourceURL = directory.appendingPathComponent(String(revision.filename.dropLast(5)) + ".source.ovpn")
            let source: String?
            if (try? FileManager.default.attributesOfItem(atPath: sourceURL.path)) != nil {
                source = try backupText(sourceURL)
            } else { source = nil }
            guard let text = String(data: runtime, encoding: .utf8) else { throw ProfileBackupFailure.invalidContents }
            return ProfileBackupRevision(id: id, createdAt: revision.createdAt, runtime: text, source: source)
        }
    }
    public func backupSnapshot() throws -> ProfileBackupSnapshot {
        let profiles = try list(); try privateDirectory(root)
        guard profiles.count <= 1000 else { throw ProfileBackupFailure.limits }
        var entries: [ProfileBackupEntry] = []
        var bytes = 0
        for profile in profiles {
            try Task.checkCancellation()
            let runtimePath = root.appendingPathComponent(profile.id.uuidString + ".runtime.ovpn")
            if let attributes = try? FileManager.default.attributesOfItem(atPath: runtimePath.path) {
                guard attributes[.type] as? FileAttributeType == .typeRegular else { throw ProfileBackupFailure.invalidContents }
            }
            let entry = try ProfileBackupEntry(profile: profile, source: backupText(root.appendingPathComponent(profile.relativePath)), runtime: runtimeConfig(for: profile), revisions: backupHistory(profile))
            bytes += entry.source.utf8.count + entry.runtime.utf8.count + entry.revisions.reduce(0) { $0 + $1.runtime.utf8.count + ($1.source?.utf8.count ?? 0) }
            guard bytes <= EncryptedProfileBackup.maximumPlaintextBytes else { throw ProfileBackupFailure.limits }
            entries.append(entry)
        }
        let result = ProfileBackupSnapshot(entries: entries); try result.validate(); return result
    }
    /// Expected metadata binds confirmation to the library displayed in preview.
    /// All restored IDs are fresh; archive paths are never used for destinations.
    public func restoreBackup(_ snapshot: ProfileBackupSnapshot, expecting expected: [VPNProfile]) throws -> [VPNProfile] {
        try snapshot.validate()
        let current = try list(); try privateDirectory(root)
        guard current == expected else { throw ProfileBackupFailure.staleLibrary }
        guard current.count + snapshot.entries.count <= 10_000 else { throw ProfileBackupFailure.limits }
        guard !snapshot.entries.isEmpty else { return [] }
        let restored = snapshot.entries.map { entry -> VPNProfile in
            let p = entry.profile
            let id = UUID()
            return VPNProfile(id: id, name: p.name, sourceFilename: p.sourceFilename, relativePath: id.uuidString + ".ovpn",
                mode: p.mode, importedAt: p.importedAt, group: p.group, notes: p.notes, isFavorite: p.isFavorite, customRules: p.customRules)
        }
        for p in restored {
            for path in [root.appendingPathComponent(p.relativePath), root.appendingPathComponent(p.id.uuidString + ".runtime.ovpn"), historyDirectory(for: p.id)] {
                guard !FileManager.default.fileExists(atPath: path.path), (try? FileManager.default.attributesOfItem(atPath: path.path)) == nil else { throw ProfileBackupFailure.pendingRecovery }
            }
        }
        let stageID = UUID()
        // Use the same ID for the private stage path and its durable receipt.
        let stagePath = root.appendingPathComponent("BackupRestore-" + stageID.uuidString)
        guard (try? FileManager.default.attributesOfItem(atPath: stagePath.path)) == nil else { throw ProfileBackupFailure.pendingRecovery }
        let journal = BackupRestoreJournal(schemaVersion: 1, ids: restored.map(\.id), stageID: stageID)
        try ProfileFileIO.write(JSONEncoder().encode(journal), to: restoreJournal)
        do {
            try privateDirectory(stagePath, create: true)
            for (entry, profile) in zip(snapshot.entries, restored) {
                try Task.checkCancellation()
                try ProfileFileIO.write(Data(entry.source.utf8), to: stagePath.appendingPathComponent(profile.relativePath))
                try ProfileFileIO.write(Data(entry.runtime.utf8), to: stagePath.appendingPathComponent(profile.id.uuidString + ".runtime.ovpn"))
                if !entry.revisions.isEmpty {
                    try privateDirectory(stagePath.appendingPathComponent("History"), create: true)
                    let history = stagePath.appendingPathComponent("History/" + profile.id.uuidString); try privateDirectory(history, create: true)
                    for revision in entry.revisions {
                        try Task.checkCancellation()
                        let path = history.appendingPathComponent(revision.id.uuidString + ".ovpn")
                        try ProfileFileIO.write(Data(revision.runtime.utf8), to: path)
                        try FileManager.default.setAttributes([.modificationDate: revision.createdAt], ofItemAtPath: path.path)
                        if let source = revision.source { try ProfileFileIO.write(Data(source.utf8), to: history.appendingPathComponent(revision.id.uuidString + ".source.ovpn")) }
                    }
                }
            }
            for profile in restored {
                try Task.checkCancellation()
                for name in [profile.relativePath, profile.id.uuidString + ".runtime.ovpn"] {
                    try FileManager.default.moveItem(at: stagePath.appendingPathComponent(name), to: root.appendingPathComponent(name))
                }
                let stagedHistory = stagePath.appendingPathComponent("History/" + profile.id.uuidString)
                if FileManager.default.fileExists(atPath: stagedHistory.path) {
                    try privateDirectory(root.appendingPathComponent("History"), create: true)
                    try FileManager.default.moveItem(at: stagedHistory, to: historyDirectory(for: profile.id))
                }
            }
            try Task.checkCancellation()
            try index.save(current + restored, beforeCommit: { try Task.checkCancellation() }) // Single publication.
        } catch {
            try? recoverBackupRestore()
            throw error
        }
        try? recoverBackupRestore()
        return restored
    }
    private func recoverBackupRestore() throws {
        guard (try? FileManager.default.attributesOfItem(atPath: restoreJournal.path)) != nil else { return }
        try privateDirectory(root)
        let journal: BackupRestoreJournal
        do {
            journal = try JSONDecoder().decode(BackupRestoreJournal.self, from: ProfileFileIO.read(restoreJournal, maximumBytes: 100_000))
            guard journal.schemaVersion == 1, !journal.ids.isEmpty, journal.ids.count <= 1000,
                  Set(journal.ids).count == journal.ids.count else { throw ProfileBackupFailure.pendingRecovery }
        } catch { throw ProfileBackupFailure.pendingRecovery }
        // A damaged primary is never treated as an empty list. The existing
        // index-recovery flow may repair it before this cleanup is retried.
        let referenced = Set(try index.list().map(\.id))
        for id in journal.ids where !referenced.contains(id) {
            for filename in [id.uuidString + ".ovpn", id.uuidString + ".runtime.ovpn"] {
                let path = root.appendingPathComponent(filename)
                if let attributes = try? FileManager.default.attributesOfItem(atPath: path.path) {
                    guard attributes[.type] as? FileAttributeType == .typeRegular else { throw ProfileBackupFailure.pendingRecovery }
                    try FileManager.default.removeItem(at: path)
                }
            }
            let parent = root.appendingPathComponent("History")
            if FileManager.default.fileExists(atPath: parent.path) { try privateDirectory(parent) }
            let history = historyDirectory(for: id)
            if (try? FileManager.default.attributesOfItem(atPath: history.path)) != nil {
                try privateDirectory(history)
                let children = try FileManager.default.contentsOfDirectory(at: history, includingPropertiesForKeys: nil)
                for path in children {
                    let name = path.lastPathComponent.replacingOccurrences(of: ".source.ovpn", with: ".ovpn")
                    guard name.hasSuffix(".ovpn"), UUID(uuidString: String(name.dropLast(5))) != nil,
                          (try FileManager.default.attributesOfItem(atPath: path.path))[.type] as? FileAttributeType == .typeRegular else { throw ProfileBackupFailure.pendingRecovery }
                }
                try FileManager.default.removeItem(at: history)
            }
        }
        if let id = journal.stageID {
            let stage = root.appendingPathComponent("BackupRestore-" + id.uuidString)
            if (try? FileManager.default.attributesOfItem(atPath: stage.path)) != nil {
                try privateDirectory(stage)
                var count = 0
                func validateStage(_ path: URL, depth: Int) throws {
                    guard depth <= 4 else { throw ProfileBackupFailure.pendingRecovery }
                    count += 1; guard count <= 30_000 else { throw ProfileBackupFailure.pendingRecovery }
                    let type = try FileManager.default.attributesOfItem(atPath: path.path)[.type] as? FileAttributeType
                    if type == .typeDirectory {
                        try privateDirectory(path)
                        for child in try FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil) { try validateStage(child, depth: depth + 1) }
                    } else if type != .typeRegular { throw ProfileBackupFailure.pendingRecovery }
                }
                try validateStage(stage, depth: 0)
                try FileManager.default.removeItem(at: stage)
            }
        }
        try FileManager.default.removeItem(at: restoreJournal)
    }
}
