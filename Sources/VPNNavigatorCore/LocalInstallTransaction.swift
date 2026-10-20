import Foundation

/// An administrator-created barrier, persisted before package extraction.
/// No paths, commands, credentials or network recovery data are stored here.
public struct LocalInstallTransaction: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case preparing, verifying, repairRequired }
    public let schema: Int
    public let version: String
    public let architecture: String
    public var phase: Phase
    public init(version: String, architecture: String, phase: Phase) {
        schema = 1; self.version = version; self.architecture = architecture; self.phase = phase
    }
    public func validate() throws {
        guard schema == 1, version.count < 32,
              version.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil,
              ["arm64", "x86_64"].contains(architecture) else { throw LocalInstallError.invalid }
    }
    public func matches(version: String, architecture: String) -> Bool {
        do { try validate(); return self.version == version && self.architecture == architecture }
        catch { return false }
    }
    public var summary: String {
        switch phase {
        case .preparing: return "安装尚未完成。若系统安装器仍在运行，请等待；否则选择可信安装包修复。"
        case .verifying: return "正在核验后台助手。若安装已中断，请选择可信安装包修复。"
        case .repairRequired: return "上次安装未能完成健康检查，请通过可信安装包重新修复。"
        }
    }
}
