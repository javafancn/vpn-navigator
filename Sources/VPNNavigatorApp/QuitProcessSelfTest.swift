import AppKit
import Darwin
import VPNNavigatorCore

/// Installed-system CI uses the real NSApplication delegate and authenticated
/// root helper. The parent fixture independently observes process disappearance.
@MainActor
enum QuitProcessSelfTest {
    private static var started = false
    static func trace(_ message: String) {
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",
              ProcessInfo.processInfo.arguments.contains("--vpnnav-quit-process-self-test") else { return }
        FileHandle.standardError.write(Data(("Quit fixture: " + message + "\n").utf8))
    }
    static func verifyRejection() async throws {
        guard BuildChannel.isLocal, ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" else { throw LocalInstallError.unsafe }
        let client = HelperClient.shared
        var refused = false
        do { try await client.stopForApplicationQuit() }
        catch { refused = true }
        client.resumeAfterCancelledQuit()
        guard refused, await client.ping() == "VPN Navigator Helper (local)" else { throw LocalInstallError.command }
        print("PASS: unsafe direct helper exit refused and authenticated requests resumed after cancellation.")
    }
    static func start(model: AppModel) {
        guard !started, BuildChannel.isLocal,
              ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" else { return }
        started = true
        trace("main scene ready")
        Task {
            for tick in 0..<100 {
                await model.refreshConnectionStatus()
                if tick % 20 == 0 { trace("startup ready=\(model.profileOpenReady), state=\(model.sessionState.rawValue)") }
                if model.profileOpenReady && !model.backgroundServicesBusy && !model.maintenanceInProgress && (model.connected || model.canQuit) {
                    print("Quit fixture: real application termination requested")
                    fflush(stdout)
                    NSApp.terminate(nil)
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            print("Quit fixture failed to verify startup")
            Darwin.exit(1)
        }
    }
}
