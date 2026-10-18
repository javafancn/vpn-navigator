#if DEBUG
import Foundation
import VPNNavigatorCore

enum ManagementSocketSelfTest {
    private final class Results: @unchecked Sendable {
        let lock = NSLock()
        var challenges = 0, failures = 0, unsupported = 0, errors = 0
        var authenticating = 0, connected = 0, traffic = 0, exits = 0
        func update(_ work: (Results) -> Void) { lock.lock(); defer { lock.unlock() }; work(self) }
    }
    static func run(path: String, scenario: String) throws {
        let socket = ManagementSocket(), result = Results(), ended = DispatchSemaphore(value: 0), responses = DispatchGroup()
        socket.setCredentials(username: "fixture-user", password: "fixture-password")
        socket.onState = { state in
            result.update {
                if state.state == .authenticating { $0.authenticating += 1 }
                if state.state == .connected { $0.connected += 1 }
                if state.state == .reconnecting { $0.errors += 1 }
            }
        }
        socket.onTraffic = { sample in
            result.update { if sample.receivedBytes == 100 && sample.sentBytes == 200 { $0.traffic += 1 } else { $0.errors += 1 } }
        }
        socket.onAuthenticationFailure = { result.update { $0.failures += 1 } }
        socket.onUnsupportedChallenge = { result.update { $0.unsupported += 1 } }
        socket.onChallenge = { challenge in
            result.update { $0.challenges += 1 }
            responses.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { responses.leave() }
                if scenario == "cancel" { socket.close(); return }
                do {
                    do { try socket.respond(id: UUID().uuidString, response: "stale"); result.update { $0.errors += 1 } }
                    catch ChallengeResponseError.stale { }
                    let value = challenge.kind == .privateKey ? "fixture-key" : (challenge.responseRequired ? "8675309" : "")
                    try socket.respond(id: challenge.id.uuidString, response: value)
                    do { try socket.respond(id: challenge.id.uuidString, response: "reused"); result.update { $0.errors += 1 } }
                    catch ChallengeResponseError.stale { }
                } catch { result.update { $0.errors += 1 }; socket.close() }
            }
        }
        socket.onExit = { result.update { $0.exits += 1 }; ended.signal() }
        try socket.open(path: path)
        if scenario == "idle-cancel" { DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { socket.close() } }
        guard ended.wait(timeout: .now() + 7) == .success else { socket.close(); throw ManagementError.unavailable }
        guard responses.wait(timeout: .now() + 2) == .success else { throw ManagementError.socket }
        var valid = false
        result.update {
            let base = $0.errors == 0 && $0.exits == 1
            switch scenario {
            case "happy": valid = base && $0.challenges == 7 && $0.authenticating == 2 && $0.connected == 1 && $0.traffic == 1 && $0.failures == 0 && $0.unsupported == 0
            case "invalid": valid = base && $0.challenges == 0 && $0.failures == 1 && $0.unsupported == 0
            case "unsupported": valid = base && $0.challenges == 0 && $0.failures == 0 && $0.unsupported == 1
            case "cancel": valid = base && $0.challenges == 1 && $0.failures == 0 && $0.unsupported == 0
            case "idle-cancel": valid = base && $0.challenges == 0 && $0.failures == 0 && $0.unsupported == 0
            default: valid = false
            }
        }
        guard valid else { throw ManagementError.socket }
        do { try socket.open(path: path); throw ManagementError.socket }
        catch ManagementError.badPath { }
    }
}
#endif
