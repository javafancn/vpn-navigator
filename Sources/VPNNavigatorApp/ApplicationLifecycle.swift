import AppKit

/// Cmd-Q and menu-bar Quit share one asynchronous shutdown path. A failed
/// disconnect must not silently abandon an unresolved owned session.
@MainActor
final class ApplicationLifecycle: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var quitting = false
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { model?.quickAccess.shutdown() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard !model.maintenanceInProgress, !model.backgroundServicesBusy else { return .terminateCancel }
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
