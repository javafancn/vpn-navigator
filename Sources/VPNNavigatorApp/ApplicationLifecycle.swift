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
        quitting = true
        Task {
            let finished = await model.prepareApplicationQuit()
            QuitProcessSelfTest.trace(finished ? "termination approved" : "termination cancelled")
            quitting = false
            if !finished { model.quickAccess.openMainWindow() }
            sender.reply(toApplicationShouldTerminate: finished)
        }
        return .terminateLater
    }
}
