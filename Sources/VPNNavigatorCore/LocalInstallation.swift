import Foundation
import Security
import CryptoKit
import Darwin

public enum BuildChannel {
    public static var isLocal: Bool {
        #if VPNNAV_LOCAL_TEST
        return true
        #else
        return false
        #endif
    }
    public static var label: String { isLocal ? "本地测试版（未公证）" : "签名发布 / UI 预览" }
}

public enum LocalRole: String, Codable, CaseIterable, Sendable {
    case app, helper, agent, engine, setup
    public var file: String {
        switch self {
        case .app: return "VPNNavigatorApp"
        case .helper: return "VPNNavigatorHelper"
        case .agent: return "VPNNavigatorRuleAgent"
        case .engine: return "openvpn"
        case .setup: return "VPNNavigatorLocalSetup"
        }
    }
    public var identifier: String {
        switch self {
        case .app: return "com.javafancn.vpn-navigator"
        case .helper: return "com.javafancn.vpn-navigator.helper"
        case .agent: return "com.javafancn.vpn-navigator.rule-agent"
        case .engine: return "com.javafancn.vpn-navigator.openvpn"
        case .setup: return "com.javafancn.vpn-navigator.local-setup"
        }
    }
}
public struct LocalBinary: Codable, Equatable, Sendable {
    public let sha256: String
    public let cdhash: String
    public let identifier: String
    public init(sha256: String, cdhash: String, identifier: String) {
        self.sha256 = sha256; self.cdhash = cdhash; self.identifier = identifier
    }
}
public struct LocalApproval: Codable, Equatable, Sendable {
    public let schema: Int
    public let version: String
    public let architecture: String
    public var ownerUID: UInt32
    public let binaries: [String: LocalBinary]
    public let uninstallerSHA256: String
    public let dnsSHA256: String
    public init(version: String, architecture: String, ownerUID: UInt32, binaries: [String: LocalBinary], dnsSHA256: String, uninstallerSHA256: String) {
        schema = 1; self.version = version; self.architecture = architecture; self.ownerUID = ownerUID
        self.binaries = binaries; self.dnsSHA256 = dnsSHA256; self.uninstallerSHA256 = uninstallerSHA256
    }
    public func validate() throws {
        guard schema == 1, version.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil,
              version.count < 32, ["arm64", "x86_64"].contains(architecture), ownerUID >= 500,
              Set(binaries.keys) == Set(LocalRole.allCases.map(\.rawValue)), Self.hex(dnsSHA256, 64), Self.hex(uninstallerSHA256, 64) else { throw LocalInstallError.invalid }
        for role in LocalRole.allCases {
            guard let binary = binaries[role.rawValue], binary.identifier == role.identifier,
                  Self.hex(binary.sha256, 64), Self.hex(binary.cdhash, 40) else { throw LocalInstallError.invalid }
        }
    }
    public func requirement(for roles: [LocalRole]) throws -> String {
        try validate()
        guard !roles.isEmpty else { throw LocalInstallError.invalid }
        return try roles.map { role in
            guard let binary = binaries[role.rawValue] else { throw LocalInstallError.invalid }
            return "(identifier \"\(role.identifier)\" and cdhash H\"\(binary.cdhash)\")"
        }.joined(separator: " or ")
    }
    private static func hex(_ value: String, _ count: Int) -> Bool {
        value.count == count && value.allSatisfy { $0.isASCII && ($0.isNumber || ("a"..."f").contains(String($0))) }
    }
}
public enum LocalInstallError: Error, LocalizedError {
    case invalid, unsafe, altered, notInstalled, rootRequired, recoveryRequired, command
    public var errorDescription: String? {
        switch self {
        case .invalid: return "本地安装批准记录无效。"
        case .unsafe: return "本地程序目录或权限不符合要求，请重新安装本地测试包。"
        case .altered: return "本地程序与批准版本不一致，请重新运行可信安装包修复。"
        case .notInstalled: return "请先安装包含引擎的本地测试 PKG。"
        case .rootRequired: return "此安装操作需要系统安装器授予管理员权限。"
        case .recoveryRequired: return "VPN 会话或网络恢复尚未完成，请先断开并执行安全恢复。"
        case .command: return "后台服务操作未完成，请检查安装状态。"
        }
    }
}
public enum LocalInstallation {
    public static let root = URL(fileURLWithPath: "/Library/Application Support/VPNNavigator/Local", isDirectory: true)
    public static let payload = root.appendingPathComponent("Payload", isDirectory: true)
    public static let manifest = root.appendingPathComponent("manifest.json")
    public static let retired = root.appendingPathComponent("retired-approval.json")
    public static let uninstaller = payload.appendingPathComponent("VPNNavigator-Uninstall.pkg")
    public static let template = payload.appendingPathComponent("approval-template.json")
    public static let daemonLabel = "com.javafancn.vpn-navigator.local-helper"
    public static let daemonPlist = URL(fileURLWithPath: "/Library/LaunchDaemons/\(daemonLabel).plist")
    public static let app = URL(fileURLWithPath: "/Applications/VPN Navigator.app", isDirectory: true)
    public static func executable(_ role: LocalRole) -> URL {
        role == .app ? app.appendingPathComponent("Contents/MacOS/\(role.file)") : payload.appendingPathComponent(role.file)
    }
    public static func hash(_ path: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: path); defer { try? handle.close() }
        var digest = SHA256(), size = 0
        while let bytes = try handle.read(upToCount: 65_536), !bytes.isEmpty {
            size += bytes.count; guard size < 256_000_000 else { throw LocalInstallError.invalid }
            digest.update(data: bytes)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func binary(_ path: URL, role: LocalRole) throws -> LocalBinary {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(path as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else { throw LocalInstallError.altered }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
              let values = info as? [String: Any], let cdhash = values[kSecCodeInfoUnique as String] as? Data,
              values[kSecCodeInfoIdentifier as String] as? String == role.identifier,
              let flags = values[kSecCodeInfoFlags as String] as? NSNumber,
              flags.uint32Value & 0x10000 != 0, flags.uint32Value & 0x2 != 0 else { throw LocalInstallError.altered }
        return LocalBinary(sha256: try hash(path), cdhash: cdhash.map { String(format: "%02x", $0) }.joined(), identifier: role.identifier)
    }
    public static func protected(_ path: URL, directory: Bool = false) throws {
        guard path.standardizedFileURL == path.resolvingSymlinksInPath(),
              let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
              attrs[.type] as? FileAttributeType == (directory ? .typeDirectory : .typeRegular),
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == 0,
              ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o022 == 0 else { throw LocalInstallError.unsafe }
    }
    public static func protectedRoot() throws {
        for path in ["/Library", "/Library/Application Support", "/Library/Application Support/VPNNavigator", root.path, payload.path] {
            try protected(URL(fileURLWithPath: path), directory: true)
        }
    }
    public static func decode(_ path: URL) throws -> LocalApproval {
        try protected(path)
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        guard ((attrs[.size] as? NSNumber)?.intValue ?? Int.max) < 32_768 else { throw LocalInstallError.invalid }
        let value = try JSONDecoder().decode(LocalApproval.self, from: Data(contentsOf: path)); try value.validate(); return value
    }
    public static func load(allowRetired: Bool = false) throws -> LocalApproval {
        let record = FileManager.default.fileExists(atPath: manifest.path) ? manifest : (allowRetired ? retired : manifest)
        guard BuildChannel.isLocal, FileManager.default.fileExists(atPath: record.path) else { throw LocalInstallError.notInstalled }
        try protectedRoot()
        let value = try decode(record)
        for role in LocalRole.allCases where role != .app {
            let path = executable(role); try protected(path)
            guard try binary(path, role: role) == value.binaries[role.rawValue] else { throw LocalInstallError.altered }
        }
        let dns = payload.appendingPathComponent("macos-dns-updown.sh"); try protected(dns)
        try protected(uninstaller)
        guard try hash(dns) == value.dnsSHA256, hash(uninstaller) == value.uninstallerSHA256 else { throw LocalInstallError.altered }
        return value
    }
    public static func selfMatches(_ roles: [LocalRole], approval: LocalApproval) -> Bool {
        var code: SecCode?, staticCode: SecStaticCode?, info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
              let values = info as? [String: Any], let hash = values[kSecCodeInfoUnique as String] as? Data else { return false }
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        return roles.contains { approval.binaries[$0.rawValue]?.cdhash == hex && values[kSecCodeInfoIdentifier as String] as? String == $0.identifier }
    }
    public static var hasRecoveryEvidence: Bool {
        let fm = FileManager.default
        return ["routes.journal", "dns.journal", "pf-guard.json", "active.ovpn", "openvpn-child.json"].contains {
            fm.fileExists(atPath: "/var/run/vpn-navigator/\($0)")
        }
    }
    public static func daemonData() throws -> Data {
        let plist: [String: Any] = ["Label": daemonLabel,
            "ProgramArguments": [executable(.helper).path], "RunAtLoad": true,
            "MachServices": [HelperIdentity.machService: true]]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }
    /// Called only by the approved root helper after session cleanup. No paths
    /// or commands come from XPC. launchctl is spawned after its final reply.
    public static func removeApproval() throws {
        guard getuid() == 0 else { throw LocalInstallError.rootRequired }
        _ = try load()
        guard !hasRecoveryEvidence else { throw LocalInstallError.recoveryRequired }
        if FileManager.default.fileExists(atPath: daemonPlist.path) {
            try protected(daemonPlist)
            guard try Data(contentsOf: daemonPlist) == daemonData() else { throw LocalInstallError.altered }
            try FileManager.default.removeItem(at: daemonPlist)
        }
        if FileManager.default.fileExists(atPath: retired.path) { try protected(retired); try FileManager.default.removeItem(at: retired) }
        try FileManager.default.moveItem(at: manifest, to: retired)
    }
}
