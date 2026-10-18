import Foundation

/// Legacy CRV1 context stays in the helper. Only id, prompt and input policy
/// belong in SessionReport; no state identifier or encoded account is exported.
struct DynamicAuthenticationChallenge {
    let presentation: AuthenticationChallenge
    let username: String
    let state: String

    static func parse(_ line: String) -> Self? {
        let prefixes = [">PASSWORD:Verification Failed: 'Auth' ['", ">PASSWORD:Verification Failed: ['"]
        guard line.utf8.count <= 8192, let prefix = prefixes.first(where: { line.hasPrefix($0) }),
              line.hasSuffix("']") else { return nil }
        let text = line.dropFirst(prefix.count).dropLast(2)
        let fields = text.split(separator: ":", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 5, fields[0] == "CRV1" else { return nil }
        let flags = fields[1].isEmpty ? [] : fields[1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard Set(flags).count == flags.count, flags.allSatisfy({ ["R", "E"].contains($0) }),
              !fields[2].isEmpty, fields[2].utf8.count <= 512,
              !fields[4].isEmpty, fields[4].utf8.count <= 512,
              fields[3].utf8.count <= 1368,
              let decoded = Data(base64Encoded: fields[3]), decoded.base64EncodedString() == fields[3],
              let username = String(data: decoded, encoding: .utf8), !username.isEmpty,
              ManagementCredentialPolicy.allows(username: username, password: fields[2], credentialsRequired: false),
              ManagementCredentialPolicy.allows(username: "", password: fields[4], credentialsRequired: false) else { return nil }
        return .init(presentation: .init(kind: .dynamicOTP, prompt: fields[4], responseRequired: flags.contains("R")),
                     username: username, state: fields[2])
    }
    func commands(response: String) throws -> [String] {
        guard response.utf8.count <= 1024,
              presentation.responseRequired ? !response.isEmpty : response.isEmpty,
              ManagementCredentialPolicy.allows(username: "", password: response, credentialsRequired: false) else {
            throw ChallengeResponseError.invalid
        }
        return ["username \"Auth\" \"\(ManagementEscaping.escape(username))\"",
                "password \"Auth\" \"\(ManagementEscaping.escape("CRV1::" + state + "::" + response))\""]
    }
}

/// Serialized by ManagementSocket. A challenge is actionable only after the
/// next Need Auth request; invalid failures never fall back to the saved secret.
public struct ManagementAuthentication {
    public enum Event { case commands([String]), challenge(AuthenticationChallenge), failed, unsupported }
    private var credentials: (username: String, password: String)?
    private var pending: AuthenticationChallenge?
    private var dynamic: DynamicAuthenticationChallenge?
    private var awaitingAuthRequest = false
    private var dynamicRounds = 0
    private var connectedBefore = false
    public init() { }
    public mutating func setCredentials(username: String, password: String) {
        credentials = ManagementCredentialPolicy.allows(username: username, password: password, credentialsRequired: true) ? (username, password) : nil
    }
    public mutating func receive(_ line: String) -> Event? {
        if line.hasPrefix(">PASSWORD:Verification Failed:") {
            pending = nil; dynamic = nil; awaitingAuthRequest = false
            guard !connectedBefore, dynamicRounds < 3, let value = DynamicAuthenticationChallenge.parse(line) else { return .failed }
            dynamicRounds += 1; dynamic = value; awaitingAuthRequest = true
            return nil
        }
        guard line.hasPrefix(">PASSWORD:Need ") else { return nil }
        // A reconnect can ask to unlock the local key before requesting the
        // next server factor. Preserve the independent CRV1 context.
        if let value = AuthenticationChallenge.parse(line), value.kind == .privateKey {
            pending = value; return .challenge(value)
        }
        if let dynamic {
            guard line == ">PASSWORD:Need 'Auth' username/password" else { return .unsupported }
            awaitingAuthRequest = false; pending = dynamic.presentation
            return .challenge(dynamic.presentation)
        }
        if let value = AuthenticationChallenge.parse(line) {
            pending = value; return .challenge(value)
        }
        guard line == ">PASSWORD:Need 'Auth' username/password", let credentials else { return .unsupported }
        return .commands(["username \"Auth\" \"\(ManagementEscaping.escape(credentials.username))\"",
                          "password \"Auth\" \"\(ManagementEscaping.escape(credentials.password))\""])
    }
    public mutating func respond(id: String, response: String) throws -> [String] {
        guard let pending, pending.id.uuidString == id else { throw ChallengeResponseError.stale }
        let commands: [String]
        if pending.kind == .dynamicOTP {
            guard let dynamic, !awaitingAuthRequest else { throw ChallengeResponseError.stale }
            commands = try dynamic.commands(response: response)
        }
        else {
            let password = try pending.responseCommand(response: response, accountPassword: credentials?.password ?? "")
            if pending.kind == .staticOTP {
                guard let credentials else { throw ChallengeResponseError.invalid }
                commands = ["username \"Auth\" \"\(ManagementEscaping.escape(credentials.username))\"", password]
            } else { commands = [password] }
        }
        self.pending = nil
        if pending.kind == .dynamicOTP { dynamic = nil }
        return commands
    }
    public mutating func transition(_ snapshot: TunnelSnapshot) -> TunnelSnapshot {
        if snapshot.state == .connected { connectedBefore = true; pending = nil; dynamic = nil; awaitingAuthRequest = false }
        // CRV1 intentionally restarts the initial auth attempt. Do not route
        // this through the managed transport reconnect path. The original
        // overall attempt deadline and pre-tunnel PF policy remain in force.
        if !connectedBefore, dynamic != nil, awaitingAuthRequest,
           snapshot.state == .reconnecting, snapshot.message == "auth-failure" {
            return TunnelSnapshot(state: .authenticating, remoteIPv4: nil, localTunnelIPv4: nil, message: "等待动态身份验证")
        }
        return snapshot
    }
    public static let openVPNArguments = ["--auth-retry", "interact"]
}
