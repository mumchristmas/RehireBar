import Foundation

@MainActor
final class RehireBarApplication {
    private let coordinator: AppCoordinator
    private let loginRegistrationEnabled: Bool
    private let loginItemManager: any LoginItemManaging
    private let approvalCoordinator: ConversationApprovalCoordinator?
    private let applicationMenu: any ApplicationMenuManaging

    init(
        coordinator: AppCoordinator,
        loginRegistrationEnabled: Bool,
        loginItemManager: any LoginItemManaging,
        approvalCoordinator: ConversationApprovalCoordinator? = nil,
        applicationMenu: any ApplicationMenuManaging = NoopApplicationMenuController()
    ) {
        self.coordinator = coordinator
        self.loginRegistrationEnabled = loginRegistrationEnabled
        self.loginItemManager = loginItemManager
        self.approvalCoordinator = approvalCoordinator
        self.applicationMenu = applicationMenu
    }

    static func makeProduction(
        loginRegistrationEnabled: Bool = true,
        activityMonitor: any ActivityMonitoring = CodexActivityMonitor(),
        presenter: any UsagePresenting = TouchBarPresenter(),
        loginItemManager: any LoginItemManaging = LoginItemManager(),
        statusCache: StatusCachePublisher? = nil,
        wakeMonitor: any WakeMonitoring = WorkspaceWakeMonitor(),
        statusOutputURL: URL? = nil,
        applicationMenu: (any ApplicationMenuManaging)? = nil
    ) -> RehireBarApplication {
        let defaults = UserDefaults.standard
        let selectedThread = SelectedThreadState(
            initialThreadID: defaults.string(forKey: SelectedThreadTracker.persistedThreadIDKey)
        )
        let selectedThreadTracker = SelectedThreadTracker(
            state: selectedThread,
            defaults: defaults
        )
        let approvalStore = ConversationApprovalStore()
        let focusedThreadMetadata = CodexThreadMetadataStore()
        // Catalog rows already carry their authoritative display title. Runtime
        // metadata enrichment needs only state_5 model/effort/rollout fields and
        // should not reopen the catalog database once per local row.
        let catalogThreadMetadata = CodexThreadMetadataStore(catalogDatabaseURL: nil)
        let usageProvider = CodexUsageProvider(
            primary: CodexAppServerClient(),
            fallback: SessionLogUsageProvider()
        )
        let desktopSnapshots = CodexDesktopThreadSnapshotCache()
        let appThreadStatuses = CodexDesktopLogStatusProvider()
        let rolloutSnapshots = SessionSnapshotCache()
        let currentSessionProvider = CurrentSessionProvider(
            selectedThread: selectedThread,
            metadata: focusedThreadMetadata,
            snapshots: rolloutSnapshots
        )
        let sessionCatalogProvider = CodexSessionCatalogProvider(
            selectedThread: selectedThread,
            approvalStore: approvalStore,
            desktopSnapshots: desktopSnapshots,
            appThreadStatuses: appThreadStatuses,
            threadMetadata: catalogThreadMetadata,
            rolloutSnapshots: rolloutSnapshots
        )
        let allSessions = CombinedSessionCollectionProvider(providers: [
            sessionCatalogProvider,
            AgentStatusDirectoryProvider(),
        ])
        let statusProvider = UsageOnlyStatusProvider(usage: usageProvider)
        let startupStatusProvider = FocusedSessionStatusProvider(
            session: currentSessionProvider
        )
        let liveStatusProvider = LiveSessionStatusProvider(
            session: currentSessionProvider,
            sessions: allSessions
        )
        let statusCache = statusCache ?? StatusCachePublisher()
        let statusPublisher: any StatusPublishing
        if let statusOutputURL {
            statusPublisher = StatusDiagnosticsPublisher(base: statusCache, outputURL: statusOutputURL)
        } else {
            statusPublisher = statusCache
        }
        let coordinator = AppCoordinator(
            activityMonitor: activityMonitor,
            statusFetcher: statusProvider,
            startupStatusFetcher: startupStatusProvider,
            liveStatusFetcher: liveStatusProvider,
            presenter: presenter,
            statusPublisher: statusPublisher,
            statusCache: statusCache,
            selectedThreadMonitor: selectedThreadTracker,
            dataChangeMonitor: CodexDataChangeMonitor(),
            relauncher: ApplicationRelauncher(),
            wakeMonitor: wakeMonitor,
            logger: { NSLog("%@", $0) }
        )
        let approvalCoordinator = (presenter as? TouchBarPresenter).map {
            ConversationApprovalCoordinator(store: approvalStore, presenter: $0)
        }
        let resolvedApplicationMenu = applicationMenu ?? ApplicationMenuController(
            onShow: { [weak coordinator] in coordinator?.restoreFromApplicationMenu() }
        )
        return RehireBarApplication(
            coordinator: coordinator,
            loginRegistrationEnabled: loginRegistrationEnabled,
            loginItemManager: loginItemManager,
            approvalCoordinator: approvalCoordinator,
            applicationMenu: resolvedApplicationMenu
        )
    }

    func start() {
        coordinator.start()
        approvalCoordinator?.start()
        applicationMenu.start()
        if loginRegistrationEnabled {
            loginItemManager.register()
        }
    }

    func stop() {
        approvalCoordinator?.stop()
        applicationMenu.stop()
        coordinator.stop()
    }
}
