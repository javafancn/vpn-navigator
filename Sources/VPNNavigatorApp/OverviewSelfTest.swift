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
        model.pendingManualFailureAttempt = attempt
        let failed = SessionReport(state: .failed, message: "synthetic route failure", activeProfileID: nil,
            receivedBytes: nil, sentBytes: nil, attemptID: attempt, networkRecoveryRequired: false)
        model.applyVerifiedSessionReport(failed)
        guard model.message?.contains("synthetic route failure") == true, model.pendingManualFailureAttempt == nil else { throw Failure.check }
        guard model.canEditOverviewProtection else { throw Failure.check }
        model.setOverviewProtection(false)
        guard !model.killSwitch else { throw Failure.check }
        model.message = nil
        model.applyVerifiedSessionReport(failed)
        guard model.message == nil else { throw Failure.check }
        model.pendingManualFailureAttempt = UUID()
        model.applyVerifiedSessionReport(failed)
        guard model.message == nil, model.pendingManualFailureAttempt != nil else { throw Failure.check }
        model.pendingManualFailureAttempt = nil
        #if DEBUG
        // Reproduce a route rollback longer than the old 12s poll timeout.
        // The production status gates run unchanged; only the XPC stop receipt
        // is delayed synthetically, without starting or stopping a real VPN.
        model.disconnectTestOperation = { _ in
            try? await Task.sleep(nanoseconds: 13_000_000_000)
            return "Disconnected"
        }
        var ended = false
        let disconnect = Task { await model.disconnect(); ended = true }
        await Task.yield()
        guard model.disconnectRequestInFlight, model.stopping else { throw Failure.check }
        let stale = SessionReport(state: .failed, message: "old timed-out status poll", activeProfileID: nil,
            receivedBytes: nil, sentBytes: nil, networkRecoveryRequired: true)
        while !ended {
            model.applyVerifiedSessionReport(stale)
            await model.refreshConnectionStatus()
            if ended { break }
            guard model.disconnectRequestInFlight, model.stopping, !model.overviewRecoveryNeeded, model.message == nil else { throw Failure.check }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        await disconnect.value
        model.disconnectTestOperation = nil
        guard !model.disconnectRequestInFlight, !model.stopping else { throw Failure.check }
        print("PASS: disconnect exceeds the ordinary poll deadline without a false failure; stale snapshots and overlapping polls cannot overwrite stopping.")
        #endif
        idle(); guard model.canEditOverviewProtection, !model.overviewRecoveryNeeded else { throw Failure.check }
        print("PASS overview: verified 60-second live graph, measured duration, actual route instead of selection, dual-stack receipt, stale-state expiry, next-connection preference guard, PF recovery and real two-card raster; no VPN requests.")
    }
    static func verifyInstalledTraffic() async throws {
        guard BuildChannel.isLocal, ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" else { throw Failure.check }
        var tracker = TunnelSpeedTracker()
        for _ in 0..<6 {
            guard let report = await HelperClient.shared.sessionReport(),
                  ConnectionObservation(report).verifiedConnection,
                  !report.requiresNetworkRecovery, !report.firewallRecoveryRequired else { throw Failure.check }
            tracker.observe(report)
            if tracker.current() != nil && !tracker.visibleSamples().isEmpty {
                print("PASS: actual installed helper TLS report produces fresh live throughput and chart points; owned journals are not recovery failures.")
                return
            }
            try await Task.sleep(nanoseconds: 800_000_000)
        }
        throw Failure.check
    }
    private enum Failure: Error { case check }
}
