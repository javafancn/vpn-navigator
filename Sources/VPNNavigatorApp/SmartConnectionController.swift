import AppKit
import Combine
import CoreLocation
import CoreWLAN
import Network
import SystemConfiguration
import UserNotifications
import VPNNavigatorCore

/// Runs while the application is open, including when its last window is closed.
/// Never changes an existing session or performs privileged service registration.
@MainActor
final class SmartConnectionController: NSObject, ObservableObject, CLLocationManagerDelegate, UNUserNotificationCenterDelegate {
    @Published private(set) var preferences: SmartConnectionPreferences
    @Published private(set) var status = "自动连接未开启"
    @Published private(set) var network = SmartNetworkState(online: false)
    @Published private(set) var notificationStatus = "状态通知未开启"
    private weak var model: AppModel?
    private let store: SmartConnectionStore
    private var monitor: NWPathMonitor?
    private var path: NWPath?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var subscription: AnyCancellable?
    private var pending: Task<Void, Never>?
    private var generation = UUID()
    private var sleeping = false
    private var stopped = false
    private var initializedNetwork = false
    private var startupWaitedForNetwork = false
    private var expectedDisconnect = false
    private var reducer = StatusNoticeReducer()
    private var recorded = Set<String>()
    private var location: CLLocationManager?
    private var notices: UNUserNotificationCenter?
    private var permissionBusy = false

    init(model: AppModel, defaults: UserDefaults = .standard) {
        self.model = model; store = SmartConnectionStore(defaults: defaults); preferences = store.load()
        super.init()
        status = preferences.enabled ? (preferences.paused ? "自动连接已暂停" : "等待触发条件") : "自动连接未开启"
        subscription = objectWillChange.sink { [weak model] _ in model?.objectWillChange.send() }
    }
    func start() {
        guard monitor == nil, !stopped else { return }
        let monitor = NWPathMonitor(); self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in Task { @MainActor [weak self] in self?.path = path; self?.refreshNetwork() } }
        monitor.start(queue: DispatchQueue(label: "com.javafancn.vpnnav.smart-network"))
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sleeping = true; self?.cancelPending() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sleeping = false; self?.refreshNetwork(); self?.schedule(.wake) }
        })
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in Task { @MainActor [weak self] in self?.refreshNetwork() } }
        if preferences.notifications { Task { await refreshNotificationPermission() } }
    }
    func stop() {
        stopped = true; cancelPending(); timer?.invalidate(); timer = nil; monitor?.cancel(); monitor = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }; observers.removeAll()
    }
    func update(_ edit: (inout SmartConnectionPreferences) -> Void) {
        var value = preferences; edit(&value)
        do {
            try store.save(value); preferences = value; cancelPending()
            status = value.enabled ? (value.paused ? "自动连接已暂停" : "设置已保存，等待下一次触发") : "自动连接未开启"
        } catch { model?.message = error.localizedDescription }
    }
    func willStartConnection() { expectedDisconnect = false }
    func expectDisconnect() { expectedDisconnect = true }
    func pauseForManualDisconnect() { expectedDisconnect = true; if preferences.enabled { update { $0.paused = true } } else { cancelPending() } }
    func togglePause() { update { $0.paused.toggle() } }
    func cancelPending() { generation = UUID(); pending?.cancel(); pending = nil }
    func target(automatic: Bool) -> VPNProfile? {
        SmartConnectionPlanner.target(profiles: model?.profiles ?? [], successes: store.successes(), preferred: preferences.profileID, automatic: automatic)
    }
    func connectNow() {
        guard let model, let target = target(automatic: false) else { status = "没有可用配置，请先导入配置。"; return }
        guard NSApp.modalWindow == nil, !model.showingSetup, !model.showingMaintenance,
              !model.showingPreferences, !model.showingSmartConnection, !model.showingProfileBackup else { model.quickAccess.openMainWindow(); return }
        cancelPending()
        // Reuse the existing confirmation panel when a different VPN is active.
        model.quickAccess.show(); model.quickAccess.select(target.id); model.quickAccess.activateSelection()
    }
    private func refreshNetwork() {
        guard !stopped, let path else { return }
        // Ignore utun identities: our own VPN must not trigger another attempt.
        let interfaces = path.availableInterfaces.filter { $0.name.hasPrefix("en") }
        func entity(_ name: String, _ family: String) -> [String: Any] {
            SCDynamicStoreCopyValue(nil, "State:/Network/Interface/\(name)/\(family)" as CFString) as? [String: Any] ?? [:]
        }
        let primaryNames = ["IPv4", "IPv6"].compactMap { family -> String? in
            let global = SCDynamicStoreCopyValue(nil, "State:/Network/Global/\(family)" as CFString) as? [String: Any]
            return global?["PrimaryInterface"] as? String
        }.filter { name in interfaces.contains { $0.name == name } }
        let primary = Set(primaryNames)
        let candidates = interfaces.filter { path.usesInterfaceType($0.type) }
        // Multiple different physical defaults are ambiguous: do not guess an SSID.
        let physical = primary.count == 1 ? interfaces.first { primary.contains($0.name) } :
            primary.isEmpty && candidates.count == 1 ? candidates.first : nil
        let kind: SmartNetworkState.Kind = physical?.type == .wifi ? .wifi : physical?.type == .wiredEthernet ? .wired : .other
        let name = kind == .wifi && preferences.networkScope == .specifiedWiFi ? CWWiFiClient.shared().interface(withName: physical?.name)?.ssid() : nil
        let routers = physical.map { "\(entity($0.name, "IPv4")["Router"] ?? "")|\(entity($0.name, "IPv6")["Router"] ?? "")" } ?? ""
        let next = SmartNetworkState(online: path.status == .satisfied && physical != nil, kind: kind, wifiName: name,
                                    expensive: path.isExpensive, identity: "\(physical?.name ?? "")|\(routers)|\(name ?? "")")
        let old = network; network = next
        if !initializedNetwork {
            if next.online {
                initializedNetwork = true
                schedule(preferences.onLaunch || !startupWaitedForNetwork ? .launch : .networkRestored)
            } else { startupWaitedForNetwork = true }
        }
        else if !next.online { cancelPending(); status = preferences.enabled ? "等待可用网络" : "自动连接未开启" }
        else if !old.online || old.identity != next.identity || old.expensive != next.expensive { schedule(.networkRestored) }
    }
    func schedule(_ trigger: SmartTrigger) {
        guard !stopped, preferences.enabled, !preferences.paused, preferences.accepts(trigger) else { return }
        cancelPending(); let token = generation
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, !Task.isCancelled, token == self.generation, let model = self.model else { return }
            await model.refreshConnectionStatus()
            guard !Task.isCancelled, token == self.generation else { return }
            let decision = SmartConnectionPlanner.decide(preferences: self.preferences, trigger: trigger, network: self.network,
                context: model.smartConnectionContext(sleeping: self.sleeping), target: self.target(automatic: true)?.id)
            switch decision {
            case .disabled: break
            case .wait(let reason): self.status = reason
            case .connect(let id):
                self.status = "正在智能连接…"
                model.selectedID = id
                await model.connectSelected(automatically: true, automationPermit: { [weak self] in
                    guard let self else { return false }
                    self.refreshNetwork()
                    guard token == self.generation, !self.stopped, self.target(automatic: true)?.id == id else { return false }
                    return SmartConnectionPlanner.decide(preferences: self.preferences, trigger: trigger, network: self.network,
                        context: .init(state: .disconnected, helperReady: true, sleeping: self.sleeping), target: id) == .connect(id)
                })
                if token == self.generation {
                    if model.sessionState == .failed {
                        self.update { $0.paused = true }; self.status = "连接未成功，自动连接已暂停；请检查后主动恢复。"
                        await self.deliver(.failure)
                    } else { self.status = model.connected ? "智能连接已完成" : model.connecting ? "连接请求已提交，等待助手确认" : "本次自动连接已跳过，等待下一次触发" }
                }
            }
        }
    }
    func observe(_ report: SessionReport?) {
        if let report, report.state == .connected, report.challenge == nil,
           report.routingMode != nil, report.routingMode == .original || report.routingRevision != nil,
           let id = report.activeProfileID, let attempt = report.attemptID {
            let key = "\(id):\(attempt)"
            if recorded.insert(key).inserted { store.recordSuccess(id); if recorded.count > 100 { recorded = [key] } }
        }
        let events = reducer.observe(report, expectedDisconnect: expectedDisconnect)
        if let report, report.state == .disconnected || report.state == .failed { expectedDisconnect = false }
        if let report, report.state == .failed, preferences.enabled, !preferences.paused {
            update { $0.paused = true }; status = "连接异常，自动连接已暂停；请检查后主动恢复。"
        }
        for notice in events { Task { await deliver(notice) } }
    }
    func requestWiFiAccess() {
        if location == nil { location = CLLocationManager(); location?.delegate = self }
        location?.requestWhenInUseAuthorization()
    }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in self?.refreshNetwork() }
    }
    private func notificationCenter() -> UNUserNotificationCenter {
        if let notices { return notices }
        let center = UNUserNotificationCenter.current(); center.delegate = self; notices = center; return center
    }
    func enableNotifications(_ enabled: Bool) async {
        if !enabled {
            update { $0.notifications = false }; notificationStatus = "状态通知未开启"
            notices?.removeAllPendingNotificationRequests(); return
        }
        guard !permissionBusy else { return }; permissionBusy = true; defer { permissionBusy = false }
        update { $0.notifications = enabled }
        if enabled {
            do { _ = try await notificationCenter().requestAuthorization(options: [.alert, .sound]) }
            catch { notificationStatus = "无法请求通知授权，请检查系统设置。"; return }
        }
        await refreshNotificationPermission()
    }
    func refreshNotificationPermission() async {
        guard preferences.notifications else { notificationStatus = "状态通知未开启"; return }
        let settings = await notificationCenter().notificationSettings()
        notificationStatus = settings.authorizationStatus == .authorized ? "系统已允许通知；横幅与声音由系统设置控制" : "系统尚未允许通知，请前往通知设置检查"
    }
    func deliver(_ notice: VPNStatusNotice) async {
        guard preferences.notifications, notice == .test || preferences.noticeScope == .all || notice.isError else { return }
        let center = notificationCenter(), settings = await center.notificationSettings()
        guard preferences.notifications, notice == .test || preferences.noticeScope == .all || notice.isError, settings.authorizationStatus == .authorized else { await refreshNotificationPermission(); return }
        let content = UNMutableNotificationContent(); content.title = notice.title; content.body = notice.body
        if preferences.sound { content.sound = .default }
        do { try await center.add(UNNotificationRequest(identifier: "vpnnav-status-" + UUID().uuidString, content: content, trigger: nil)) }
        catch { notificationStatus = "通知提交失败，请检查系统通知设置。" }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor [weak self] in
            guard let self, self.preferences.notifications else { completionHandler([]); return }
            completionHandler(self.preferences.sound ? [.banner, .list, .sound] : [.banner, .list])
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor [weak self] in self?.model?.quickAccess.openMainWindow(); completionHandler() }
    }
}
