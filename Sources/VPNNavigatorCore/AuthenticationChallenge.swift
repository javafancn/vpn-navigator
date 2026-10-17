import Foundation

public struct AuthenticationChallenge: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case privateKey, staticOTP }
    public let id: UUID
    public let kind: Kind
    public let prompt: String
    public init(kind: Kind, prompt: String) {
        id = UUID(); self.kind = kind; self.prompt = prompt
    }
    public static func parse(_ line: String) -> Self? {
        if line == ">PASSWORD:Need 'Private Key' password" {
            return .init(kind: .privateKey, prompt: "输入此配置私钥的解锁密码")
        }
        let prefix = ">PASSWORD:Need 'Auth' username/password SC:"
        guard line.hasPrefix(prefix) else { return nil }
        let parts = line.dropFirst(prefix.count).split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, ["0", "1"].contains(String(parts[0])),
              !parts[1].isEmpty, parts[1].utf8.count <= 512,
              !parts[1].unicodeScalars.contains(where: { CharacterSet.controlCharacters.union(.newlines).contains($0) }) else { return nil }
        // Always use a secure input even if the server requests visible echo.
        return .init(kind: .staticOTP, prompt: String(parts[1]))
    }
    public func responseCommand(response: String, accountPassword: String) throws -> String {
        guard !response.isEmpty, response.utf8.count <= 1024,
              ManagementCredentialPolicy.allows(username: "", password: response, credentialsRequired: false) else {
            throw ChallengeResponseError.invalid
        }
        switch kind {
        case .privateKey:
            return "password \"Private Key\" \"\(ManagementEscaping.escape(response))\""
        case .staticOTP:
            guard !accountPassword.isEmpty,
                  ManagementCredentialPolicy.allows(username: "", password: accountPassword, credentialsRequired: false) else {
                throw ChallengeResponseError.invalid
            }
            let packed = "SCRV1:\(Data(accountPassword.utf8).base64EncodedString()):\(Data(response.utf8).base64EncodedString())"
            return "password \"Auth\" \"\(packed)\""
        }
    }
}
public enum ChallengeResponseError: Error { case invalid, stale }
