import AppKit
import VPNNavigatorCore

/// Cmd-Q and menu-bar Quit share one asynchronous shutdown path. A failed
/// disconnect must not silently abandon an unresolved owned session.
@MainActor
final class ApplicationLifecycle: NSObject, NSApplicationDelegate {
    weak var model: AppModel? {
        didSet {
            guard let model, !pendingProfiles.isEmpty else { return }
            let request = pendingProfiles; pendingProfiles.clear()
            model.receiveProfileOpenRequest(request)
        }
    }
    private var pendingProfiles = ProfileOpenQueue()
    private var quitting = false
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { model?.quickAccess.openMainWindow() }
        return true
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        var request = ProfileOpenQueue(); request.append(urls)
        if let model { model.receiveProfileOpenRequest(request) }
        else { pendingProfiles.merge(request) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { model?.profileHealth.stop(); model?.smartConnection.stop(); model?.quickAccess.shutdown() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        QuitProcessSelfTest.trace("termination delegate reached")
        guard let model else { return .terminateNow }
        guard !model.maintenanceInProgress, !model.backgroundServicesBusy, !model.profileTransferInProgress,
              !model.routingModeSwitching else {
            QuitProcessSelfTest.trace("termination blocked by an operation in progress")
            return .terminateCancel
        }
        guard !quitting else { return .terminateCancel }
        guard model.beginApplicationQuit() else { return .terminateCancel }
        quitting = true
        let repairExit = model.allowInstallationRepairExit
        let flushHistory = model.connectionHistory.takeQuitFlusher()
        Task.detached {
            let result = await HelperClient.shared.prepareApplicationQuit(allowInstallationRepairExit: repairExit)
            await flushHistory(result.report)
            // terminateLater changes the run-loop mode. MainActor Tasks/main
            // dispatch alone do not progress there; use its explicit modes.
            RunLoop.main.perform(inModes: [.modalPanel, .default, .eventTracking]) {
                MainActor.assumeIsolated {
                    model.finishApplicationQuit(result)
                    self.quitting = false
                    QuitProcessSelfTest.trace(result.succeeded ? "termination approved" : "termination cancelled")
                    if !result.succeeded { model.quickAccess.openMainWindow() }
                    sender.reply(toApplicationShouldTerminate: result.succeeded)
                }
            }
        }
        return .terminateLater
    }
}
