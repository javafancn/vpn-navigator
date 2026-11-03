import Foundation
import Security

/// Immutable identity of this running executable, read once per process.
/// Approval records and peer requirements are still checked independently.
public struct ProcessSigningIdentity: Sendable {
    public let identifier: String
    public let cdhash: String
    public let team: String?
    public static let current: Self? = {
        var code: SecCode?, staticCode: SecStaticCode?, info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
              let values = info as? [String: Any],
              let identifier = values[kSecCodeInfoIdentifier as String] as? String,
              let hash = values[kSecCodeInfoUnique as String] as? Data else { return nil }
        return .init(identifier: identifier, cdhash: hash.map { String(format: "%02x", $0) }.joined(),
                     team: values[kSecCodeInfoTeamIdentifier as String] as? String)
    }()
}
