import SwiftUI
import VPNNavigatorCore
import ServiceManagement
import Darwin
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published var profiles: [VPNProfile] = []
    @Published var profileLibrary: ProfileLibraryQuery {
        didSet {
            if oldValue.sort != profileLibrary.sort { libraryDefaults.set(profileLibrary.sort.rawValue, forKey: "profileLibrarySort") }
        }
    }
    private let libraryDefaults: UserDefaults
    @Published private(set) var profileMetadataInProgress = false
    var libraryProfiles: [VPNProfile] { profileLibrary.results(profiles) }
    var libraryGroups: [ProfileGroupSummary] { ProfileLibraryQuery.groups(profiles) }

    @Published var showingImportReport = false
    @Published private(set) var importResults: [ProfileImportResult] = []
    @Published private(set) var profileImportInProgress = false
    @Published private(set) var profileExportInProgress = false
    @Published private(set) var profileBackupInProgress = false
    @Published private(set) var profileUpdateInProgress = false
    @Published var profileHealthTarget: VPNProfile?
    @Published var profileUpdateRequested = false
    lazy var profileHealth = ProfileHealthController(model: self, store: store, defaults: smartDefaults)
    @Published var showingProfileBackup = false
    @Published private(set) var importCancellationRequested = false
    private var importCancellation: ProfileImportCancellation?
    @Published private(set) var incomingProfiles = ProfileOpenQueue()
    @Published private(set) var reviewingIncomingProfiles = false
    @Published private(set) var profileDropLoading = false
    @Published var profilePickerPresented = false
    @Published private(set) var profileOpenReady = false
    var profileTransferInProgress: Bool { profileImportInProgress || profileExportInProgress || profileBackupInProgress || profileUpdateInProgress || profileIndexRecoveryInProgress || profileMetadataInProgress }
    @Published var quickAccessShortcut = QuickAccessShortcut(rawValue: UserDefaults.standard.string(forKey: "quickAccessShortcut") ?? "") ?? .disabled {
        didSet { UserDefaults.standard.set(quickAccessShortcut.rawValue, forKey: "quickAccessShortcut") }
    }
    @Published private(set) var profileIndexIssue: String?
    @Published private(set) var profileIndexRecovery: ProfileIndexRecoveryPreview?
    @Published private(set) var profileIndexRecoveryProblem: String?
    @Published private(set) var profileIndexBackupStatus = L10n.text("尚未检查")
    @Published private(set) var profileIndexRecoveryInProgress = false
    @Published var showingProfileIndexRecovery = false
    @Published var quickAccessShortcutStatus = L10n.text("全局快捷键已关闭")
    lazy var quickAccess = QuickAccessCoordinator(model: self)
    private let smartDefaults: UserDefaults
    lazy var smartConnection = SmartConnectionController(model: self, defaults: smartDefaults)
    @Published var showingSmartConnection = false
    @Published var selectedID: UUID? {
        didSet {
            if oldValue != selectedID {
                username = ""
                password = ""
            }
        }
    }
    @Published var rulesUpdatedAt: Date?
    @Published var rules: RuleSet?
    @Published var ipv6Preview: IPv6RuleSet?
    @Published var ruleSnapshots: [RuleSnapshot] = []
    @Published var firewallActive = false
    @Published var firewallRecoveryRequired = false
    @Published var networkRecoveryRequired = false
    @Published var reconnectManaged = UserDefaults.standard.bool(forKey: "reconnectManaged") {
        didSet { UserDefaults.standard.set(reconnectManaged, forKey: "reconnectManaged") }
    }
    @Published var killSwitch = UserDefaults.standard.bool(forKey: "killSwitch") {
        didSet { UserDefaults.standard.set(killSwitch, forKey: "killSwitch") }
    }
    @Published var authenticationChallenge: AuthenticationChallenge? {
        didSet {
            if let challenge = authenticationChallenge, challenge.id != oldValue?.id {
                quickAccess.openMainWindow()
            }
        }
    }
    @Published var showingAccountCredentials = false {
        didSet { if showingAccountCredentials && !oldValue { quickAccess.openMainWindow() } }
    }
    @Published var showingMaintenance = false
    @Published var showingSetup = false
    @Published var showingPreferences = false
    @Published var showingDiagnostics = false
    @Published var showingConnectionHistory = false
    private let connectionHistoryDirectory: URL
    lazy var connectionHistory = ConnectionHistoryController(model: self, directory: connectionHistoryDirectory)
    @Published var showingRouteExplanation = false
    @Published var showingTroubleshooting = false
    @Published var showingPublicEgress = false
    @Published var showingLanguageSettings = false
    @Published var showingKeyboardHelp = false
    /// Prevent main-window menu shortcuts from navigating behind sheets or a
    /// native file/authorization panel. The native command router rechecks it.
    var nativeDialogPresented: Bool {
        NSApp.modalWindow != nil || NSApp.keyWindow?.sheetParent != nil || NSApp.mainWindow?.attachedSheet != nil
    }
    var workspaceNavigationBlocked: Bool {
        nativeDialogPresented || showingLanguageSettings || showingKeyboardHelp || message != nil ||
        profilePickerPresented || showingAccountCredentials || authenticationChallenge != nil ||
        showingMaintenance || showingSetup || showingPreferences || showingProfileBackup ||
        profileHealthTarget != nil || showingSmartConnection || showingProfileIndexRecovery ||
        customRuleEditorProfile != nil || showingRouteExplanation || showingTroubleshooting ||
        showingPublicEgress || showingDiagnostics || showingConnectionHistory || showingImportReport ||
        profileTransferInProgress || maintenanceInProgress || backgroundServicesBusy
    }
    var canStartEgressProbe: Bool { !busy && !connecting && !stopping && !maintenanceInProgress && !profileTransferInProgress && !routingModeSwitching }
    var egressContextIdentity: String {
        activeRoutingIdentity + "|\(helperStateVerified)|\(networkRecoveryRequired)|\(firewallRecoveryRequired)|\(firewallActive)|\(activeIPStack?.rawValue ?? "")|\(smartConnection.network.identity)|\(smartConnection.network.online)"
    }
    @Published var customRuleEditorProfile: VPNProfile?
    @Published private(set) var activeCustomRuleDigest: String?
    @Published private(set) var activeCustomRuleCount: Int?
    @Published private(set) var activeIPStack: TunnelIPStack?
    @Published var requireDualStack = UserDefaults.standard.bool(forKey: "requireDualStack") {
        didSet { UserDefaults.standard.set(requireDualStack, forKey: "requireDualStack") }
    }
    var activeRoutingIdentity: String {
        [connectionStatus.components(separatedBy: ":").first ?? "", activeProfileID?.uuidString ?? "",
         helperAttemptID?.uuidString ?? "", routingRevision?.uuidString ?? "", activeRoutingMode?.rawValue ?? ""].joined(separator: "|")
    }
    @Published var connectionTimeout = UserDefaults.standard.integer(forKey: "connectionTimeout") {
        didSet { UserDefaults.standard.set(connectionTimeout, forKey: "connectionTimeout") }
    }
    @Published var reconnectOriginal = UserDefaults.standard.object(forKey: "reconnectOriginal") as? Bool ?? true {
        didSet { UserDefaults.standard.set(reconnectOriginal, forKey: "reconnectOriginal") }
    }
    @Published var eventHistory: [DiagnosticEvent] = []
    @Published var profileSizes: [UUID: Int] = [:]
    private var connectionAttempt: UUID?
    private var helperAttemptID: UUID?
    private var helperStateVerified = true
    private var repairExitAuthorized = false
    private let localEvents = DiagnosticEventStore(file: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("VPNNavigator/Diagnostics/events.json"))
    private var profileMutations = 0
    @Published private(set) var maintenanceInProgress = false
    @Published private(set) var backgroundServicesBusy = false
    @Published private(set) var automaticRulesEnabled = true
    @Published private(set) var launchAtLogin = false
    @Published private(set) var rulesServiceStatus = L10n.text("未检查")
    @Published private(set) var loginServiceStatus = L10n.text("未检查")
    @Published private(set) var backgroundServicesIssue: String?
    private let backgroundPreferences: BackgroundServicePreferences
    @Published var busy = false
    @Published var message: String?
    @Published var helperStatus = L10n.text("未启用")
    @Published var installationIssue: String?
    @Published var availableInstaller: URL?
    @Published var availableReleasePage: URL?
    @Published var connectionStatus = "disconnected: Not connected"
    @Published private(set) var activeRoutingMode: RoutingMode?
    @Published private(set) var routingModeTarget: RoutingMode?
    var routingModeSwitching: Bool { routingModeTarget != nil }
    private var routingRevision: UUID?
    private var statusEpoch: UInt64 = 0
    private let routingModeService: RoutingModeService
    @Published var activeProfileID: UUID?
    @Published var traffic: TunnelTraffic?
    @Published private(set) var menuTraffic = TunnelSpeedTracker()
    @Published var receiveTrend = TrafficTrend()
    @Published var sendTrend = TrafficTrend()
    @Published var username = ""
    @Published var password = ""
    @Published var rememberCredentials = UserDefaults.standard.bool(forKey: "rememberCredentials") {
        didSet {
            UserDefaults.standard.set(rememberCredentials, forKey: "rememberCredentials")
            if !rememberCredentials, let selected { KeychainVault.remove(id: selected.credentialID) }
        }
    }

    private let store: ProfileStore
    private let updater: RuleUpdater
    private let ipv6Updater: APNICIPv6PreviewStore
    private let helper = HelperClient.shared

    init(backgroundServiceDefaults: UserDefaults = .standard, profileStoreRoot: URL? = nil, routingModeService: RoutingModeService? = nil, libraryDefaults: UserDefaults = .standard, smartDefaults: UserDefaults = .standard) {
        self.smartDefaults = smartDefaults
        self.libraryDefaults = libraryDefaults
        profileLibrary = ProfileLibraryQuery(sort: ProfileLibrarySort(savedValue: libraryDefaults.string(forKey: "profileLibrarySort")))
        self.routingModeService = routingModeService ?? .live
        backgroundPreferences = BackgroundServicePreferences(defaults: backgroundServiceDefaults,
            existingLoginEnabled: UserServices.loginStatus == .enabled)
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VPNNavigator", isDirectory: true)
        connectionHistoryDirectory = (profileStoreRoot?.deletingLastPathComponent() ?? root).appendingPathComponent("ConnectionHistory")
        store = ProfileStore(root: profileStoreRoot ?? root.appendingPathComponent("Profiles"))
        updater = RuleUpdater(folder: root.appendingPathComponent("Rules"))
        ipv6Updater = APNICIPv6PreviewStore(root: root.appendingPathComponent("Rules"))
        automaticRulesEnabled = backgroundPreferences.rulesEnabled
        launchAtLogin = backgroundPreferences.loginEnabled
        helperStateVerified = helper.installationStatus != .enabled && !(BuildChannel.isLocal && helper.installationStatus == .requiresApproval)
        installationIssue = helper.localInstallationIssue
        if ProcessInfo.processInfo.arguments.contains("--vpnnav-status-bar-self-test") || ProcessInfo.processInfo.arguments.contains("--vpnnav-localization-self-test") || ProcessInfo.processInfo.arguments.contains("--vpnnav-workspace-accessibility-self-test") || ProcessInfo.processInfo.arguments.contains("--vpnnav-public-egress-self-test") || ProcessInfo.processInfo.arguments.contains("--vpnnav-connection-history-self-test") || ProcessInfo.processInfo.arguments.contains("--vpnnav-profile-health-self-test") || ProcessInfo.processInfo.arguments.contains("--vpnnav-profile-backup-self-test") || ProcessInfo.processInfo.arguments.contains("--vpnnav-smart-connection-self-test") || ProcessInfo.processInfo.arguments.contains("--vpnnav-network-self-test") || ProcessInfo.processInfo.arguments.contains("--vpnnav-local-health-check") || ProcessInfo.processInfo.arguments.contains("--vpnnav-local-services-self-test") || ProcessInfo.processInfo.arguments.contains("--vpnnav-local-installation-state") || ProcessInfo.processInfo.arguments.contains("--vpnnav-quick-access-self-test") || ProcessInfo.processInfo.arguments.contains("--vpnnav-profile-transfer-self-test") || ProcessInfo.processInfo.arguments.contains("--vpnnav-routing-mode-self-test") || ProcessInfo.processInfo.arguments.contains("--vpnnav-profile-recovery-self-test") || ProcessInfo.processInfo.arguments.contains("--vpnnav-profile-library-self-test") || ProcessInfo.processInfo.arguments.contains("--vpnnav-routing-tools-self-test") { profileOpenReady = true; return }
        // CI-only in-memory composition fixture for checking the populated
        // inspector against the design. Never written to ProfileStore, never
        // launches OpenVPN and never marks the session as connected.
        if ProcessInfo.processInfo.arguments.contains("--vpnnav-ui-demo-snapshot") {
            let names = [
                ("dy", "dy.ovpn", true),
                ("工作网络", "work.ovpn", false),
                ("家庭网络", "home.ovpn", false),
                ("新加坡节点", "sg.ovpn", false),
                ("美国节点", "us.ovpn", false),
                ("日本节点", "jp.ovpn", false)
            ]
            profiles = names.map { name, file, favorite in
                VPNProfile(name: name, sourceFilename: file,
                    relativePath: "ui-snapshot-only",
                    group: name == "工作网络" ? "工作" : name == "家庭网络" ? "家庭" : name == "dy" ? "个人" : "节点", isFavorite: favorite)
            }
            selectedID = profiles.first?.id
            connectionStatus = "disconnected: UI composition fixture, no tunnel"
            profileOpenReady = true
            return
        }
        Task {
            defer { profileOpenReady = true }
            await load()
            if helper.installationStatus == .enabled { await restoreBackgroundServices() }
            eventHistory = localEvents.events()
            await connectionHistory.start()
            smartConnection.start()
            profileHealth.start()
            if installationIssue != nil || !UserDefaults.standard.bool(forKey: "setupAssistantDismissed") {
                showingSetup = true
            }
        }
        Task {
            while !Task.isCancelled {
                await refreshConnectionStatus()
                try? await Task.sleep(nanoseconds: connected || connecting ? 1_000_000_000 : 3_000_000_000)
            }
        }
    }

    var selected: VPNProfile? { profiles.first { $0.id == selectedID } }
    var activeProfile: VPNProfile? { profiles.first { $0.id == activeProfileID } }
    var sessionState: TunnelState {
        TunnelState(rawValue: String(connectionStatus.prefix { $0 != ":" })) ?? .failed
    }
    var connected: Bool { sessionState == .connected }
    var connecting: Bool { [.connecting, .authenticating, .reconnecting].contains(sessionState) }
    var stopping: Bool { sessionState == .stopping }
    var canQuit: Bool { !routingModeSwitching && !profileTransferInProgress && !backgroundServicesBusy && ((repairExitAuthorized && canRepairInterruptedInstallation) || SessionExitPolicy.mayExit(state: sessionState, activeProfileID: activeProfileID, helperVerified: helperStateVerified, recoveryRequired: firewallRecoveryRequired || networkRecoveryRequired)) }
    var canRepairInterruptedInstallation: Bool {
        guard BuildChannel.isLocal, !maintenanceInProgress, !backgroundServicesBusy, !busy, !connected, !connecting, !stopping,
              activeProfileID == nil, profileMutations == 0,
              let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let transaction = try? LocalInstallation.pendingTransaction() else { return false }
        return transaction.matches(version: version, architecture: LocalInstallation.nativeArchitecture)
    }
    var sessionPreferences: SessionPreferences {
        .init(connectionTimeout: connectionTimeout == 0 ? 60 : connectionTimeout,
              reconnectOriginal: reconnectOriginal, killSwitch: killSwitch, reconnectManaged: reconnectManaged, requireDualStack: requireDualStack)
    }

    func load() async {
        do { try await loadProfiles() } catch { /* Persistent recovery banner owns this failure. */ }
        do {
            rules = try await updater.cached()
            if rules == nil, let seed = Bundle.main.url(forResource: "china-ipv4", withExtension: "txt", subdirectory: "Rules") {
                rules = try await updater.bootstrap(seed)
            }
            rulesUpdatedAt = try await updater.lastUpdated()
            ipv6Preview = try await ipv6Updater.cached()
            ruleSnapshots = try await updater.snapshots()
            rulesUpdatedAt = try await updater.lastUpdated()
        } catch { message = error.localizedDescription }
    }
    private func loadProfiles() async throws {
        do {
            profiles = try await store.list()
            profileLibrary.reconcileGroups(profiles)
            profileIndexIssue = nil; profileIndexRecovery = nil; profileIndexRecoveryProblem = nil
        } catch {
            profiles = []; profileSizes = [:]; selectedID = nil
            profileIndexIssue = error.localizedDescription
            await refreshProfileIndexRecovery()
            throw error
        }
        var sizes: [UUID: Int] = [:]
        for item in profiles { sizes[item.id] = try? await store.fileSize(for: item) }
        profileSizes = sizes
        if !profiles.contains(where: { $0.id == selectedID }) { selectedID = profiles.first?.id }
        await refreshProfileIndexBackupStatus()
        profileHealth.requestRefresh()
    }
    private func refreshProfileIndexBackupStatus() async {
        do {
            let info = try await store.indexBackupInfo()
            profileIndexBackupStatus = info.matchesCurrentIndex ?
                L10n.format("已备份 {0} 个配置 · ", [String(describing: info.profileCount)]) + info.savedAt.formatted(.dateTime.locale(L10n.locale).year().month().day().hour().minute()) :
                L10n.text("备份与当前列表不一致，请保留原始配置文件。")
        } catch { profileIndexBackupStatus = L10n.text("暂无可用备份：") + error.localizedDescription }
    }
    private func refreshProfileIndexRecovery() async {
        await refreshProfileIndexBackupStatus()
        do {
            profileIndexRecovery = try await store.indexRecoveryPreview()
            profileIndexRecoveryProblem = nil
        } catch {
            profileIndexRecovery = nil; profileIndexRecoveryProblem = error.localizedDescription
        }
    }
    var canManageProfileIndex: Bool {
        !ProcessInfo.processInfo.arguments.contains("--vpnnav-ui-demo-snapshot") && !profileTransferInProgress &&
        !busy && !maintenanceInProgress && !backgroundServicesBusy && !routingModeSwitching &&
        profileMutations == 0 && sessionState == .disconnected && activeProfileID == nil && !showingImportReport
    }
    var canRecoverProfileIndex: Bool {
        canManageProfileIndex && profileIndexIssue != nil && profileIndexRecovery != nil
    }
    func refreshProfileIndexBackup() async {
        guard canManageProfileIndex, profileIndexIssue == nil else { return }
        profileIndexRecoveryInProgress = true; profileMutations += 1
        defer { profileIndexRecoveryInProgress = false; profileMutations -= 1 }
        do {
            try await store.refreshIndexBackup()
            await refreshProfileIndexBackupStatus()
            profileIndexRecoveryProblem = L10n.text("配置列表备份已更新。")
        } catch { profileIndexRecoveryProblem = L10n.text("未更新备份：") + error.localizedDescription }
    }
    func inspectProfileIndex() async {
        guard !busy, !profileTransferInProgress, !maintenanceInProgress, !backgroundServicesBusy,
              !routingModeSwitching, profileMutations == 0 else { return }
        profileIndexRecoveryInProgress = true
        defer { profileIndexRecoveryInProgress = false }
        do { try await loadProfiles() } catch { /* Show the recovery result in the sheet. */ }
        showingProfileIndexRecovery = true
    }
    func recoverProfileIndex() async {
        guard canRecoverProfileIndex, let preview = profileIndexRecovery else { return }
        profileIndexRecoveryInProgress = true; profileMutations += 1
        defer { profileIndexRecoveryInProgress = false; profileMutations -= 1 }
        do {
            try await store.recoverIndex(preview)
            try await loadProfiles()
            profileIndexRecoveryProblem = L10n.text("配置列表已恢复。")
        } catch {
            // Keep the confirmation disabled until the user explicitly inspects
            // again. A stale confirmation must never become a new approval.
            profileIndexRecovery = nil
            profileIndexRecoveryProblem = L10n.text("未恢复：") + error.localizedDescription
        }
    }
    func showProfileIndexRecoverySnapshot() async {
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",
              ProcessInfo.processInfo.arguments.contains("--vpnnav-ui-demo-snapshot") else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vpnnav-index-snapshot-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let source = root.appendingPathComponent("工作网络.ovpn")
            try "client\ndev tun\nremote fixture.example 1194\n<ca>\nFAKE\n</ca>\n".write(to: source, atomically: true, encoding: .utf8)
            let folder = root.appendingPathComponent("profiles"), fixture = ProfileStore(root: root.appendingPathComponent("profiles"))
            var item = try await fixture.importProfile(from: source)
            item.group = "公司"; item.isFavorite = true; item.mode = .chinaDirect
            try await fixture.update(item)
            try Data("fixture damage".utf8).write(to: folder.appendingPathComponent("profiles.json"))
            profileIndexRecovery = try await fixture.indexRecoveryPreview()
            profileIndexIssue = ProfileIndexFailure.invalidIndex.localizedDescription
            profileIndexBackupStatus = L10n.text("已备份 1 个配置 · 本机故障恢复预览")
            showingProfileIndexRecovery = true
        } catch { message = L10n.text("恢复界面预览未能生成。") }
    }
    func importFile(_ url: URL) async {
        await importFiles([url], presentReport: false)
    }
    var incomingPresentationReady: Bool {
        profileOpenReady && !nativeDialogPresented && profileIndexIssue == nil && !incomingProfiles.isEmpty && !profileDropLoading && !profilePickerPresented &&
        !routingModeSwitching && !maintenanceInProgress && !backgroundServicesBusy && !profileTransferInProgress && !busy &&
        !connecting && !stopping && !showingConnectionHistory && profileHealthTarget == nil && !showingImportReport && !showingSetup && !showingMaintenance &&
        !showingPreferences && !showingLanguageSettings && !showingKeyboardHelp && !showingPublicEgress && !showingDiagnostics && !showingRouteExplanation && !showingTroubleshooting && customRuleEditorProfile == nil && !showingProfileIndexRecovery && !showingAccountCredentials &&
        authenticationChallenge == nil && message == nil
    }
    func receiveProfileOpenRequest(_ request: ProfileOpenQueue) {
        incomingProfiles.merge(request)
        quickAccess.hide()
        quickAccess.openMainWindow()
    }
    func presentIncomingProfiles() {
        guard incomingPresentationReady else { return }
        quickAccess.hide()
        reviewingIncomingProfiles = true; showingImportReport = true
    }
    func receiveProfileDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty, !profileDropLoading else { return false }
        profileDropLoading = true
        ProfileDropLoader.start(providers) { [weak self] urls, unresolved, overflow in
            guard let self else { return }
            var request = ProfileOpenQueue(); request.append(urls)
            request.recordUnresolved(unresolved, overflow: overflow)
            self.profileDropLoading = false
            self.receiveProfileOpenRequest(request)
        }
        return true
    }
    func confirmIncomingProfiles() async {
        guard canConfirmIncomingProfiles else { return }
        let urls = incomingProfiles.urls
        incomingProfiles.clear(); reviewingIncomingProfiles = false
        await importFiles(urls)
    }
    var canConfirmIncomingProfiles: Bool {
        !routingModeSwitching && profileIndexIssue == nil && reviewingIncomingProfiles && !incomingProfiles.urls.isEmpty &&
        !maintenanceInProgress && !backgroundServicesBusy && !profileTransferInProgress &&
        !busy && !connecting && !stopping
    }
    var canChooseProfileFiles: Bool {
        !nativeDialogPresented && !routingModeSwitching && !maintenanceInProgress && !backgroundServicesBusy && !profileTransferInProgress &&
        !showingImportReport && !showingProfileIndexRecovery && profileIndexIssue == nil && !busy && !connecting && !stopping
    }
    func importFiles(_ urls: [URL], presentReport: Bool = true) async {
        guard !reviewingIncomingProfiles, !maintenanceInProgress, !backgroundServicesBusy,
              !profileTransferInProgress, !routingModeSwitching, profileIndexIssue == nil, !busy, !connecting, !stopping else {
            message = L10n.text("请等待当前操作完成后再导入配置。"); return
        }
        guard !urls.isEmpty, urls.count <= ProfileBatchImporter.maximumFiles else {
            message = ProfileBatchImporter.Failure.fileCount.localizedDescription; return
        }
        let cancellation = ProfileImportCancellation()
        importCancellation = cancellation; importCancellationRequested = false
        importResults = []; profileImportInProgress = true; profileMutations += 1
        if presentReport { showingImportReport = true }
        defer { profileImportInProgress = false; profileMutations -= 1; importCancellation = nil; profileHealth.requestRefresh() }
        do {
            importResults = try await ProfileBatchImporter(store: store).run(urls, cancellation: cancellation) { [weak self] results in
                await self?.receiveImportProgress(results)
            }
            try await loadProfiles()
            if let id = importResults.compactMap({ item -> UUID? in
                if case .imported(let id) = item.status { return id }; return nil
            }).first { selectedID = id }
            if !presentReport {
                if let first = importResults.first, case .failed(let failure) = first.status { message = failure.summary }
                else { message = L10n.text("配置已导入。") }
            }
        } catch { message = L10n.text("无法完成导入或刷新配置列表，请检查存储权限。") }
    }
    func cancelProfileImport() {
        guard profileImportInProgress else { return }
        importCancellationRequested = true; importCancellation?.cancel()
    }
    private func receiveImportProgress(_ results: [ProfileImportResult]) { importResults = results }
    func clearImportReport() {
        guard !profileImportInProgress else { return }
        if reviewingIncomingProfiles { incomingProfiles.clear() }
        reviewingIncomingProfiles = false
        showingImportReport = false; importResults = []; importCancellationRequested = false
    }
    func showImportReportSnapshot() {
        guard ProcessInfo.processInfo.arguments.contains("--vpnnav-ui-demo-snapshot") else { return }
        importResults = [
            .init(filename: "工作网络.ovpn", status: .imported(UUID())),
            .init(filename: "家庭网络.ovpn", status: .imported(UUID())),
            .init(filename: "测试节点.ovpn", status: .failed(.material)),
            .init(filename: "备用节点.ovpn", status: .cancelled)
        ]
        showingImportReport = true
    }
    func displayedRoutingMode(for id: UUID?) -> RoutingMode? {
        if activeProfileID != nil, id == activeProfileID { return connected ? activeRoutingMode : nil }
        return profiles.first(where: { $0.id == id })?.mode
    }
    var routingModeStatus: String {
        if let target = routingModeTarget { return L10n.text("正在切换为") + target.title + "…" }
        if connected { return L10n.text("实际路由：") + (activeRoutingMode?.title ?? L10n.text("尚未核验")) }
        if activeProfileID != nil { return L10n.text("连接状态变化中，路由待核验") }
        return L10n.text("保存后在下次连接生效")
    }
    func canSetRoutingMode(_ mode: RoutingMode, for id: UUID?) -> Bool {
        guard let id, profiles.contains(where: { $0.id == id }), !busy, !routingModeSwitching,
              !maintenanceInProgress, !backgroundServicesBusy, !profileTransferInProgress,
              !showingImportReport, !connecting, !stopping else { return false }
        if id == activeProfileID {
            guard connected, let current = activeRoutingMode else { return false }
            if mode == current { return true }
            return current != .original && mode != .original && routingRevision != nil && helperAttemptID != nil &&
                (mode != .chinaDirect || ((rules?.routes.count ?? 0) >= 100 && (activeIPStack != .dual && activeIPStack != .ipv6 || (ipv6Preview?.routes.count ?? 0) >= 100)))
        }
        return true
    }
    func setMode(_ mode: RoutingMode, for profileID: UUID? = nil) async {
        let id = profileID ?? selectedID
        guard canSetRoutingMode(mode, for: id), let id else { return }
        guard displayedRoutingMode(for: id) != mode else { return }
        profileMutations += 1; defer { profileMutations -= 1 }
        if connected, activeProfileID == id {
            guard let expectedAttempt = helperAttemptID, let revision = routingRevision,
                  let previous = activeRoutingMode else { return }
            statusEpoch &+= 1; routingModeTarget = mode; busy = true
            let operationEpoch = statusEpoch
            defer { statusEpoch &+= 1; routingModeTarget = nil; busy = maintenanceInProgress }
            do {
                guard let report = await routingModeService.snapshot() else {
                    markRoutingUnverified(); throw RoutingModeSwitchError.stale
                }
                guard statusEpoch == operationEpoch else { throw RoutingModeSwitchError.stale }
                applyVerifiedSessionReport(report)
                guard report.activeProfileID == id, report.attemptID == expectedAttempt,
                      report.routingRevision == revision, report.routingMode == previous else { throw RoutingModeSwitchError.stale }
                let request = try RoutingModeSwitchRequest(report: report, target: mode)
                let ruleText = mode == .chinaDirect ? routingRuleText() : ""
                let response = await routingModeService.apply(request, ruleText)
                let confirmed = await routingModeService.snapshot()
                guard statusEpoch == operationEpoch else { throw RoutingModeSwitchError.stale }
                if let confirmed { applyVerifiedSessionReport(confirmed) }
                else { markRoutingUnverified() }
                guard response == "Routing mode applied", let confirmed,
                      confirmed.state == .connected, confirmed.activeProfileID == id,
                      confirmed.attemptID == expectedAttempt, confirmed.routingMode == mode,
                      let confirmedRevision = confirmed.routingRevision, confirmedRevision != revision else {
                    message = L10n.text("路由切换未确认：") + response; return
                }
                do { try await persistMode(mode, id: id) }
                catch { message = L10n.text("实际路由已切换为") + mode.title + L10n.text("，但默认策略保存失败，请在下次连接前重新选择。") }
            } catch { message = L10n.text("未切换路由：") + error.localizedDescription }
        } else {
            do { try await persistMode(mode, id: id) }
            catch { message = L10n.text("无法保存路由策略：") + error.localizedDescription }
        }
    }
    private func persistMode(_ mode: RoutingMode, id: UUID) async throws {
        // Reload metadata after a potentially long route transaction.
        let latest = try await store.list()
        guard var item = latest.first(where: { $0.id == id }) else { throw StoreError.notFound }
        item.mode = mode; try await store.update(item); try await loadProfiles()
    }
    private func markRoutingUnverified() {
        activeRoutingMode = nil; routingRevision = nil; activeCustomRuleDigest = nil; activeCustomRuleCount = nil; activeIPStack = nil; helperStateVerified = false
        networkRecoveryRequired = true
        connectionStatus = L10n.text("failed: 无法核验路由切换结果，请检查助手与网络恢复状态")
    }
    func canEditProfileMetadata(_ id: UUID) -> Bool {
        profileIndexIssue == nil && profiles.contains(where: { $0.id == id }) && !busy &&
        !maintenanceInProgress && !routingModeSwitching && !profileTransferInProgress &&
        !backgroundServicesBusy && profileMutations == 0
    }
    func updateMetadata(name: String, group: String, notes: String, favorite: Bool, for id: UUID) async {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanGroup = group.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, cleanName.count <= 100,
              !cleanGroup.isEmpty, cleanGroup.count <= 48, notes.count <= 4000 else {
            message = L10n.text("名称最多 100 字、类别最多 48 字、备注最多 4000 字，名称与类别不能为空。"); return
        }
        await persistProfileMetadata(id) { item in
            item.name = cleanName; item.group = cleanGroup; item.notes = notes; item.isFavorite = favorite
        }
    }
    func setProfileFavorite(_ favorite: Bool, for id: UUID) async {
        await persistProfileMetadata(id) { $0.isFavorite = favorite }
    }
    private func persistProfileMetadata(_ id: UUID, change: (inout VPNProfile) -> Void) async {
        guard canEditProfileMetadata(id) else { return }
        profileMetadataInProgress = true; profileMutations += 1
        defer { profileMetadataInProgress = false; profileMutations -= 1 }
        do {
            // Resolve the pinned UUID afresh. Do not overwrite a newer routing
            // preference with the inspector's earlier metadata snapshot.
            let latest = try await store.list()
            guard var item = latest.first(where: { $0.id == id }) else { throw StoreError.notFound }
            change(&item)
            try await store.update(item)
            try await loadProfiles()
        } catch { message = L10n.text("无法保存配置信息：") + error.localizedDescription }
    }

    func canEditCustomRules(_ id: UUID) -> Bool {
        canEditProfileMetadata(id) && id != activeProfileID && !connecting && !stopping
    }
    func saveCustomRules(for id: UUID, original: [CustomRouteRule], draft: [CustomRouteRule]) async -> String? {
        guard canEditCustomRules(id) else { return L10n.text("请先断开该配置的连接并等待其它操作完成。") }
        profileMetadataInProgress = true; profileMutations += 1
        defer { profileMetadataInProgress = false; profileMutations -= 1 }
        do {
            let validated = try CustomRuleSet(draft)
            let latest = try await store.list()
            guard var item = latest.first(where: { $0.id == id }), item.customRules == original else { return L10n.text("配置规则已改变，请关闭后重新打开编辑器。") }
            item.customRules = validated.rules
            try await store.update(item); try await loadProfiles()
            return nil
        } catch { return L10n.text("未保存规则：") + error.localizedDescription }
    }
    func checkConfiguration(_ profile: VPNProfile?, mode: RoutingMode?) async -> ConfigurationCheckState {
        guard let profile else { return .missing }
        do {
            let text = try await store.runtimeConfig(for: profile)
            let parsed = try ProfileSafety.validate(text)
            try ManagedRoutingPolicy.validate(parsed, mode: mode ?? profile.mode)
            _ = try CustomRuleSet(profile.customRules)
            return .valid
        } catch { return .invalid }
    }
    func editSource(for profile: VPNProfile) async -> String? {
        do { return try await store.runtimeConfig(for: profile) }
        catch { message = L10n.format("Cannot open configuration: {0}", [String(describing: error.localizedDescription)]); return nil }
    }

    func saveSource(for profile: VPNProfile, text: String) async -> Bool {
        guard !maintenanceInProgress, !profileTransferInProgress else { return false }
        profileUpdateInProgress = true; profileMutations += 1
        defer { profileUpdateInProgress = false; profileMutations -= 1; profileHealth.requestRefresh() }
        guard !connected && !connecting else {
            message = L10n.text("Disconnect before editing a VPN profile.")
            return false
        }
        do {
            try await store.revise(profile, text: text)
            try await loadProfiles()
            if profiles.first(where: { $0.id == profile.id })?.credentialID != profile.credentialID {
                username = ""; password = ""; KeychainVault.remove(id: profile.credentialID)
            }
            message = L10n.text("Configuration saved and previous version archived.")
            return true
        } catch {
            message = L10n.format("Configuration was not saved: {0}", [String(describing: error.localizedDescription)])
            return false
        }
    }

    func revisions(for profile: VPNProfile) async -> [ProfileRevision] {
        if ProcessInfo.processInfo.arguments.contains("--vpnnav-ui-demo-snapshot") {
            return []
        }
        do { return try await store.revisions(for: profile) }
        catch { message = L10n.format("Cannot read profile history: {0}", [String(describing: error.localizedDescription)]); return [] }
    }

    func restoreSource(for profile: VPNProfile, revision: String) async -> Bool {
        guard !maintenanceInProgress, !profileTransferInProgress else { return false }
        profileUpdateInProgress = true; profileMutations += 1
        defer { profileUpdateInProgress = false; profileMutations -= 1; profileHealth.requestRefresh() }
        guard !connected && !connecting else {
            message = L10n.text("Disconnect before restoring a VPN profile.")
            return false
        }
        do {
            try await store.restore(profile, revision: revision)
            try await loadProfiles()
            if profiles.first(where: { $0.id == profile.id })?.credentialID != profile.credentialID {
                username = ""; password = ""; KeychainVault.remove(id: profile.credentialID)
            }
            message = L10n.text("Previous configuration restored. The newer version was archived.")
            return true
        } catch {
            message = L10n.format("Restore refused: {0}", [String(describing: error.localizedDescription)])
            return false
        }
    }

    func canDeleteProfile(_ id: UUID) -> Bool {
        canEditProfileMetadata(id) && canQuit && activeProfileID == nil && !connecting && !stopping
    }
    func deleteProfile(_ id: UUID) async {
        guard canDeleteProfile(id) else { message = L10n.text("请先断开 VPN 并完成其它操作或网络恢复，再删除配置。"); return }
        profileMetadataInProgress = true; profileMutations += 1
        defer { profileMetadataInProgress = false; profileMutations -= 1 }
        do {
            let credentialID = profiles.first(where: { $0.id == id })?.credentialID ?? id
            try await store.delete(id: id); KeychainVault.remove(id: credentialID)
            try await loadProfiles()
        } catch { message = L10n.text("无法删除配置：") + error.localizedDescription }
    }

    private func routingRuleText(_ ipv4: RuleSet? = nil, ipv6: IPv6RuleSet? = nil) -> String {
        let text4 = (ipv4 ?? rules)?.routes.map(\.description).joined(separator: "\n") ?? ""
        let v6 = ipv6 ?? ipv6Preview
        return v6.map { RoutingRuleBundle(ipv4: text4, ipv6: $0.routes.map(\.description).joined(separator: "\n")).json } ?? text4
    }
    func updateIPv6Preview() async {
        guard !busy, !routingModeSwitching, !connecting, !stopping else { return }
        busy = true; defer { busy = false }
        do {
            let candidate = try await ipv6Updater.fetchCandidate()
            if connected {
                let response = await helper.updateRules(routingRuleText(ipv6: candidate))
                guard response == "Rules applied" || response == "NO_ACTIVE_SPLIT" else { message = L10n.text("IPv6 更新未确认，旧缓存保留：") + response; return }
                await refreshConnectionStatus()
            }
            try await ipv6Updater.commit(candidate); ipv6Preview = candidate
            message = L10n.format("已校验并保存 {0} 条中国 IPv6 注册前缀；活动规则会话已同步核验。", [String(describing: candidate.routes.count)])
        } catch { message = L10n.text("IPv6 更新失败，原缓存保留：") + error.localizedDescription }
    }
    func refreshRules() async {
        guard !busy, !routingModeSwitching, !connecting, !stopping else { return }
        busy = true; defer { busy = false }
        do {
            async let candidate4 = updater.fetchCandidate()
            async let candidate6 = ipv6Updater.fetchCandidate()
            let (v4, v6) = try await (candidate4, candidate6)
            if connected {
                let response = await helper.updateRules(routingRuleText(v4, ipv6: v6))
                guard response == "Rules applied" || response == "NO_ACTIVE_SPLIT" else { message = L10n.text("双栈更新未确认，原缓存保留：") + response; return }
                await refreshConnectionStatus()
            }
            try await updater.commit(v4); try await ipv6Updater.commit(v6)
            rules = v4; ipv6Preview = v6; ruleSnapshots = try await updater.snapshots(); rulesUpdatedAt = try await updater.lastUpdated()
            message = L10n.format("已校验并保存 IPv4 {0} 条、IPv6 {1} 条规则。", [String(describing: v4.routes.count), String(describing: v6.routes.count)])
        } catch { message = L10n.text("双栈规则更新失败；请查看当前实际会话状态：") + error.localizedDescription }
    }

    func checkForUpdates() async {
        if BuildChannel.isLocal {
            message = L10n.text("本地版通过可信来源的同架构 Local.pkg 手动更新；请先打开升级与卸载准备。")
            showingMaintenance = true
            return
        }
        do {
            let release = try await UpdateChecker.latestRelease()
            guard ReleaseAssetPolicy.isApprovedReleasePage(release.html_url) else {
                message = L10n.text("Release metadata failed URL verification.")
                return
            }
            availableReleasePage = release.html_url
            guard let remote = ReleaseVersion(release.tag_name),
                  let installed = ReleaseVersion(
                    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
                  ) else {
                message = L10n.text("Release version could not be verified.")
                return
            }
            if remote <= installed {
                availableInstaller = nil
                message = L10n.format("VPN Navigator {0} is up to date.", [String(describing: installed)])
                return
            }
            availableInstaller = release.trustedInstallerURL
            message = L10n.format("VPN Navigator {0} is available. Downloading requires your approval; installation uses the macOS Installer.", [String(describing: remote)])
        } catch {
            message = L10n.format("Cannot check for application updates: {0}", [String(describing: error.localizedDescription)])
        }
    }
    func downloadVerifiedUpdate() async {
        guard !BuildChannel.isLocal else { return }
        guard !busy, let url = availableInstaller else { return }
        guard !connected && !connecting, helper.installationStatus != .enabled else {
            message = L10n.text("请先准备升级：断开 VPN 并停用后台服务。")
            showingMaintenance = true
            return
        }
        busy = true
        defer { busy = false }
        do {
            let local = try await InstallerUpdate.prepare(url)
            // Never run /usr/sbin/installer automatically; the user remains
            // in control of privileged changes via the macOS Installer UI.
            let accepted = NSWorkspace.shared.open(local)
            message = accepted ?
                "Installer opened. Review and approve the signed update in macOS." :
                "Verified installer saved at \(local.path); open it in Finder to continue."
        } catch {
            message = L10n.format("Update verification failed: {0}", [String(describing: error.localizedDescription)])
        }
    }
    func viewReleasePage() {
        guard let url = availableReleasePage,
              ReleaseAssetPolicy.isApprovedReleasePage(url) else { return }
        NSWorkspace.shared.open(url)
    }
    func retryNetworkRecovery() async {
        guard !connected && !connecting else {
            message = L10n.text("Disconnect the VPN before attempting route recovery.")
            return
        }
        message = await helper.recoverOrphanedRoutes()
        await refreshConnectionStatus()
    }
    func disableServices() async {
        guard !maintenanceInProgress, !backgroundServicesBusy else { return }
        _ = await unregisterNetworkServices()
    }
    func refreshBackgroundServiceStatus() {
        func display(_ status: SMAppService.Status) -> String {
            status == .requiresApproval ? L10n.text("需要系统授权或服务配置需修复") : displayHelperStatus(status)
        }
        rulesServiceStatus = display(UserServices.rulesStatus)
        loginServiceStatus = display(UserServices.loginStatus)
    }
    func setAutomaticRules(_ enabled: Bool) async {
        guard !maintenanceInProgress, !backgroundServicesBusy else { return }
        backgroundPreferences.rulesEnabled = enabled
        automaticRulesEnabled = enabled
        await restoreBackgroundServices()
    }
    func setLaunchAtLogin(_ enabled: Bool) async {
        guard !maintenanceInProgress, !backgroundServicesBusy else { return }
        backgroundPreferences.loginEnabled = enabled
        launchAtLogin = enabled
        await restoreBackgroundServices()
    }
    func restoreBackgroundServices() async {
        guard !maintenanceInProgress, !backgroundServicesBusy else { return }
        backgroundServicesBusy = true
        defer { backgroundServicesBusy = false; refreshBackgroundServiceStatus() }
        backgroundServicesIssue = nil
        do {
            // Removal needs no root authority. Enabling requires the existing
            // authenticated helper, including local payload and caller checks.
            if !automaticRulesEnabled { try await UserServices.disableRules() }
            if !launchAtLogin { try UserServices.setLogin(false) }
            if automaticRulesEnabled || launchAtLogin {
                guard helper.installationStatus == .enabled,
                      (await helper.ping()).hasPrefix("VPN Navigator Helper") else {
                    throw LocalInstallError.notInstalled
                }
                if automaticRulesEnabled, UserServices.rulesStatus != .enabled { try UserServices.enableRules() }
                if launchAtLogin, UserServices.loginStatus != .enabled { try UserServices.setLogin(true) }
            }
            func matches(_ status: SMAppService.Status, enabled: Bool) -> Bool {
                enabled ? status == .enabled : status == .notRegistered || status == .notFound
            }
            guard matches(UserServices.rulesStatus, enabled: automaticRulesEnabled),
                  matches(UserServices.loginStatus, enabled: launchAtLogin) else { throw LocalInstallError.command }
        } catch {
            backgroundServicesIssue = L10n.format("后台服务未完全应用，偏好已保留。请检查安装或系统授权后重试：{0}", [String(describing: error.localizedDescription)])
        }
    }
    private func unregisterNetworkServices() async -> Bool {
        guard !connected && !connecting else {
            message = L10n.text("Disconnect VPN before disabling background services.")
            return false
        }
        if helper.installationStatus == .enabled {
            let actual = await helper.status()
            guard actual.hasPrefix("disconnected:") else {
                message = L10n.format("Background helper reports an active, failed or unresolved session; verify recovery before disabling services: {0}", [String(describing: actual)])
                return false
            }
        }
        do {
            try await UserServices.disableRules()
            if BuildChannel.isLocal { try UserServices.setLogin(false) }
            if helper.installationStatus != .notRegistered && helper.installationStatus != .notFound { try await helper.unregister() }
            await refreshConnectionStatus()
            refreshBackgroundServiceStatus()
            guard [UserServices.rulesStatus, helper.installationStatus].allSatisfy({ $0 == .notRegistered || $0 == .notFound }) else {
                message = L10n.text("后台服务尚未完全停用，请检查系统设置。"); return false
            }
            message = L10n.text("VPN Navigator background services have been unregistered.")
            return true
        } catch {
            message = L10n.format("Service removal requires attention: {0}", [String(describing: error.localizedDescription)])
            return false
        }
    }
    func restoreRuleSnapshot(_ id: UUID) async {
        guard !busy, !routingModeSwitching, !connecting, !stopping else { return }
        busy = true
        defer { busy = false }
        do {
            let restored = try await updater.archivedRules(id: id)
            if let previous = try await updater.cached() {
                try RuleUpdater.validateChange(previous: previous, next: restored)
            }
            if connected {
                let result = await helper.updateRules(
                    routingRuleText(restored))
                guard result == "Rules applied" || result == "NO_ACTIVE_SPLIT" else {
                    message = L10n.format("Previous rules preserved: {0}", [String(describing: result)])
                    return
                }
            }
            try await updater.commit(restored)
            rules = restored
            ruleSnapshots = try await updater.snapshots()
            rulesUpdatedAt = try await updater.lastUpdated()
            message = L10n.text("Previous China IPv4 rules restored.")
        } catch {
            message = L10n.format("Rule rollback refused: {0}", [String(describing: error.localizedDescription)])
        }
    }

    private func displayHelperStatus(_ status: SMAppService.Status) -> String {
        if BuildChannel.isLocal, LocalInstallation.isInstallationPending { return L10n.text("安装未完成") }
        switch status {
        case .enabled: return L10n.text("已启用")
        case .notRegistered: return L10n.text("未注册")
        case .requiresApproval: return BuildChannel.isLocal ? L10n.text("安装需修复或非安装用户") : L10n.text("等待系统授权")
        case .notFound: return L10n.text("服务未安装")
        @unknown default: return L10n.text("状态未知")
        }
    }

    func requestHelper() {
        guard !maintenanceInProgress, !backgroundServicesBusy else { return }
        if BuildChannel.isLocal {
            if helper.installationStatus == .enabled {
                Task { await restoreBackgroundServices(); message = backgroundServicesIssue ?? L10n.text("本地助手已批准，后台服务已按偏好恢复。") }
            } else { openLocalInstaller() }
            return
        }
        do {
            try helper.requestRegistration()
            Task { await restoreBackgroundServices() }
            helperStatus = displayHelperStatus(helper.installationStatus)
            message = L10n.text("Enable the background helper in System Settings if requested. A signed .app distribution is required.")
        } catch { message = L10n.format("Helper registration failed: {0}", [String(describing: error.localizedDescription)]) }
    }
    func applyVerifiedSessionReport(_ report: SessionReport) {
        menuTraffic.observe(report)
        if !(busy && connectionAttempt != nil && sessionState == .connecting && report.state == .disconnected) {
            connectionHistory.observe(.report(.init(report)))
        }
        activeIPStack = report.ipStack; activeCustomRuleDigest = report.customRuleDigest; activeCustomRuleCount = report.customRuleCount
        helperStateVerified = true
        if !(busy && connectionAttempt != nil && sessionState == .connecting && report.state == .disconnected) {
            connectionStatus = report.statusText
        }
        helperAttemptID = report.attemptID
        activeProfileID = report.activeProfileID
        authenticationChallenge = report.challenge
        firewallActive = report.firewallActive
        firewallRecoveryRequired = report.firewallRecoveryRequired
        networkRecoveryRequired = report.requiresNetworkRecovery
        traffic = report.traffic
        if report.state == .connected, let value = report.traffic {
            receiveTrend.record(cumulativeBytes: value.receivedBytes)
            sendTrend.record(cumulativeBytes: value.sentBytes)
        } else {
            receiveTrend.reset()
            sendTrend.reset()
        }
        activeRoutingMode = report.routingMode
        routingRevision = report.routingRevision
        smartConnection.observe(report)
    }
    func refreshConnectionStatus() async {
        let capturedEpoch = statusEpoch
        guard !routingModeSwitching else { return }
        installationIssue = helper.localInstallationIssue
        helperStatus = displayHelperStatus(helper.installationStatus)
        if helper.installationStatus == .enabled {
            if let report = await helper.sessionReport() {
                guard capturedEpoch == statusEpoch, !routingModeSwitching else { return }
                applyVerifiedSessionReport(report)
            } else {
                guard capturedEpoch == statusEpoch, !routingModeSwitching else { return }
                activeRoutingMode = nil; routingRevision = nil; activeCustomRuleDigest = nil; activeCustomRuleCount = nil; activeIPStack = nil
                helperStateVerified = false
                menuTraffic.reset()
                smartConnection.observe(nil)
                connectionHistory.observe(.unverified)
                authenticationChallenge = nil
                connectionStatus = L10n.text("failed: 无法核验后台会话，请检查助手与网络恢复状态")
                activeProfileID = nil
                traffic = nil
                receiveTrend.reset()
                sendTrend.reset()
            }
        } else {
            let unresolved = BuildChannel.isLocal && (helper.installationStatus == .requiresApproval || LocalInstallation.hasRecoveryEvidence)
            helperStateVerified = !unresolved
            menuTraffic.reset()
            smartConnection.observe(nil)
            connectionHistory.observe(.unverified)
            connectionStatus = unresolved ? L10n.text("failed: 本地安装未通过校验，请先恢复网络并修复安装") : "disconnected: Privileged helper not enabled"
            activeRoutingMode = nil; routingRevision = nil; activeCustomRuleDigest = nil; activeCustomRuleCount = nil; activeIPStack = nil
            activeProfileID = nil
            authenticationChallenge = nil
            traffic = nil
            receiveTrend.reset()
            sendTrend.reset()
        }
    }
    func smartConnectionContext(sleeping: Bool = false, preparingAutomatic: Bool = false) -> SmartConnectionContext {
        .init(state: sessionState, activeProfileID: activeProfileID,
              helperReady: helperStateVerified && helper.installationStatus == .enabled,
              recoveryRequired: networkRecoveryRequired || firewallRecoveryRequired,
              occupied: nativeDialogPresented || !profileOpenReady || profileIndexIssue != nil || (busy && !preparingAutomatic) || maintenanceInProgress || backgroundServicesBusy || profileTransferInProgress || profileMutations != 0 ||
                routingModeSwitching || showingImportReport || showingSetup || showingMaintenance || showingPreferences ||
                showingLanguageSettings || showingKeyboardHelp || showingPublicEgress || showingConnectionHistory || profileHealthTarget != nil || showingProfileBackup || showingSmartConnection || showingDiagnostics || showingRouteExplanation || showingTroubleshooting ||
                customRuleEditorProfile != nil || showingProfileIndexRecovery || profilePickerPresented ||
                profileDropLoading || !incomingProfiles.isEmpty || authenticationChallenge != nil || showingAccountCredentials ||
                !username.isEmpty || !password.isEmpty || quickAccess.panel?.isVisible == true,
              sleeping: sleeping)
    }
    var menuStatusTitle: String {
        switch sessionState {
        case .connected: return L10n.text("已连接")
        case .connecting: return L10n.text("正在连接")
        case .authenticating: return L10n.text("等待身份验证")
        case .reconnecting: return L10n.text("正在重连")
        case .stopping: return L10n.text("正在断开与恢复")
        case .failed: return L10n.text("连接异常，请检查")
        case .disconnected: return L10n.text("未连接")
        }
    }
    var menuStatusSymbol: String {
        connected ? "checkmark.shield.fill" : sessionState == .failed ? "exclamationmark.shield" : connecting ? "arrow.triangle.2.circlepath" : "network"
    }
    func connectSelected(automatically: Bool = false, automationPermit: (() -> Bool)? = nil) async {
        if automatically {
            guard automationPermit?() == true,
                  !smartConnectionContext().occupied, helperStateVerified, helper.installationStatus == .enabled,
                  sessionState == .disconnected, activeProfileID == nil, !networkRecoveryRequired, !firewallRecoveryRequired else { return }
        } else { smartConnection.cancelPending() }
        guard !showingLanguageSettings && !showingKeyboardHelp && !showingPublicEgress, !showingConnectionHistory, profileHealthTarget == nil, !maintenanceInProgress, !profileTransferInProgress, !showingImportReport else { return }
        if BuildChannel.isLocal, LocalInstallation.isInstallationPending {
            message = helper.localInstallationIssue; if !automatically { showingSetup = true }; return
        }
        guard !busy, !connecting, !connected, !stopping, let selected else { return }
        smartConnection.willStartConnection()
        statusEpoch &+= 1
        let attempt = UUID(); connectionAttempt = attempt
        connectionStatus = L10n.text("connecting: 正在准备连接")
        busy = true
        defer { if connectionAttempt == attempt { busy = false } }
        localEvents.append(.starting)
        do {
            let text = try await store.runtimeConfig(for: selected)
            let validated = try ProfileSafety.validate(text)
            try ManagedRoutingPolicy.validate(validated, mode: selected.mode)
            if selected.mode == .chinaDirect && rules == nil {
                message = L10n.text("请先下载或导入中国 IPv4 规则。")
                connectionStatus = L10n.text("failed: 缺少中国 IPv4 规则")
                return
            }
            guard connectionAttempt == attempt, selectedID == selected.id else {
                if connectionAttempt == attempt { connectionStatus = L10n.text("disconnected: 所选配置已改变") }
                return
            }
            var connectionUsername = username, connectionPassword = password
            if automatically {
                guard automationPermit?() == true else { throw SmartConnectionError.cancelled }
                connectionUsername = ""; connectionPassword = ""
                if validated.requestsCredentials {
                    guard rememberCredentials, let secret = KeychainVault.load(id: selected.credentialID, allowInteraction: false),
                          !secret.username.isEmpty, !secret.password.isEmpty else { throw SmartConnectionError.needsCredentials }
                    connectionUsername = secret.username; connectionPassword = secret.password
                }
            } else {
                if rememberCredentials, let secret = KeychainVault.load(id: selected.credentialID) {
                    if username.isEmpty { username = secret.username }
                    if password.isEmpty && username == secret.username { password = secret.password }
                }
                if validated.requestsCredentials && (username.isEmpty || password.isEmpty) {
                    connectionStatus = L10n.text("disconnected: 等待输入身份验证信息")
                    showingAccountCredentials = true
                    return
                }
                if rememberCredentials && !password.isEmpty {
                    try KeychainVault.store(.init(username: username, password: password), id: selected.credentialID)
                }
                connectionUsername = username; connectionPassword = password
            }
            let rulesText = routingRuleText()
            guard connectionAttempt == attempt else { return }
            if automatically {
                guard automationPermit?() == true, selectedID == selected.id, profiles.contains(selected),
                      !smartConnectionContext(preparingAutomatic: true).occupied,
                      helperStateVerified, helper.installationStatus == .enabled,
                      activeProfileID == nil, !networkRecoveryRequired, !firewallRecoveryRequired else { throw SmartConnectionError.cancelled }
            }
            var connectionPreferences = sessionPreferences
            connectionPreferences.customRules = selected.mode == .original ? nil : try CustomRuleSet(selected.customRules).rules
            connectionHistory.observe(.begin(profileID: selected.id, attemptID: attempt))
            let result = await helper.connect(profile: text, profileID: selected.id,
                                              mode: selected.mode, rules: rulesText,
                                              username: connectionUsername, password: connectionPassword, preferences: connectionPreferences, attemptID: attempt)
            guard connectionAttempt == attempt else { return }
            if !automatically { password = "" } // Automatic attempts never mutate credential drafts.
            if result.hasPrefix("ERROR:") {
                connectionHistory.observe(.requestFailed(attemptID: attempt))
                message = result
                connectionStatus = "failed: \(result)"
            } else { await refreshConnectionStatus() }
        } catch {
            guard connectionAttempt == attempt else { return }
            if !automatically { password = "" }
            if automatically, let smartError = error as? SmartConnectionError, case .cancelled = smartError {
                connectionStatus = L10n.text("disconnected: 自动连接条件已改变")
            } else {
                message = automatically ? error.localizedDescription : L10n.format("配置未通过检查：{0}", [String(describing: error.localizedDescription)])
                connectionStatus = L10n.text("failed: 连接准备未完成")
            }
        }
    }
    func switchToSelected(expectedSession: QuickAccessSession? = nil) async {
        guard !maintenanceInProgress, !profileTransferInProgress, !showingImportReport else { return }
        guard !busy, let selected, connected, activeProfileID != selected.id else { return }
        busy = true
        if let expectedSession {
            guard let report = await helper.sessionReport(), expectedSession.matches(report),
                  selectedID == selected.id, profiles.contains(where: { $0.id == selected.id }) else {
                busy = false
                message = L10n.text("连接状态或所选配置已改变，未执行切换。")
                await refreshConnectionStatus()
                return
            }
        }
        smartConnection.expectDisconnect()
        let response: String
        if let expectedSession { response = await helper.disconnectSession(expectedSession) }
        else { response = await helper.disconnect() }
        if response != "Disconnected" {
            busy = false
            message = L10n.format("Cannot switch profiles until the old VPN has fully exited: {0}", [String(describing: response)])
            return
        }
        await refreshConnectionStatus()
        if !connectionStatus.hasPrefix("disconnected:") {
            busy = false
            message = L10n.text("The old VPN did not finish disconnecting. Profile switch cancelled.")
            return
        }
        busy = false
        guard selectedID == selected.id, profiles.contains(where: { $0.id == selected.id }) else {
            message = L10n.text("所选配置已改变，原 VPN 已安全断开，请重新选择连接。"); return
        }
        await connectSelected()
    }
    var quickAccessSession: QuickAccessSession? {
        guard connected, let profileID = activeProfileID, let attemptID = helperAttemptID else { return nil }
        return QuickAccessSession(profileID: profileID, attemptID: attemptID)
    }
    func quickAccessAction(for id: UUID) -> QuickAccessAction {
        guard profiles.contains(where: { $0.id == id }) else { return .blocked }
        if connected && id != activeProfileID && quickAccessSession == nil { return .blocked }
        return QuickAccessAction.resolve(state: sessionState, profileID: id, activeProfileID: activeProfileID,
            operationInProgress: showingLanguageSettings || showingKeyboardHelp || showingPublicEgress || showingConnectionHistory || profileHealthTarget != nil || showingProfileBackup || customRuleEditorProfile != nil || showingRouteExplanation || showingTroubleshooting || showingProfileIndexRecovery || routingModeSwitching || busy || maintenanceInProgress || backgroundServicesBusy || profileTransferInProgress || showingImportReport ||
                authenticationChallenge != nil || showingAccountCredentials,
            mayStart: canQuit)
    }
    func activateQuickProfile(_ id: UUID, replacing expectedSession: QuickAccessSession?) async {
        let action = quickAccessAction(for: id)
        guard (action == .connect && expectedSession == nil) ||
              (action == .requestSwitch && expectedSession != nil && quickAccessSession == expectedSession) else {
            message = L10n.text("连接状态已改变，请在主窗口确认后重试。"); return
        }
        guard helper.installationStatus == .enabled else { showingSetup = true; return }
        selectedID = id
        if action == .requestSwitch { await switchToSelected(expectedSession: expectedSession) }
        else { await connectSelected() }
    }
    func disconnect() async {
        smartConnection.pauseForManualDisconnect()
        connectionHistory.observe(.userStop)
        statusEpoch &+= 1
        guard !stopping else { return }
        let cancelledAttempt = connectionAttempt ?? helperAttemptID
        connectionAttempt = nil
        if connecting { localEvents.append(.cancelled) }
        connectionStatus = L10n.text("stopping: 正在停止连接并恢复网络")
        busy = true
        let response = await helper.disconnect(attemptID: cancelledAttempt)
        busy = maintenanceInProgress
        if response.hasPrefix("ERROR:") { message = response }
        localEvents.append(.stopped)
        await refreshConnectionStatus()
    }
    func respondToChallenge(_ challenge: AuthenticationChallenge, value: String) async {
        let response = await helper.submitChallenge(id: challenge.id, response: value)
        if response == "Accepted" {
            // A newer factor may have arrived while this XPC call awaited.
            if authenticationChallenge?.id == challenge.id { authenticationChallenge = nil }
        } else { message = response }
    }
    func refreshDiagnostics() async {
        let remote = helper.installationStatus == .enabled ? await helper.diagnosticEvents() : []
        eventHistory = (localEvents.events() + remote).sorted { $0.date < $1.date }
    }
    func exportDiagnostics() async {
        await refreshDiagnostics()
        // Explicitly constructed support fields; never serialize AppModel,
        // profile contents, command output, hostnames, IPs or Keychain values.
        let events = eventHistory.suffix(150).map {
            "\(ISO8601DateFormatter().string(from: $0.date)) [\($0.code.rawValue)] \($0.code.summary)"
        }.joined(separator: "\n")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let report = L10n.format("VPN Navigator {0}\nmacOS {1}\n状态：{2}\n配置数：{3}\nIPv4规则数：{4}\n\n本报告不包含地址、域名、配置、证书或凭据。\n\n{5}\n", [String(describing: version), String(describing: ProcessInfo.processInfo.operatingSystemVersionString), String(describing: sessionState.rawValue), String(describing: profiles.count), String(describing: rules?.routes.count ?? 0), String(describing: events)])
        let panel = NSSavePanel(); panel.nameFieldStringValue = "VPNNavigator-diagnostics.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try report.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { message = L10n.format("诊断报告保存失败：{0}", [String(describing: error.localizedDescription)]) }
    }
    func importRules(_ url: URL) async {
        guard !busy, !routingModeSwitching, !connecting, !stopping else { return }
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        busy = true; defer { busy = false }
        do {
            let candidate = try await updater.localCandidate(url)
            if connected {
                let response = await helper.updateRules(routingRuleText(candidate))
                guard response == "Rules applied" || response == "NO_ACTIVE_SPLIT" else {
                    message = response; return
                }
            }
            try await updater.commit(candidate)
            rules = candidate; ruleSnapshots = try await updater.snapshots()
            rulesUpdatedAt = try await updater.lastUpdated()
            message = L10n.format("已校验并导入 {0} 条 IPv4 规则。", [String(describing: candidate.routes.count)])
        } catch { message = L10n.format("规则导入失败，原规则已保留：{0}", [String(describing: error.localizedDescription)]) }
    }

    func prepareMaintenance(removeProfiles: Bool) async -> Bool {
        guard !maintenanceInProgress, !backgroundServicesBusy, profileMutations == 0, !busy || connecting else {
            message = L10n.text("请等待当前操作结束后再准备维护。"); return false
        }
        maintenanceInProgress = true; busy = true
        defer { maintenanceInProgress = false; busy = false }
        if helper.installationStatus == .enabled || !canQuit { await disconnect() }
        guard canQuit else { message = L10n.text("会话或网络恢复尚未完成，不能准备升级或卸载。"); return false }
        guard await unregisterNetworkServices() else { return false }
        do {
            try UserServices.setLogin(false)
            let statuses = [helper.installationStatus, UserServices.rulesStatus, UserServices.loginStatus]
            guard statuses.allSatisfy({ $0 == .notRegistered || $0 == .notFound }) else {
                message = L10n.text("后台助手、规则更新或登录启动仍未完全停用。"); return false
            }
            if removeProfiles {
                // Delete only this application's Keychain service, including
                // orphan entries. A Keychain error must never report success.
                try KeychainVault.removeAll()
                try await connectionHistory.clearForMaintenance()
                for profile in profiles { try await store.delete(id: profile.id) }
                selectedID = nil; username = ""; password = ""
                await load()
            }
        } catch {
            message = L10n.format("维护准备尚未完成：{0}", [String(describing: error.localizedDescription)]); return false
        }
        message = BuildChannel.isLocal ? L10n.text("后台服务已停用。可选择可信本地安装包升级，或运行管理员卸载包移除系统组件。默认保留配置。") : L10n.text("后台助手、规则更新与登录启动均已停用，可以升级或在 Finder 中移除应用。")
        return true
    }
    /// Local packages have no publisher certificate. Selection is an explicit
    /// user action; only macOS Installer can grant administrator authorization.
    func openLocalInstaller() {
        let repairing = canRepairInterruptedInstallation
        guard BuildChannel.isLocal, !maintenanceInProgress, canQuit || repairing,
              helper.installationStatus != .enabled else {
            message = L10n.text("请先完成升级与卸载准备。"); showingMaintenance = true; return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "pkg")!]
        panel.message = L10n.text("选择可信来源、与本机架构一致的 Local.pkg。此通道不验证发布者证书，请先核对来源及 SHA-256。系统安装器将请求管理员授权。")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.lastPathComponent.hasSuffix("-Local.pkg"),
              url.lastPathComponent.contains("-" + LocalInstallation.nativeArchitecture + "-") else {
            message = L10n.text("请选择与本机架构一致的本地版安装包（-Local.pkg）。"); return
        }
        if repairing {
            Task {
                do {
                    try await UserServices.disableRules()
                    try UserServices.setLogin(false)
                    guard canRepairInterruptedInstallation else { throw LocalInstallError.incomplete }
                    // This exception applies only to a validated administrator
                    // transaction barrier. Preinstall already stopped the old
                    // job; the new helper rejects VPN requests until commit.
                    // The trusted PKG independently checks root-owned journals.
                    guard NSWorkspace.shared.open(url) else { throw LocalInstallError.command }
                    repairExitAuthorized = true
                    NSApplication.shared.terminate(nil)
                } catch { message = L10n.format("无法交接安装修复：{0}", [String(describing: error.localizedDescription)]) }
            }
        } else if NSWorkspace.shared.open(url) { NSApplication.shared.terminate(nil) }
        else { message = L10n.text("无法打开安装包，请在 Finder 中打开。") }
    }
    func openLocalUninstaller() {
        guard !LocalInstallation.isInstallationPending else { message = L10n.text("请先修复未完成的安装，再准备卸载。"); return }
        guard BuildChannel.isLocal, !maintenanceInProgress, canQuit,
              helper.installationStatus != .enabled else { return }
        do {
            let approval = try LocalInstallation.load(allowRetired: true)
            guard approval.ownerUID == getuid() else { throw LocalInstallError.unsafe }
            if NSWorkspace.shared.open(LocalInstallation.uninstaller) { NSApplication.shared.terminate(nil) }
            else { throw LocalInstallError.command }
        } catch { message = L10n.format("无法打开卸载包：{0}", [String(describing: error.localizedDescription)]) }
    }
    var canUseProfileBackup: Bool {
        !ProcessInfo.processInfo.arguments.contains("--vpnnav-ui-demo-snapshot") &&
        profileOpenReady && profileIndexIssue == nil && !profileTransferInProgress && !maintenanceInProgress &&
        !backgroundServicesBusy && !busy && !routingModeSwitching && !showingImportReport && !profilePickerPresented
    }
    private var backupSessionSafe: Bool {
        helperStateVerified && sessionState == .disconnected && activeProfileID == nil &&
        !networkRecoveryRequired && !firewallRecoveryRequired && !maintenanceInProgress && !backgroundServicesBusy && !busy
    }
    var canRestoreProfileBackup: Bool { canUseProfileBackup && backupSessionSafe }
    func canUpdateProfile(_ id: UUID) -> Bool { canRestoreProfileBackup && profiles.contains(where: { $0.id == id }) }
    func showProfileHealth(_ id: UUID, updating: Bool = false) {
        guard !profileTransferInProgress, let profile = profiles.first(where: { $0.id == id }) else { return }
        quickAccess.hide(); smartConnection.cancelPending()
        profileUpdateRequested = updating; profileHealthTarget = profile
    }
    func previewProfileUpdate(id: UUID, from url: URL) async throws -> ProfileUpdatePreview {
        guard canUseProfileBackup else { throw ProfileUpdateFailure.pending }
        profileUpdateInProgress = true; profileMutations += 1
        defer { profileUpdateInProgress = false; profileMutations -= 1 }
        let result = try await store.previewUpdate(id: id, from: url)
        try Task.checkCancellation()
        return result
    }
    func applyProfileUpdate(_ preview: ProfileUpdatePreview) async throws {
        guard canUpdateProfile(preview.profile.id) else { throw ProfileUpdateFailure.pending }
        profileHealth.invalidate()
        profileUpdateInProgress = true; profileMutations += 1; smartConnection.cancelPending()
        defer { profileUpdateInProgress = false; profileMutations -= 1; profileHealth.requestRefresh() }
        await refreshConnectionStatus(); try Task.checkCancellation()
        guard backupSessionSafe else { throw ProfileUpdateFailure.pending }
        let updated = try await store.applyUpdate(preview)
        if let position = profiles.firstIndex(where: { $0.id == updated.id }) { profiles[position] = updated }
        profileSizes[updated.id] = preview.sourceByteCount
        if preview.identityChanged {
            username = ""; password = ""; KeychainVault.remove(id: preview.profile.credentialID)
        }
    }
    private func backupWork<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        let work = Task.detached(priority: .userInitiated) { try operation() }
        return try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
    }
    func createEncryptedBackup(password: String, to url: URL) async throws -> Int {
        guard canUseProfileBackup, url.pathExtension.lowercased() == "vpnnavbackup" else { throw ProfileBackupFailure.pendingRecovery }
        profileBackupInProgress = true; profileMutations += 1
        defer { profileBackupInProgress = false; profileMutations -= 1 }
        let snapshot = try await store.backupSnapshot()
        try Task.checkCancellation()
        let archive = try await backupWork { try EncryptedProfileBackup.seal(snapshot, password: password) }
        try Task.checkCancellation()
        // Cancellation is honoured before publication. Once the atomic write
        // commits, report success even if a cancellation races with its return.
        try await backupWork { try ProfileFileIO.write(archive, to: url, beforeCommit: { try Task.checkCancellation() }) }
        return snapshot.entries.count
    }
    func previewEncryptedBackup(at url: URL, password: String) async throws -> DecryptedProfileBackup {
        guard canUseProfileBackup else { throw ProfileBackupFailure.pendingRecovery }
        profileBackupInProgress = true; profileMutations += 1
        defer { profileBackupInProgress = false; profileMutations -= 1 }
        let snapshot = try await backupWork {
            let archive = try ProfileFileIO.read(url, maximumBytes: EncryptedProfileBackup.maximumBytes)
            return try EncryptedProfileBackup.open(archive, password: password)
        }
        try Task.checkCancellation()
        let current = try await store.list()
        try Task.checkCancellation()
        return DecryptedProfileBackup(snapshot: snapshot, existing: current)
    }
    func restoreEncryptedBackup(_ preview: DecryptedProfileBackup) async throws -> Int {
        guard canRestoreProfileBackup else { throw ProfileBackupFailure.pendingRecovery }
        profileBackupInProgress = true; profileMutations += 1
        defer { profileBackupInProgress = false; profileMutations -= 1 }
        await refreshConnectionStatus()
        try Task.checkCancellation()
        guard backupSessionSafe else { throw ProfileBackupFailure.pendingRecovery }
        let restored = try await store.restoreBackup(preview.snapshot, expecting: preview.existing)
        // No throwing work after the store's index publication.
        profiles = preview.existing + restored
        for (profile, entry) in zip(restored, preview.snapshot.entries) { profileSizes[profile.id] = entry.source.utf8.count }
        if sessionState == .disconnected, activeProfileID == nil { selectedID = restored.first?.id ?? selectedID }
        return restored.count
    }
    func exportProfile(kind: ProfileExportKind = .portable, for id: UUID? = nil) async {
        guard !maintenanceInProgress, !profileTransferInProgress,
              let target = id ?? selectedID, let profile = profiles.first(where: { $0.id == target }) else { return }
        profileExportInProgress = true; profileMutations += 1
        defer { profileExportInProgress = false; profileMutations -= 1 }
        do {
            let runtime = try await store.runtimeConfig(for: profile)
            let generated = try ProfileExport.render(runtime: runtime, kind: kind, mode: profile.mode, rules: rules, custom: try CustomRuleSet(profile.customRules))
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.init(filenameExtension: "ovpn")!]
            panel.nameFieldStringValue = ProfileExport.filename(name: profile.name, kind: kind)
            panel.message = kind == .portable ? L10n.text("文件可能包含证书和私钥，请妥善保存。应用内选定的分流策略在连接时生效。") : L10n.text("这是静态路由预览，可能包含证书和私钥，不代表当前系统路由。")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let granted = url.startAccessingSecurityScopedResource()
            defer { if granted { url.stopAccessingSecurityScopedResource() } }
            try await Task.detached(priority: .userInitiated) { try ProfileFileIO.write(generated, to: url) }.value
            message = kind == .portable ? L10n.text("已导出可迁移的配置，文件仅限当前用户读写。") : L10n.text("已导出静态路由预览，文件仅限当前用户读写。")
        } catch { message = L10n.format("导出失败：{0}", [String(describing: error.localizedDescription)]) }
    }
}

@main
struct VPNNavigatorApp: App {
    @NSApplicationDelegateAdaptor(ApplicationLifecycle.self) private var appDelegate
    @StateObject private var model = WorkspaceAccessibilitySelfTest.applicationModel()
    @StateObject private var workspaceCommands = WorkspaceCommandRouter()
    init() {
        if ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true", ProcessInfo.processInfo.arguments.contains(where: { $0.hasSuffix("self-test") }) {
            FileHandle.standardError.write(Data("UI application init reached\n".utf8))
        }

        if ProcessInfo.processInfo.arguments.contains("--vpnnav-localization-self-test") {
            Task {
                do { try LocalizationSelfTest.run(); Darwin.exit(0) }
                catch { print("Localization self-test failed: \(error)"); Darwin.exit(1) }
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--vpnnav-public-egress-self-test") {
            Task {
                do { try await PublicEgressSelfTest.run(); print("Public egress checks passed."); Darwin.exit(0) }
                catch { print("Public egress self-test failed: \(error.localizedDescription)"); Darwin.exit(1) }
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--vpnnav-connection-history-self-test") {
            Task {
                do { try await ConnectionHistorySelfTest.run(); print("Connection history and quality checks passed."); Darwin.exit(0) }
                catch { print("Connection history self-test failed: \(error.localizedDescription)"); Darwin.exit(1) }
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--vpnnav-profile-health-self-test") {
            Task {
                do { try await ProfileHealthSelfTest.run(); print("Profile health and update wizard checks passed."); Darwin.exit(0) }
                catch { print("Profile health self-test failed: \(error.localizedDescription)"); Darwin.exit(1) }
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--vpnnav-profile-backup-self-test") {
            Task { @MainActor in
                do { try await ProfileBackupSelfTest.run(); Darwin.exit(0) }
                catch { print("Encrypted backup self-test failed: \(error.localizedDescription)"); Darwin.exit(1) }
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--vpnnav-smart-connection-self-test") {
            Task { @MainActor in
                do { try await SmartConnectionSelfTest.run(); Darwin.exit(0) }
                catch { print("Smart connection self-test failed: \(error.localizedDescription)"); Darwin.exit(1) }
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--vpnnav-routing-tools-self-test") {
            Task {
                do { try await RoutingToolsSelfTest.run(); print("Routing tools checks passed."); Darwin.exit(0) }
                catch { print("Routing tools self-test failed: \(error.localizedDescription)"); Darwin.exit(1) }
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--vpnnav-profile-library-self-test") {
            Task {
                do { try await ProfileLibrarySelfTest.run(); print("Profile library checks passed."); Darwin.exit(0) }
                catch { print("Profile library self-test failed: \(error.localizedDescription)"); Darwin.exit(1) }
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--vpnnav-profile-recovery-self-test") {
            Task {
                do { try await ProfileRecoverySelfTest.run(); print("Profile index recovery checks passed."); Darwin.exit(0) }
                catch { print("Profile index recovery self-test failed: \(error.localizedDescription)"); Darwin.exit(1) }
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--vpnnav-routing-mode-self-test") {
            Task {
                do { try await RoutingModeSelfTest.run(); print("Routing mode model checks passed."); Darwin.exit(0) }
                catch { print("Routing mode self-test failed: \(error.localizedDescription)"); Darwin.exit(1) }
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--vpnnav-profile-transfer-self-test") {
            Task {
                do { try await ProfileTransferSelfTest.run(); print("Profile import model checks passed."); Darwin.exit(0) }
                catch { print("Profile import model self-test failed: \(error.localizedDescription)"); Darwin.exit(1) }
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--vpnnav-quick-access-self-test") {
            Task {
                do { try await QuickAccessSelfTest.run(); print("Quick access panel and global shortcut checks passed."); Darwin.exit(0) }
                catch { print("Quick access self-test failed: \(error.localizedDescription)"); Darwin.exit(1) }
            }
        }
        if BuildChannel.isLocal && ProcessInfo.processInfo.arguments.contains("--vpnnav-local-installation-state") {
            let diagnosticModel = AppModel()
            let transaction = try? LocalInstallation.pendingTransaction()
            let state: [String: Any] = ["pending": LocalInstallation.isInstallationPending,
                                       "phase": transaction?.phase.rawValue ?? "none",
                                       "repairAvailable": diagnosticModel.canRepairInterruptedInstallation,
                                       "status": diagnosticModel.installationIssue ?? "ready"]
            if let bytes = try? JSONSerialization.data(withJSONObject: state) {
                print(String(decoding: bytes, as: UTF8.self)); Darwin.exit(0)
            }
            Darwin.exit(1)
        }
        if BuildChannel.isLocal && ProcessInfo.processInfo.arguments.contains("--vpnnav-local-health-check") {
            Task { let result = await HelperClient.shared.ping(); print(result); Darwin.exit(result.hasPrefix("VPN Navigator Helper") ? 0 : 1) }
        }
        if BuildChannel.isLocal && ProcessInfo.processInfo.arguments.contains("--vpnnav-local-services-self-test") {
            Task {
                do {
                    guard await HelperClient.shared.ping() == "VPN Navigator Helper (local)" else { throw LocalInstallError.command }
                    try await BackgroundServicesSelfTest.run()
                    guard UserServices.rulesStatus == .notRegistered, UserServices.loginStatus == .notRegistered,
                          HelperClient.shared.installationStatus == .notRegistered else { throw LocalInstallError.command }
                    _ = try LocalInstallation.load(allowRetired: true)
                    print("Local user services and authenticated maintenance passed.")
                    Darwin.exit(0)
                } catch { print("Local maintenance self-test failed: \(error.localizedDescription)"); Darwin.exit(1) }
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--vpnnav-network-self-test") {
            Task {
                do {
                    try await NetworkProbeSelfTest.run()
                    print("Loopback TCP, DNS, ping, traceroute, timeout and cancellation passed.")
                    Darwin.exit(0)
                } catch {
                    print("Network probe self-test failed: \(error.localizedDescription)")
                    Darwin.exit(1)
                }
            }
        }
    }
    var body: some Scene {
        Window("VPN Navigator", id: "main") {
            MainView().environmentObject(model).environmentObject(workspaceCommands)
                .onAppear { appDelegate.model = model }
                .frame(minWidth: 1100, minHeight: 700)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(after: .newItem) {
                Button(L10n.text("快速打开…")) { model.quickAccess.toggle() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }
        MenuBarExtra {
            GlassMenuBarView().environmentObject(model)
        } label: {
            StatusBarLabel().environmentObject(model)
        }
        .menuBarExtraStyle(.window)
        Settings {
            SystemSettingsPane().environmentObject(model)
                .frame(minWidth: 650, minHeight: 620)
        }
    }
}

