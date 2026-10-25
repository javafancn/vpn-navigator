import AppKit
import Combine
import UserNotifications
import VPNNavigatorCore

@MainActor
final class ProfileHealthController: ObservableObject {
    @Published private(set) var reports: [UUID: ProfileHealthReport] = [:]
    @Published private(set) var checking = false
    @Published private(set) var problem: String?
    @Published private(set) var ledger: CertificateReminderLedger
    @Published private(set) var notificationStatus = "证书到期通知未开启"
    var remindersEnabled: Bool { ledger.enabled }
    private weak var model: AppModel?
    private let store: ProfileStore
    private let defaults: UserDefaults
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var subscription: AnyCancellable?
    private var pending: Task<Void, Never>?
    private var generation = UUID()
    private var permissionBusy = false
    private var started = false
    private let key = "certificate-reminders-v1"

    init(model: AppModel, store: ProfileStore, defaults: UserDefaults) {
        self.model = model; self.store = store; self.defaults = defaults
        ledger = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(CertificateReminderLedger.self, from: $0) } ?? .init()
        subscription = objectWillChange.sink { [weak model] _ in model?.objectWillChange.send() }
    }
    func start() {
        guard !started else { return }; started = true
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in Task { @MainActor [weak self] in self?.requestRefresh() } }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor [weak self] in self?.requestRefresh() } })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor [weak self] in self?.requestRefresh() } })
        requestRefresh()
    }
    func stop() {
        generation = UUID(); pending?.cancel(); pending = nil; timer?.invalidate(); timer = nil
        for item in observers { NotificationCenter.default.removeObserver(item); NSWorkspace.shared.notificationCenter.removeObserver(item) }
        observers = []; started = false
    }
    func invalidate() { generation = UUID(); pending?.cancel(); pending = nil; checking = false }
    func requestRefresh() {
        // Avoid filesystem reads for composition fixtures or during mutation.
        guard let model, !ProcessInfo.processInfo.arguments.contains("--vpnnav-ui-demo-snapshot"),
              !model.profileTransferInProgress, model.profileIndexIssue == nil else { return }
        generation = UUID(); let token = generation; pending?.cancel()
        pending = Task { [weak self] in
            guard let self else { return }
            self.checking = true; self.problem = nil
            defer { if token == self.generation { self.checking = false; self.pending = nil } }
            do {
                let next = try await self.store.healthReports()
                guard !Task.isCancelled, token == self.generation, self.model?.profileTransferInProgress == false else { return }
                self.reports = next; self.ledger.reconcile(ids: Set(next.keys)); self.save()
                await self.deliverReminders(token: token)
            } catch is CancellationError { }
            catch { if token == self.generation { self.problem = "未能完成配置检查，请检查配置存储及索引状态。" } }
        }
    }
    func enableReminders(_ value: Bool) async {
        guard !permissionBusy else { return }; permissionBusy = true; defer { permissionBusy = false }
        generation = UUID(); pending?.cancel(); checking = false
        ledger.enabled = value; save()
        if !value {
            notificationStatus = "证书到期通知未开启"
            let ids = (model?.profiles ?? []).map { "vpnnav-certificate-" + $0.id.uuidString }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
            return
        }
        do { _ = try await model?.smartConnection.requestCertificatePermission() }
        catch { notificationStatus = "无法请求通知授权，请检查系统设置。"; return }
        await refreshPermission(); requestRefresh()
    }
    func refreshPermission() async {
        guard ledger.enabled else { notificationStatus = "证书到期通知未开启"; return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationStatus = settings.authorizationStatus == .authorized ? "已允许证书提醒；应用运行时检查，横幅由系统设置控制" : "系统尚未允许通知；应用内仍显示检查结果"
    }
    private func save() { if let data = try? JSONEncoder().encode(ledger) { defaults.set(data, forKey: key) } }
    private func deliverReminders(token: UUID) async {
        guard ledger.enabled, let model else { return }
        await refreshPermission()
        for (id, report) in reports.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            let identifier = "vpnnav-certificate-" + id.uuidString
            guard let signature = report.reminderSignature(at: Date()) else {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier]); continue
            }
            guard token == generation, !Task.isCancelled, ledger.shouldDeliver(id: id, signature: signature), model.profiles.contains(where: { $0.id == id }) else { continue }
            if await model.smartConnection.deliverCertificateReminder(id: id) {
                guard token == generation, ledger.enabled else {
                    UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier]); continue
                }
                ledger.record(id: id, signature: signature); save()
            }
        }
    }
}
