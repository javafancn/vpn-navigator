import Foundation
import CryptoKit
import CommonCrypto
import Security

public enum ProfileBackupFailure: Error, LocalizedError {
    case password, unsupported, damaged, limits, invalidContents, staleLibrary, pendingRecovery
    public var errorDescription: String? {
        switch self {
        case .password: return L10n.text("备份密码至少需要 12 个字符，且不能超过 1024 字节。")
        case .unsupported: return L10n.text("文件不是受支持的 VPN Navigator 加密备份。")
        case .damaged: return L10n.text("无法解密：密码不正确或备份文件已损坏。")
        case .limits: return L10n.text("备份超过限制：最多 1000 个配置、每配置 1000 个历史版本，文件不超过 16 MB。请分批导出配置。")
        case .invalidContents: return L10n.text("备份内容无法通过完整性或配置检查，未执行恢复。")
        case .staleLibrary: return L10n.text("配置列表已改变，请重新预览后再确认恢复。")
        case .pendingRecovery: return L10n.text("上次备份恢复记录无法安全核验。配置文件已保留，请先检查配置列表或保留目录进行排障。")
        }
    }
}
public struct ProfileBackupRevision: Codable, Equatable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let runtime: String
    public let source: String?
    public init(id: UUID, createdAt: Date, runtime: String, source: String?) {
        self.id = id; self.createdAt = createdAt; self.runtime = runtime; self.source = source
    }
}
public struct ProfileBackupEntry: Codable, Equatable, Sendable {
    public let profile: VPNProfile
    public let source: String
    public let runtime: String
    public let revisions: [ProfileBackupRevision]
    public init(profile: VPNProfile, source: String, runtime: String, revisions: [ProfileBackupRevision] = []) {
        self.profile = profile; self.source = source; self.runtime = runtime; self.revisions = revisions
    }
}
/// Explicit schema: no Keychain, input fields, app preferences or system journals.
public struct ProfileBackupSnapshot: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let createdAt: Date
    public let entries: [ProfileBackupEntry]
    public init(createdAt: Date = Date(), entries: [ProfileBackupEntry]) {
        schemaVersion = 1; self.createdAt = createdAt; self.entries = entries
    }
    public var revisionCount: Int { entries.reduce(0) { $0 + $1.revisions.count } }
    public func validate() throws {
        guard schemaVersion == 1 else { throw ProfileBackupFailure.unsupported }
        guard createdAt.timeIntervalSince1970.isFinite, entries.count <= 1000,
              Set(entries.map { $0.profile.id }).count == entries.count, revisionCount <= 10_000 else { throw ProfileBackupFailure.limits }
        var bytes = 0
        func configuration(_ value: String, runtime: Bool) throws {
            guard !value.isEmpty, value.utf8.count <= 2_000_000 else { throw ProfileBackupFailure.invalidContents }
            bytes += value.utf8.count
            guard bytes <= EncryptedProfileBackup.maximumPlaintextBytes else { throw ProfileBackupFailure.limits }
            if runtime { do { _ = try ProfileSafety.validate(value) } catch { throw ProfileBackupFailure.invalidContents } }
        }
        for entry in entries {
            try Task.checkCancellation()
            let p = entry.profile
            guard p.relativePath == "\(p.id.uuidString).ovpn", p.importedAt.timeIntervalSince1970.isFinite,
                  !p.name.isEmpty, p.name.utf8.count <= 1024, p.group.utf8.count <= 1024,
                  !p.sourceFilename.isEmpty, p.sourceFilename.utf8.count <= 1024,
                  p.notes.utf8.count <= 16_384,
                  entry.revisions.count <= 1000, Set(entry.revisions.map(\.id)).count == entry.revisions.count else { throw ProfileBackupFailure.invalidContents }
            _ = try CustomRuleSet(p.customRules)
            try configuration(entry.source, runtime: false); try configuration(entry.runtime, runtime: true)
            for revision in entry.revisions {
                guard revision.createdAt.timeIntervalSince1970.isFinite else { throw ProfileBackupFailure.invalidContents }
                try configuration(revision.runtime, runtime: true)
                if let source = revision.source { try configuration(source, runtime: false) }
            }
        }
    }
}

/// Version 1: fixed magic/version/KDF parameters/salt (authenticated header),
/// followed by CryptoKit's nonce + AES-256-GCM ciphertext + authentication tag.
/// No compression and no caller-controlled KDF work factor or plaintext names.
public enum EncryptedProfileBackup {
    public static let maximumBytes = 16_000_000
    public static let maximumPlaintextBytes = 15_900_000
    private static let prefix = Data([0x56,0x50,0x4e,0x4e,0x41,0x56,0x42,0x4b, 1, 0,9,0x27,0xc0]) // VPNNAVBK, v1, 600000 rounds
    private static let saltBytes = 16
    public static func seal(_ snapshot: ProfileBackupSnapshot, password: String) throws -> Data {
        guard password.count >= 12, password.utf8.count <= 1024 else { throw ProfileBackupFailure.password }
        try Task.checkCancellation(); try snapshot.validate()
        let plaintext = try JSONEncoder().encode(snapshot)
        guard plaintext.count <= maximumPlaintextBytes else { throw ProfileBackupFailure.limits }
        var salt = Data(count: saltBytes)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, saltBytes, $0.baseAddress!) }
        guard status == errSecSuccess else { throw ProfileBackupFailure.damaged }
        let header = prefix + salt, key = try derive(password, salt: salt)
        try Task.checkCancellation()
        guard let combined = try AES.GCM.seal(plaintext, using: key, authenticating: header).combined else { throw ProfileBackupFailure.damaged }
        let result = header + combined
        guard result.count <= maximumBytes else { throw ProfileBackupFailure.limits }
        return result
    }
    public static func open(_ archive: Data, password: String) throws -> ProfileBackupSnapshot {
        let headerSize = prefix.count + saltBytes
        guard archive.count <= maximumBytes else { throw ProfileBackupFailure.limits }
        guard archive.count >= headerSize + 28, archive.prefix(prefix.count) == prefix else { throw ProfileBackupFailure.unsupported }
        guard !password.isEmpty, password.utf8.count <= 1024 else { throw ProfileBackupFailure.damaged }
        try Task.checkCancellation()
        let header = Data(archive.prefix(headerSize)), salt = Data(header.suffix(saltBytes))
        let key = try derive(password, salt: salt)
        try Task.checkCancellation()
        let plaintext: Data
        do { plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: archive.dropFirst(headerSize)), using: key, authenticating: header) }
        catch { throw ProfileBackupFailure.damaged }
        guard plaintext.count <= maximumPlaintextBytes else { throw ProfileBackupFailure.limits }
        try Task.checkCancellation()
        let snapshot: ProfileBackupSnapshot
        do { snapshot = try JSONDecoder().decode(ProfileBackupSnapshot.self, from: plaintext); try snapshot.validate() }
        catch is CancellationError { throw CancellationError() }
        catch let error as ProfileBackupFailure { throw error }
        catch { throw ProfileBackupFailure.invalidContents }
        return snapshot
    }
    private static func derive(_ password: String, salt: Data) throws -> SymmetricKey {
        var secret = Array(password.precomposedStringWithCanonicalMapping.utf8), bytes = [UInt8](repeating: 0, count: 32)
        defer { _ = secret.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }; _ = bytes.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        let status = secret.withUnsafeBytes { input in salt.withUnsafeBytes { salt in bytes.withUnsafeMutableBytes { output in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), input.baseAddress!.assumingMemoryBound(to: Int8.self), input.count,
                salt.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                600_000, output.baseAddress!.assumingMemoryBound(to: UInt8.self), output.count)
        } } }
        guard status == kCCSuccess else { throw ProfileBackupFailure.damaged }
        return SymmetricKey(data: bytes)
    }
}
