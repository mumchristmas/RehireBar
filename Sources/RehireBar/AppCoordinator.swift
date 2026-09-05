import AgentStatusCore
import Foundation

@MainActor
protocol ActivityMonitoring: AnyObject {
    func start(_ handler: @escaping @MainActor @Sendable (Bool) -> Void)
    func stop()
}

@MainActor
protocol UsagePresenting: AnyObject {
    func preparePersistentAccess()
    func activatePersistentAccess()
    func show(_ snapshot: UsageSnapshot)
    func showStatus(_ status: TouchBarStatusSnapshot)
    func showUnavailable()
    func markRenderedStatusStale()
    func represent() -> Bool
    func resetCompositionAndRepresent() -> Bool
    func hide()
}

@MainActor
protocol StatusCacheLoading: AnyObject {
    func loadStatusCache() -> StatusCacheSnapshot
}

@MainActor
protocol ManualRefreshBinding: AnyObject {
    var onManualRefresh: (@MainActor @Sendable () -> Void)? { get set }
}

@MainActor
protocol PresentationRestoreBinding: AnyObject {
    var onExplicitRestore: (@MainActor @Sendable () -> Void)? { get set }
}

extension UsagePresenting {
    func preparePersistentAccess() {}
    func activatePersistentAccess() {}

    func showStatus(_ status: TouchBarStatusSnapshot) {
        if let usage = status.usage { show(usage) }
        else { showUnavailable() }
    }

    func markRenderedStatusStale() {}
    func represent() -> Bool { true }
    func resetCompositionAndRepresent() -> Bool { true }
}

@MainActor
protocol RefreshCancellation: AnyObject {
    func cancel()
}

@MainActor
protocol RefreshScheduling: AnyObject {
    func scheduleRepeating(
        every interval: TimeInterval,
        _ handler: @escaping @MainActor @Sendable () -> Void
    ) -> any RefreshCancellation

    func scheduleOnce(
        after interval: TimeInterval,
        _ handler: @escaping @MainActor @Sendable () -> Void
    ) -> any RefreshCancellation
}

@MainActor
final class AppCoordinator {
    private static let fullRefreshInterval: TimeInterval = 30
    private static let initialLiveRefreshInterval: TimeInterval = 5
    private static let activeLiveRefreshInterval: TimeInterval = 2.5
    private static let idleLiveRefreshInterval: TimeInterval = 12
    private static let maximumLiveFailureBackoff: TimeInterval = 60

    private let activityMonitor: any ActivityMonitoring
    private let fetcher: any StatusFetching
    private let startupFetcher: (any StatusFetching)?
    private let liveFetcher: (any StatusFetching)?
    private let presenter: any UsagePresenting
    private let scheduler: any RefreshScheduling
    private let statusPublisher: any StatusPublishing
    private let statusCache: any StatusCacheLoading
    private let selectedThreadMonitor: any SelectedThreadMonitoring
    private let dataChangeMonitor: any DataChangeMonitoring
    private let relauncher: any ApplicationRelaunching
    private let wakeMonitor: any WakeMonitoring
    private let logger: @MainActor (String) -> Void
    private let now: @MainActor () -> Date

    private var refreshCancellation: (any RefreshCancellation)?
    private var liveRefreshCancellation: (any RefreshCancellation)?
    private var healthCancellation: (any RefreshCancellation)?
    private var fetchTask: Task<Void, Never>?
    private var startupFetchTask: Task<Void, Never>?
    private var liveFetchTask: Task<Void, Never>?
    private var lastStatus: TouchBarStatusSnapshot?
    private var isActive = false
    private var isRefreshRunning = false
    private var activityGeneration = 0
    private var liveRequestGeneration = 0
    private var consecutiveLiveFailures = 0
    private var liveRefreshPending = false
    private var hasAttemptedStartupFetch = false
    private var hasStarted = false
    private var recovery = TouchBarRecoveryController()

    init(
        activityMonitor: any ActivityMonitoring,
        statusFetcher: any StatusFetching,
        startupStatusFetcher: (any StatusFetching)? = nil,
        liveStatusFetcher: (any StatusFetching)? = nil,
        presenter: any UsagePresenting,
        scheduler: any RefreshScheduling = TimerRefreshScheduler(),
        statusPublisher: any StatusPublishing = NoopStatusPublisher(),
        statusCache: any StatusCacheLoading = NoopStatusCache(),
        selectedThreadMonitor: any SelectedThreadMonitoring = NoopSelectedThreadMonitor(),
        dataChangeMonitor: any DataChangeMonitoring = NoopDataChangeMonitor(),
        relauncher: any ApplicationRelaunching = NoopApplicationRelauncher(),
        wakeMonitor: any WakeMonitoring = NoopWakeMonitor(),
        logger: @escaping @MainActor (String) -> Void = { _ in },
        now: @escaping @MainActor () -> Date = { .now }
    ) {
        self.activityMonitor = activityMonitor
        self.fetcher = statusFetcher
        self.startupFetcher = startupStatusFetcher
        self.liveFetcher = liveStatusFetcher
        self.presenter = presenter
        self.scheduler = scheduler
        self.statusPublisher = statusPublisher
        self.statusCache = statusCache
        self.selectedThreadMonitor = selectedThreadMonitor
        self.dataChangeMonitor = dataChangeMonitor
        self.relauncher = relauncher
        self.wakeMonitor = wakeMonitor
        self.logger = logger
        self.now = now
        if let binding = presenter as? any ManualRefreshBinding {
            binding.onManualRefresh = { [weak self] in
                self?.refreshNow(preserveRenderedStatusOnFailure: true)
            }
        }
        if let binding = presenter as? any PresentationRestoreBinding {
            binding.onExplicitRestore = { [weak self] in
                self?.handleExplicitRestore()
            }
        }
    }

    convenience init(
        activityMonitor: any ActivityMonitoring,
        fetcher: any UsageFetching,
        presenter: any UsagePresenting,
        scheduler: any RefreshScheduling = TimerRefreshScheduler(),
        statusPublisher: any StatusPublishing = NoopStatusPublisher(),
        statusCache: any StatusCacheLoading = NoopStatusCache(),
        selectedThreadMonitor: any SelectedThreadMonitoring = NoopSelectedThreadMonitor(),
        dataChangeMonitor: any DataChangeMonitoring = NoopDataChangeMonitor(),
        wakeMonitor: any WakeMonitoring = NoopWakeMonitor()
    ) {
        self.init(
            activityMonitor: activityMonitor,
            statusFetcher: UsageOnlyStatusProvider(usage: fetcher),
            presenter: presenter,
            scheduler: scheduler,
            statusPublisher: statusPublisher,
            statusCache: statusCache,
            selectedThreadMonitor: selectedThreadMonitor,
            dataChangeMonitor: dataChangeMonitor,
            wakeMonitor: wakeMonitor
        )
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        presenter.preparePersistentAccess()
        let cached = statusCache.loadStatusCache()
        if cached.hasDisplayValues {
            let status = TouchBarStatusSnapshot(cached: cached)
            lastStatus = status
            presenter.showStatus(status)
        }
        selectedThreadMonitor.start { [weak self] in
            guard let self else { return }
            if self.liveFetcher != nil {
                self.requestLiveRefresh()
            } else {
                self.refresh(preserveRenderedStatusOnFailure: true)
            }
        }
        if liveFetcher != nil {
            dataChangeMonitor.start { [weak self] in
                self?.requestLiveRefresh()
            }
        }
        activityMonitor.start { [weak self] isActive in
            self?.selectedThreadMonitor.setCodexActive(isActive)
            self?.setActive(isActive)
        }
        wakeMonitor.start { [weak self] in self?.handleWake() }
        healthCancellation = scheduler.scheduleRepeating(
            every: TouchBarRecoveryController.healthInterval
        ) { [weak self] in
            self?.runHealthCheck()
        }
        if !isRefreshRunning {
            recovery.observe(.manualInteraction)
            recordRecovery(presenter.represent(), action: .refreshAndRepresent)
            startRefreshPipeline(preserveRenderedStatusOnFailure: cached.hasDisplayValues)
        }
    }

    func stop() {
        guard hasStarted else { return }
        hasStarted = false
        activityMonitor.stop()
        selectedThreadMonitor.stop()
        dataChangeMonitor.stop()
        wakeMonitor.stop()
        isActive = false
        isRefreshRunning = false
        activityGeneration += 1
        fetchTask?.cancel()
        fetchTask = nil
        startupFetchTask?.cancel()
        startupFetchTask = nil
        liveFetchTask?.cancel()
        liveFetchTask = nil
        liveRefreshPending = false
        consecutiveLiveFailures = 0
        refreshCancellation?.cancel()
        liveRefreshCancellation?.cancel()
        liveRefreshCancellation = nil
        healthCancellation?.cancel()
        healthCancellation = nil
        presenter.hide()
    }

    private func setActive(_ active: Bool) {
        guard hasStarted else { return }
        guard active != isActive else { return }
        isActive = active

        if active {
            presenter.activatePersistentAccess()
            if !isRefreshRunning {
                startRefreshPipeline(preserveRenderedStatusOnFailure: false)
            }
        }
    }

    private func handleWake() {
        guard hasStarted else { return }
        activityGeneration += 1
        startupFetchTask?.cancel()
        startupFetchTask = nil
        fetchTask?.cancel()
        fetchTask = nil
        liveFetchTask?.cancel()
        liveFetchTask = nil
        liveRequestGeneration += 1
        liveRefreshPending = false
        consecutiveLiveFailures = 0
        cancelScheduledLiveRefresh()
        recovery.observe(.manualInteraction)
        recordRecovery(presenter.represent(), action: .refreshAndRepresent)
        startRefreshPipeline(preserveRenderedStatusOnFailure: true)
    }

    private func handleExplicitRestore() {
        guard hasStarted else { return }
        recovery.observe(.manualInteraction)
        recovery.observe(.presentationSucceeded)
        refreshNow(preserveRenderedStatusOnFailure: true)
    }

    func restoreFromApplicationMenu() {
        guard hasStarted else { return }
        recovery.observe(.manualInteraction)
        recordRecovery(presenter.represent(), action: .refreshAndRepresent)
        refreshNow(preserveRenderedStatusOnFailure: true)
    }

    private func refreshNow(preserveRenderedStatusOnFailure: Bool) {
        guard hasStarted else { return }
        if preserveRenderedStatusOnFailure {
            presenter.markRenderedStatusStale()
        }
        refreshLive(replacingInFlight: true)
        refresh(preserveRenderedStatusOnFailure: preserveRenderedStatusOnFailure)
    }

    private func startRefreshPipeline(preserveRenderedStatusOnFailure: Bool) {
        guard hasStarted else { return }
        if preserveRenderedStatusOnFailure {
            presenter.markRenderedStatusStale()
        }
        isRefreshRunning = true
        if refreshCancellation == nil {
            refreshCancellation = scheduler.scheduleRepeating(every: Self.fullRefreshInterval) { [weak self] in
                self?.refresh()
            }
        }
        // Render the focused task first on the initial launch. The complete task
        // catalog follows without holding the first useful card behind IPC work.
        if !hasAttemptedStartupFetch, let startupFetcher {
            hasAttemptedStartupFetch = true
            refreshStartup(using: startupFetcher)
        } else if startupFetchTask == nil {
            refreshLive(replacingInFlight: true)
            refresh(preserveRenderedStatusOnFailure: preserveRenderedStatusOnFailure)
        }
    }

    private func runHealthCheck() {
        guard hasStarted else { return }
        expireRetainedEvidence()
        let action = recovery.evaluate()
        switch action {
        case .none:
            break
        case .refreshAndRepresent:
            recordRecovery(presenter.represent(), action: action)
        case .resetCompositionAndRepresent:
            recordRecovery(presenter.resetCompositionAndRepresent(), action: action)
        case .relaunchApplication:
            recovery.observe(.relaunchRequested)
            relauncher.relaunch()
        }
    }

    private func recordRecovery(_ succeeded: Bool, action: TouchBarRecoveryAction) {
        if succeeded {
            recovery.observe(.presentationSucceeded)
        } else {
            recovery.observe(.recoveryFailed(action))
        }
    }

    func refresh(preserveRenderedStatusOnFailure: Bool = false) {
        guard hasStarted, isActive || isRefreshRunning else { return }
        guard fetchTask == nil else { return }
        let generation = activityGeneration
        let fetcher = self.fetcher

        fetchTask = Task { [weak self] in
            let result: Result<TouchBarStatusSnapshot, Error>
            do {
                result = .success(try await fetcher.fetchStatus())
            } catch {
                result = .failure(error)
            }

            guard let self,
                  !Task.isCancelled,
                  self.isActive || self.isRefreshRunning,
                  self.activityGeneration == generation else { return }

            self.fetchTask = nil

            switch result {
            case .success(let snapshot):
                self.publishMerged(snapshot)
            case .failure(let error):
                self.report(error, source: "quota")
                if !preserveRenderedStatusOnFailure {
                    if let previous = self.lastStatus {
                        let status = previous.markingUsageStale()
                        self.lastStatus = status
                        self.statusPublisher.publish(status)
                        self.presenter.showStatus(status)
                    } else {
                        self.presenter.showUnavailable()
                    }
                }
            }
        }
    }

    private func refreshStartup(using startupFetcher: any StatusFetching) {
        let generation = activityGeneration
        startupFetchTask?.cancel()
        startupFetchTask = Task { [weak self] in
            let result: Result<TouchBarStatusSnapshot, Error>
            do { result = .success(try await startupFetcher.fetchStatus()) }
            catch { result = .failure(error) }
            guard let self,
                  !Task.isCancelled,
                  self.hasStarted,
                  self.activityGeneration == generation else { return }
            self.startupFetchTask = nil
            switch result {
            case .success(let startupStatus): self.publishMerged(startupStatus)
            case .failure(let error): self.report(error, source: "startup")
            }
            self.refresh(preserveRenderedStatusOnFailure: self.lastStatus != nil)
            self.refreshLive()
        }
    }

    private func refreshLive(replacingInFlight: Bool = false) {
        guard hasStarted,
              isActive || isRefreshRunning,
              let liveFetcher else { return }
        if liveFetchTask != nil {
            guard replacingInFlight else { return }
            liveFetchTask?.cancel()
            liveFetchTask = nil
            liveRefreshPending = false
        }
        cancelScheduledLiveRefresh()
        let generation = activityGeneration
        liveRequestGeneration += 1
        let requestGeneration = liveRequestGeneration
        liveFetchTask = Task { [weak self] in
            let result: Result<TouchBarStatusSnapshot, Error>
            do { result = .success(try await liveFetcher.fetchStatus()) }
            catch { result = .failure(error) }

            guard let self,
                  !Task.isCancelled,
                  self.isActive || self.isRefreshRunning,
                  self.activityGeneration == generation,
                  self.liveRequestGeneration == requestGeneration else { return }
            self.liveFetchTask = nil
            switch result {
            case .success(let liveStatus):
                self.consecutiveLiveFailures = 0
                self.publishMerged(liveStatus)
            case .failure(let error):
                self.consecutiveLiveFailures += 1
                self.report(error, source: "task")
                self.expireRetainedEvidence()
            }
            if self.liveRefreshPending {
                self.liveRefreshPending = false
                self.refreshLive()
            } else {
                self.scheduleAdaptiveLiveRefresh()
            }
        }
    }

    private func requestLiveRefresh() {
        guard hasStarted, liveFetcher != nil else { return }
        cancelScheduledLiveRefresh()
        if liveFetchTask != nil {
            liveRefreshPending = true
        } else {
            refreshLive()
        }
    }

    private func scheduleAdaptiveLiveRefresh() {
        guard hasStarted,
              liveFetcher != nil,
              liveRefreshCancellation == nil else { return }
        let baseInterval: TimeInterval
        if consecutiveLiveFailures > 0 {
            let exponent = min(consecutiveLiveFailures - 1, 6)
            baseInterval = min(
                Self.maximumLiveFailureBackoff,
                Self.initialLiveRefreshInterval * pow(2, Double(exponent))
            )
        } else if let lastStatus, !lastStatus.sessions.isEmpty {
            let hasActiveSession = lastStatus.sessions.contains {
                $0.executionState == .working
                    || $0.executionState == .syncing
                    || $0.executionState == .waiting
                    || $0.isCompactingContext
            }
            if hasActiveSession {
                baseInterval = Self.activeLiveRefreshInterval
            } else if lastStatus.sessions.contains(where: { $0.executionState == .unknown }) {
                baseInterval = Self.initialLiveRefreshInterval
            } else {
                baseInterval = Self.idleLiveRefreshInterval
            }
        } else {
            baseInterval = Self.initialLiveRefreshInterval
        }
        liveRefreshCancellation = scheduler.scheduleOnce(after: baseInterval) { [weak self] in
            guard let self else { return }
            self.liveRefreshCancellation = nil
            self.refreshLive()
        }
    }

    private func cancelScheduledLiveRefresh() {
        liveRefreshCancellation?.cancel()
        liveRefreshCancellation = nil
    }

    private func publishMerged(_ fresh: TouchBarStatusSnapshot) {
        let previous = lastStatus
        let replacesSessions = fresh.includesSessions
        let status = TouchBarStatusSnapshot(
            usage: fresh.usage ?? previous?.usage,
            session: replacesSessions ? fresh.session : previous?.session,
            sessions: replacesSessions ? fresh.sessions : previous?.sessions
        )
        lastStatus = status
        statusPublisher.publish(status)
        presenter.showStatus(status)
    }

    private func expireRetainedEvidence() {
        guard let lastStatus else { return }
        let referenceDate = now()
        let status = TouchBarStatusSnapshot(
            usage: lastStatus.usage,
            session: lastStatus.session?.expiringEvidence(at: referenceDate),
            sessions: lastStatus.includesSessions
                ? lastStatus.sessions.map { $0.expiringEvidence(at: referenceDate) } : nil
        )
        guard status != lastStatus else { return }
        self.lastStatus = status
        statusPublisher.publish(status)
        presenter.showStatus(status)
    }

    private func report(_ error: Error, source: String) {
        logger("\(source) refresh failed [\(String(describing: type(of: error)))]")
    }
}

@MainActor
private final class NoopStatusPublisher: StatusPublishing {
    func publish(_ status: TouchBarStatusSnapshot) {}
}

@MainActor
private final class NoopStatusCache: StatusCacheLoading {
    func loadStatusCache() -> StatusCacheSnapshot { .unavailable }
}

@MainActor
final class TimerRefreshScheduler: RefreshScheduling {
    func scheduleRepeating(
        every interval: TimeInterval,
        _ handler: @escaping @MainActor @Sendable () -> Void
    ) -> any RefreshCancellation {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            Task { @MainActor in
                handler()
            }
        }
        // The system-modal Touch Bar can keep the app in an event-tracking run-loop
        // mode. Common mode keeps status refreshes alive while that UI is active.
        RunLoop.main.add(timer, forMode: .common)
        return TimerRefreshCancellation(timer: timer)
    }

    func scheduleOnce(
        after interval: TimeInterval,
        _ handler: @escaping @MainActor @Sendable () -> Void
    ) -> any RefreshCancellation {
        let timer = Timer(timeInterval: interval, repeats: false) { _ in
            Task { @MainActor in handler() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return TimerRefreshCancellation(timer: timer)
    }
}

@MainActor
private final class TimerRefreshCancellation: RefreshCancellation {
    private var timer: Timer?

    init(timer: Timer) {
        self.timer = timer
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }
}
