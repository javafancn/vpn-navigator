import Foundation
import CryptoKit
import Darwin

public struct ProfileIndexBackupInfo: Sendable {
    public let savedAt: Date
    public let profileCount: Int
    public let matchesCurrentIndex: Bool
}

/// An explicit recovery confirmation is bound to both files, including absence.
public struct ProfileIndexRecoveryPreview: Equatable, Sendable {
    public let savedAt: Date
    public let profiles: [VPNProfile]
    let backupDigest: String
    let damagedDigest: String?
}

public enum ProfileIndexFailure: Error, LocalizedError {
    case invalidIndex, missingIndex, noBackup, invalidBackup, recoveryNotNeeded, stalePreview, missingConfiguration
    public var errorDescription: String? {
        switch self {
        case .invalidIndex: return "配置列表损坏，已有配置文件已保留。请查看配置列表恢复。"
        case .missingIndex: return "配置列表缺失，但本机仍有备份。请先恢复列表，再导入新配置。"
        case .noBackup: return "尚无可用的配置列表备份。请从原始 .ovpn 文件重新导入。"
        case .invalidBackup: return "配置列表备份无法通过校验，未修改任何文件。"
        case .recoveryNotNeeded: return "当前配置列表可正常读取，无需恢复。"
        case .stalePreview: return "配置列表或备份已改变，请重新检查后再确认恢复。"
        case .missingConfiguration: return "备份引用的配置文件缺失或无法安全读取，不能恢复该列表。请保留现状并重新导入原始配置。"
        }
    }
}

/// Only metadata is checkpointed. Canonical configuration and revision files
/// remain in place; credentials are never copied into this checkpoint.
struct ProfileIndexRepository {
    static let maximumBytes = 16_000_000
    let root: URL
    private var indexURL: URL { root.appendingPathComponent("profiles.json") }
    private var backupURL: URL { root.appendingPathComponent("profiles.backup.json") }
    private struct Checkpoint: Codable {
        let schemaVersion: Int
        let savedAt: Date
        let profiles: [VPNProfile]
    }
    private func existingData(_ url: URL) throws -> Data? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw ProfileFileIO.Failure.unreadable
        }
        return try ProfileFileIO.read(url, maximumBytes: Self.maximumBytes)
    }
    private func validate(_ profiles: [VPNProfile]) throws {
        for profile in profiles { _ = try CustomRuleSet(profile.customRules) }
        guard profiles.count <= 10_000, Set(profiles.map(\.id)).count == profiles.count,
              profiles.allSatisfy({ $0.relativePath == "\($0.id.uuidString).ovpn" && $0.importedAt.timeIntervalSince1970.isFinite }) else {
            throw ProfileIndexFailure.invalidIndex
        }
    }
    private func decode(_ data: Data) throws -> [VPNProfile] {
        do {
            let profiles = try JSONDecoder().decode([VPNProfile].self, from: data)
            try validate(profiles)
            return profiles
        } catch { throw ProfileIndexFailure.invalidIndex }
    }
    private func checkpoint() throws -> (Checkpoint, Data) {
        guard let data = try existingData(backupURL) else { throw ProfileIndexFailure.noBackup }
        do {
            let value = try JSONDecoder().decode(Checkpoint.self, from: data)
            guard value.schemaVersion == 1, value.savedAt.timeIntervalSince1970.isFinite else { throw ProfileIndexFailure.invalidBackup }
            try validate(value.profiles)
            return (value, data)
        } catch { throw ProfileIndexFailure.invalidBackup }
    }
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= Self.maximumBytes else { throw ProfileFileIO.Failure.tooLarge }
        return data
    }
    private func digest(_ data: Data?) -> String? {
        data.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
    }
    func list() throws -> [VPNProfile] {
        guard let data = try existingData(indexURL) else {
            // A dangling link or special file is never treated as an empty store.
            if try existingData(backupURL) != nil { throw ProfileIndexFailure.missingIndex }
            return []
        }
        let profiles = try decode(data)
        // Migrate an existing healthy store lazily. A failed checkpoint must not
        // make an already committed import appear to have failed.
        var info = stat()
        if lstat(backupURL.path, &info) != 0, errno == ENOENT { try? writeCheckpoint(profiles) }
        return profiles
    }
    func save(_ profiles: [VPNProfile], beforeCommit: (() throws -> Void)? = nil) throws {
        try validate(profiles)
        try ProfileFileIO.write(encode(profiles), to: indexURL, beforeCommit: beforeCommit)
        // Primary publication is the commit point. Report checkpoint health
        // separately: throwing here would let the importer delete committed files.
        try? writeCheckpoint(profiles)
    }
    private func writeCheckpoint(_ profiles: [VPNProfile]) throws {
        try ProfileFileIO.write(encode(Checkpoint(schemaVersion: 1, savedAt: Date(), profiles: profiles)), to: backupURL)
    }
    func refreshBackup() throws {
        if let bytes = try existingData(indexURL) {
            try writeCheckpoint(decode(bytes))
        } else {
            // A genuinely new, empty repository has no primary file yet.
            // list() still refuses a missing primary when any backup exists.
            let profiles = try list()
            try ProfileFileIO.write(encode(profiles), to: indexURL)
            try writeCheckpoint(profiles)
        }
    }
    func backupInfo() throws -> ProfileIndexBackupInfo {
        let (value, _) = try checkpoint()
        let current = try existingData(indexURL).flatMap { try? decode($0) }
        return .init(savedAt: value.savedAt, profileCount: value.profiles.count, matchesCurrentIndex: current == value.profiles)
    }
    func recoveryPreview() throws -> ProfileIndexRecoveryPreview {
        let damaged = try existingData(indexURL)
        if let damaged, (try? decode(damaged)) != nil { throw ProfileIndexFailure.recoveryNotNeeded }
        let (value, bytes) = try checkpoint()
        // Restore the whole list only when every referenced source is available.
        // Never silently drop entries or reintroduce paths from untrusted JSON.
        for profile in value.profiles {
            do {
                _ = try ProfileFileIO.read(root.appendingPathComponent(profile.relativePath))
                let runtime = root.appendingPathComponent("\(profile.id.uuidString).runtime.ovpn")
                var info = stat()
                if lstat(runtime.path, &info) == 0 { _ = try ProfileFileIO.read(runtime) }
                else if errno != ENOENT { throw ProfileIndexFailure.missingConfiguration }
            } catch { throw ProfileIndexFailure.missingConfiguration }
        }
        return .init(savedAt: value.savedAt, profiles: value.profiles,
                     backupDigest: digest(bytes)!, damagedDigest: digest(damaged))
    }
    func recover(_ expected: ProfileIndexRecoveryPreview) throws {
        let fresh = try recoveryPreview()
        guard fresh.backupDigest == expected.backupDigest, fresh.damagedDigest == expected.damagedDigest else {
            throw ProfileIndexFailure.stalePreview
        }
        let damaged = try existingData(indexURL)
        guard digest(damaged) == expected.damagedDigest else { throw ProfileIndexFailure.stalePreview }
        if let damaged {
            try ProfileFileIO.write(damaged, to: root.appendingPathComponent("profiles-damaged-\(UUID().uuidString).json"))
        }
        try ProfileFileIO.write(encode(fresh.profiles), to: indexURL)
    }
}
