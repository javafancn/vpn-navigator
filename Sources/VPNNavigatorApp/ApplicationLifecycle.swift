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
        guard let model else { return .terminateNow }
        guard !model.maintenanceInProgress, !model.backgroundServicesBusy, !model.profileTransferInProgress,
              !model.routingModeSwitching else { return .terminateCancel }
        guard !model.canQuit else { return .terminateNow }
        guard !quitting else { return .terminateCancel }
        quitting = true
        Task {
            if !model.stopping { await model.disconnect() }
            await model.refreshConnectionStatus()
            quitting = false
            sender.reply(toApplicationShouldTerminate: model.canQuit)
        }
        return .terminateLater
    }
}
