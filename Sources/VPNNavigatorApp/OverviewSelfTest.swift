import AppKit
import SwiftUI
import VPNNavigatorCore

@MainActor
enum OverviewSelfTest {
    private static var started = false
    static func begin() -> Bool { guard !started else { return false }; started = true; return true }
    static func run(model: AppModel) async throws {
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" else { throw Failure.check }
        let originalPreference = model.killSwitch
        defer { model.killSwitch = originalPreference }
        let profile = VPNProfile(name: "Overview synthetic fixture", sourceFilename: "fixture.ovpn", relativePath: "not-on-disk", mode: .fullVPN)
        model.profiles = [profile]; model.selectedID = profile.id
        func idle() {
            model.applyVerifiedSessionReport(.init(state: .disconnected, message: "fixture", activeProfileID: nil,
                receivedBytes: nil, sentBytes: nil, networkRecoveryRequired: false))
        }
        idle()
        guard model.canEditOverviewProtection, !model.overviewConnectionVerified(), !model.overviewRecoveryNeeded else { throw Failure.check }
        model.setOverviewProtection(true)
        guard model.killSwitch else { throw Failure.check }
        let attempt = UUID(), now = Date(), uptime = ProcessInfo.processInfo.systemUptime
        let span = min(60, max(1, Int(uptime)))
        for i in 0...span {
            model.applyVerifiedSessionReport(.init(state: .connected, message: "fixture, no VPN", activeProfileID: profile.id,
                receivedBytes: UInt64(i * 1_000), sentBytes: UInt64(i * 100), attemptID: attempt,
                networkRecoveryRequired: false, routingMode: .original, ipStack: .dual),
                at: now.addingTimeInterval(Double(i - span)), uptime: uptime + Double(i - span))
        }
        guard model.overviewConnectionVerified(at: now, uptime: uptime), model.activeRoutingMode == .original,
              model.selected?.mode == .fullVPN, model.activeIPStack == .dual, !model.firewallActive,
              !model.canEditOverviewProtection, model.menuTraffic.samples.count == span,
              model.menuTraffic.observedConnectedSeconds == Double(span) else { throw Failure.check }
        model.setOverviewProtection(false)
        guard model.killSwitch, !model.overviewConnectionVerified(at: now.addingTimeInterval(6), uptime: uptime + 6) else { throw Failure.check }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: ConnectionOverviewCards().environmentObject(model).preferredColorScheme(.light))
        window.contentView = hosting; window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(nanoseconds: 350_000_000)
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw Failure.check }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard bitmap.pixelsWide >= 820, bitmap.pixelsHigh >= 200 else { throw Failure.check }
        model.applyVerifiedSessionReport(.init(state: .failed, message: "fixture", activeProfileID: profile.id,
            receivedBytes: nil, sentBytes: nil, firewallActive: true, firewallRecoveryRequired: true,
            attemptID: attempt, networkRecoveryRequired: true))
        guard model.overviewRecoveryNeeded, !model.overviewConnectionVerified(), !model.canEditOverviewProtection,
              model.menuTraffic.samples.isEmpty else { throw Failure.check }
        idle(); guard model.canEditOverviewProtection, !model.overviewRecoveryNeeded else { throw Failure.check }
        print("PASS overview: verified 60-second live graph, measured duration, actual route instead of selection, dual-stack receipt, stale-state expiry, next-connection preference guard, PF recovery and real two-card raster; no VPN requests.")
    }
    private enum Failure: Error { case check }
}
