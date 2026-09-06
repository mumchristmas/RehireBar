import Foundation
import XCTest
@testable import AgentStatusCore
@testable import RehireBar

@MainActor
final class AppCoordinatorTests: XCTestCase {
    func testOrderPreferenceReordersRetainedTasksAndDiagnosticsWithoutRestoringBar() async {
        let suiteName = "RehireBarTests.SortMode.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suiteName)!
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let now = Date.now
        let tasks = ["run-a", "run-b", "run-c", "wait"].map { id in
            CurrentSessionSnapshot(
                sessionID: id, threadID: id, usedTokens: 0, contextWindow: 0,
                model: nil, effort: nil, observedAt: now,
                executionState: id == "wait" ? .waiting : .working
            )
        }
        let presenter = FakeTouchBarStatusPresenter()
        let publisher = FakeStatusPublisher()
        let coordinator = AppCoordinator(
            activityMonitor: FakeActivityMonitor(),
            statusFetcher: FakeStatusFetcher(results: [.init(usage: nil, session: tasks.first, sessions: tasks)]),
            presenter: presenter, scheduler: FakeRefreshScheduler(), statusPublisher: publisher,
            now: { now },
            sortMode: { SessionSortMode(preference: preferences.string(forKey: SessionSortMode.preferenceKey)) }
        )
        coordinator.start()
        await waitUntil { presenter.statuses.count == 1 }
        let restoreCount = presenter.representCount
        XCTAssertEqual(presenter.statuses.last?.sessions.first?.threadID, "run-a")

        preferences.set(SessionSortMode.waitingFirst.rawValue, forKey: SessionSortMode.preferenceKey)
        coordinator.refreshTaskOrder()

        XCTAssertEqual(presenter.statuses.last?.sessions.first?.threadID, "wait")
        XCTAssertEqual(presenter.statuses.last?.sessions.count, 4)
        XCTAssertEqual(presenter.statuses.last?.session?.threadID, "run-a")
        XCTAssertEqual(publisher.statuses.last, presenter.statuses.last)
        XCTAssertEqual(presenter.representCount, restoreCount)
        preferences.set(SessionSortMode.runningFirst.rawValue, forKey: SessionSortMode.preferenceKey)
        coordinator.refreshTaskOrder()
        XCTAssertEqual(presenter.statuses.last?.sessions.first?.threadID, "run-a")
        coordinator.stop()
    }

    func testEmptyTaskUpdateRemovesCardsButKeepsQuota() async {
        let task = CurrentSessionSnapshot(
            sessionID: "removed-task", usedTokens: 0, contextWindow: 0,
            model: nil, effort: nil, observedAt: .now
        )
        let usage = snapshot(observedAt: 1)
        let live = FakeStatusFetcher(results: [
            .init(usage: nil, session: task), .init(usage: nil, session: nil, sessions: []),
        ])
        let presenter = FakeTouchBarStatusPresenter()
        let scheduler = FakeRefreshScheduler()
        let coordinator = AppCoordinator(
            activityMonitor: FakeActivityMonitor(),
            statusFetcher: FakeStatusFetcher(results: [.init(usage: usage, session: nil)]),
            liveStatusFetcher: live, presenter: presenter, scheduler: scheduler
        )
        coordinator.start()
        await waitUntil { presenter.statuses.count == 2 }

        scheduler.fireLive()
        await waitUntil { presenter.statuses.count == 3 }

        XCTAssertEqual(presenter.statuses.last?.sessions, [])
        XCTAssertNil(presenter.statuses.last?.session)
        XCTAssertEqual(presenter.statuses.last?.usage, usage)
        coordinator.stop()
    }

    func testHealthCheckExpiresActiveEvidenceWithoutReopeningCollapsedBar() async {
        var now = Date(timeIntervalSince1970: 2_000)
        let task = CurrentSessionSnapshot(
            sessionID: "disconnected", threadID: "task", title: "Keep my title",
            usedTokens: 20, contextWindow: 100, model: "example", effort: "high",
            observedAt: now, activeSince: now, isCompactingContext: true,
            providerID: "example-agent", hostID: "remote", hostKind: .unknown("remote"),
            executionStateObservedAt: now, executionState: .working
        )
        let presenter = FakeTouchBarStatusPresenter()
        let scheduler = FakeRefreshScheduler()
        let coordinator = AppCoordinator(
            activityMonitor: FakeActivityMonitor(),
            statusFetcher: FakeStatusFetcher(results: [.init(usage: nil, session: task)]),
            presenter: presenter, scheduler: scheduler, now: { now }
        )
        coordinator.start()
        await waitUntil { presenter.statuses.count == 1 }
        let restoreCount = presenter.representCount

        now = now.addingTimeInterval(31)
        scheduler.fireHealthCheck()

        XCTAssertEqual(presenter.statuses.last?.session?.executionState, .unknown)
        XCTAssertEqual(presenter.statuses.last?.session?.isCompactingContext, false)
        XCTAssertNil(presenter.statuses.last?.session?.activeSince)
        XCTAssertEqual(presenter.statuses.last?.session?.identity, task.identity)
        XCTAssertEqual(presenter.statuses.last?.session?.title, "Keep my title")
        XCTAssertEqual(presenter.statuses.last?.session?.model, "example")
        XCTAssertEqual(presenter.representCount, restoreCount)
        now = now.addingTimeInterval(300)
        scheduler.fireHealthCheck()
        XCTAssertNil(presenter.statuses.last?.session?.model)
        XCTAssertEqual(presenter.statuses.last?.session?.contextWindow, 0)
        XCTAssertEqual(presenter.representCount, restoreCount)
        coordinator.stop()
    }

    func testQuotaFailureKeepsTaskCardsAndMarksQuotaStale() async {
        let task = CurrentSessionSnapshot(
            sessionID: "healthy-task", usedTokens: 0, contextWindow: 0,
            model: nil, effort: nil, observedAt: .now
        )
        let full = FailingLiveStatusFetcher(results: [
            .success(.init(usage: snapshot(observedAt: 1), session: task)),
            .failure(UsageError.unavailable),
        ])
        let presenter = FakeTouchBarStatusPresenter()
        let scheduler = FakeRefreshScheduler()
        let coordinator = AppCoordinator(
            activityMonitor: FakeActivityMonitor(), statusFetcher: full,
            presenter: presenter, scheduler: scheduler
        )
        coordinator.start()
        await waitUntil { presenter.statuses.count == 1 }

        scheduler.fire()
        await waitUntil { presenter.statuses.count == 2 }

        XCTAssertEqual(presenter.statuses.last?.session, task)
        XCTAssertEqual(presenter.statuses.last?.usage?.isStale, true)
        XCTAssertEqual(presenter.unavailableCount, 0)
        coordinator.stop()
    }

    func testWakeDuringStartupDoesNotStrandLiveRefreshOrPublishOldResult() async {
        let startup = SuspendedStartupFetcher()
        let fresh = CurrentSessionSnapshot(
            sessionID: "after-wake", usedTokens: 0, contextWindow: 0,
            model: nil, effort: nil, observedAt: .now
        )
        let full = FakeStatusFetcher(results: [.init(usage: snapshot(observedAt: 1), session: nil)])
        let live = FakeStatusFetcher(results: [.init(usage: nil, session: fresh)])
        let presenter = FakeTouchBarStatusPresenter()
        let wake = FakeWakeMonitor()
        let coordinator = AppCoordinator(
            activityMonitor: FakeActivityMonitor(), statusFetcher: full,
            startupStatusFetcher: startup, liveStatusFetcher: live,
            presenter: presenter, scheduler: FakeRefreshScheduler(), wakeMonitor: wake
        )
        coordinator.start()
        await waitUntil { await startup.isWaiting }

        wake.emit()
        await waitUntil {
            let fullCount = await full.fetchCount
            let liveCount = await live.fetchCount
            return fullCount == 1 && liveCount == 1 && presenter.statuses.count == 2
        }
        await startup.finish()
        await drainTasks()

        XCTAssertEqual(presenter.statuses.last?.session?.sessionID, "after-wake")
        XCTAssertFalse(presenter.statuses.contains { $0.session?.sessionID == "before-wake" })
        coordinator.stop()
    }

    func testStartupPublishesFocusedTaskBeforeQuotaAndCompleteCatalog() async {
        let focused = CurrentSessionSnapshot(
            sessionID: "focused",
            threadID: "focused-thread",
            usedTokens: 10,
            contextWindow: 100,
            model: "gpt-5.6-sol",
            effort: "high",
            observedAt: .now
        )
        let background = CurrentSessionSnapshot(
            sessionID: "background",
            threadID: "background-thread",
            usedTokens: 20,
            contextWindow: 100,
            model: "gpt-5.6-luna",
            effort: "medium",
            observedAt: .now
        )
        let usage = snapshot(observedAt: 1)
        let startup = FakeStatusFetcher(results: [.init(usage: nil, session: focused)])
        let full = FakeStatusFetcher(results: [.init(usage: usage, session: nil)])
        let live = FakeStatusFetcher(results: [
            .init(usage: nil, session: focused, sessions: [focused, background]),
        ])
        let presenter = FakeTouchBarStatusPresenter()
        let coordinator = AppCoordinator(
            activityMonitor: FakeActivityMonitor(),
            statusFetcher: full,
            startupStatusFetcher: startup,
            liveStatusFetcher: live,
            presenter: presenter,
            scheduler: FakeRefreshScheduler()
        )

        coordinator.start()
        await waitUntil {
            let startupCount = await startup.fetchCount
            let fullCount = await full.fetchCount
            let liveCount = await live.fetchCount
            return startupCount == 1 && fullCount == 1 && liveCount == 1
                && presenter.statuses.count == 3
        }

        XCTAssertEqual(presenter.statuses.first?.sessions.map(\.sessionID), ["focused"])
        XCTAssertNil(presenter.statuses.first?.usage)
        XCTAssertTrue(presenter.statuses.dropFirst().allSatisfy {
            $0.sessions.contains { $0.sessionID == "focused" }
        })
        XCTAssertEqual(presenter.statuses.last?.usage, usage)
        XCTAssertEqual(presenter.statuses.last?.sessions.map(\.sessionID), ["background", "focused"])
        coordinator.stop()
    }

    func testUnresolvedTasksKeepDiscoveryCadenceWithoutRefetchingQuota() async {
        let usage = snapshot(observedAt: 1)
        let firstSession = CurrentSessionSnapshot(
            sessionID: "first", usedTokens: 10, contextWindow: 100,
            model: "gpt-5.6-sol", effort: "high", observedAt: .now
        )
        let updatedSession = CurrentSessionSnapshot(
            sessionID: "updated", usedTokens: 25, contextWindow: 100,
            model: "gpt-5.6-terra", effort: "low", observedAt: .now
        )
        let latestSession = CurrentSessionSnapshot(
            sessionID: "latest", usedTokens: 40, contextWindow: 100,
            model: "gpt-5.6-terra", effort: "medium", observedAt: .now
        )
        let full = FakeStatusFetcher(results: [.init(
            usage: usage, session: firstSession
        )])
        let live = FakeStatusFetcher(results: [
            .init(usage: nil, session: updatedSession),
            .init(usage: nil, session: latestSession),
        ])
        let presenter = FakeTouchBarStatusPresenter()
        let scheduler = FakeRefreshScheduler()
        let coordinator = AppCoordinator(
            activityMonitor: FakeActivityMonitor(),
            statusFetcher: full,
            liveStatusFetcher: live,
            presenter: presenter,
            scheduler: scheduler
        )
        coordinator.start()
        await waitUntil {
            let fullCount = await full.fetchCount
            let liveCount = await live.fetchCount
            return fullCount == 1 && liveCount == 1 && presenter.statuses.count == 2
        }

        scheduler.fireLive()
        await waitUntil { await live.fetchCount == 2 && presenter.statuses.count == 3 }

        XCTAssertEqual(scheduler.intervals, [15, 30, 5, 5])
        let fullFetchCount = await full.fetchCount
        XCTAssertEqual(fullFetchCount, 1)
        XCTAssertEqual(presenter.statuses.last?.usage, usage)
        XCTAssertEqual(presenter.statuses.last?.session, latestSession)
        coordinator.stop()
    }

    func testWorkingSessionUsesTwoAndHalfSecondFallback() async {
        let working = CurrentSessionSnapshot(
            sessionID: "working", usedTokens: 10, contextWindow: 100,
            model: nil, effort: nil, observedAt: .now,
            executionState: .working
        )
        let live = FakeStatusFetcher(results: [
            .init(usage: nil, session: working),
        ])
        let scheduler = FakeRefreshScheduler()
        let coordinator = AppCoordinator(
            activityMonitor: FakeActivityMonitor(),
            statusFetcher: FakeStatusFetcher(results: []),
            liveStatusFetcher: live,
            presenter: FakeTouchBarStatusPresenter(),
            scheduler: scheduler
        )

        coordinator.start()
        await waitUntil { await live.fetchCount == 1 }

        XCTAssertEqual(scheduler.intervals, [15, 30, 2.5])
        coordinator.stop()
    }

    func testDataChangeRefreshesImmediatelyAndReplacesIdleDeadline() async {
        let idle = CurrentSessionSnapshot(
            sessionID: "idle", usedTokens: 10, contextWindow: 100,
            model: nil, effort: nil, observedAt: .now,
            executionState: .idle
        )
        let live = FakeStatusFetcher(results: [
            .init(usage: nil, session: idle),
            .init(usage: nil, session: idle),
        ])
        let scheduler = FakeRefreshScheduler()
        let changes = FakeDataChangeMonitor()
        let coordinator = AppCoordinator(
            activityMonitor: FakeActivityMonitor(),
            statusFetcher: FakeStatusFetcher(results: []),
            liveStatusFetcher: live,
            presenter: FakeTouchBarStatusPresenter(),
            scheduler: scheduler,
            dataChangeMonitor: changes
        )
        coordinator.start()
        await waitUntil { await live.fetchCount == 1 }

        changes.emit()
        await waitUntil { await live.fetchCount == 2 }

        XCTAssertEqual(scheduler.intervals, [15, 30, 12, 12])
        XCTAssertEqual(changes.startCount, 1)
        coordinator.stop()
        XCTAssertEqual(changes.stopCount, 1)
    }

    func testLiveFailuresBackOffExponentiallyThenRecoverIdleCadence() async {
        let idle = CurrentSessionSnapshot(
            sessionID: "idle", usedTokens: 10, contextWindow: 100,
            model: nil, effort: nil, observedAt: .now,
            executionState: .idle
        )
        let live = FailingLiveStatusFetcher(results: [
            .failure(UsageError.unavailable),
            .failure(UsageError.unavailable),
            .success(.init(usage: nil, session: idle)),
        ])
        let scheduler = FakeRefreshScheduler()
        let coordinator = AppCoordinator(
            activityMonitor: FakeActivityMonitor(),
            statusFetcher: FakeStatusFetcher(results: []),
            liveStatusFetcher: live,
            presenter: FakeTouchBarStatusPresenter(),
            scheduler: scheduler
        )
        coordinator.start()
        await waitUntil { await live.fetchCount == 1 }
        scheduler.fireLive()
        await waitUntil { await live.fetchCount == 2 }
        scheduler.fireLive()
        await waitUntil { await live.fetchCount == 3 }

        XCTAssertEqual(scheduler.intervals, [15, 30, 5, 10, 12])
        coordinator.stop()
    }
    func testStartFetchesAndSchedulesWithoutCodexDesktopActivation() async {
        let expected = snapshot(observedAt: 1)
        let fixture = makeFixture(results: [.success(expected)])

        await fixture.waitForFetchCount(1)

        let fetchCount = await fixture.fetcher.fetchCount
        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(fixture.scheduler.intervals, [15, 30])
        XCTAssertEqual(fixture.presenter.shown, [expected])
    }

    func testStartPreparesPersistentControlStripAccess() {
        let fixture = makeFixture(results: [])

        XCTAssertEqual(fixture.presenter.preparePersistentAccessCount, 1)
        XCTAssertEqual(fixture.presenter.representCount, 0)
        XCTAssertTrue(fixture.presenter.shown.isEmpty)
    }

    func testStartHydratesCachedStatusBeforeActivityFetch() {
        let fixture = makeFixture(results: [], cached: cachedSnapshot())

        XCTAssertEqual(fixture.presenter.shown.count, 1)
        XCTAssertEqual(fixture.presenter.shown[0].primary.remainingPercent, 72)
        XCTAssertTrue(fixture.presenter.shown[0].isStale)
    }

    func testActivationFetchesAndShowsImmediately() async {
        let fixture = makeFixture(results: [.success(snapshot(observedAt: 1))])

        fixture.activity.emit(true)
        await fixture.waitForFetchCount(1)

        XCTAssertEqual(fixture.presenter.shown, [snapshot(observedAt: 1)])
        XCTAssertEqual(fixture.presenter.activatePersistentAccessCount, 0)
        XCTAssertEqual(fixture.scheduler.intervals, [15, 30])
    }

    func testThirtySecondTickFetchesAgain() async {
        let fixture = makeFixture(results: [
            .success(snapshot(observedAt: 1)),
            .success(snapshot(observedAt: 2)),
        ])
        fixture.activity.emit(true)
        await fixture.waitForFetchCount(1)

        fixture.scheduler.fire()
        await fixture.waitForFetchCount(2)

        XCTAssertEqual(fixture.presenter.shown, [snapshot(observedAt: 1), snapshot(observedAt: 2)])
    }

    func testSelectedThreadChangeTriggersImmediateRefreshAndPinsWhenCodexDeactivates() async {
        let fixture = makeFixture(results: [
            .success(snapshot(observedAt: 1)),
            .success(snapshot(observedAt: 2)),
        ])
        await fixture.waitForFetchCount(1)

        fixture.activity.emit(true)
        XCTAssertEqual(fixture.selectedThreadMonitor.activeStates, [true])
        fixture.selectedThreadMonitor.emitChange()
        await fixture.waitForFetchCount(2)

        fixture.activity.emit(false)
        XCTAssertEqual(fixture.selectedThreadMonitor.activeStates, [true, false])
        XCTAssertEqual(fixture.presenter.shown.last, snapshot(observedAt: 2))
    }

    func testQuotaTapRequestsImmediateRefresh() async {
        let first = snapshot(observedAt: 1)
        let second = snapshot(observedAt: 2)
        let fixture = makeFixture(results: [.success(first), .success(second)])
        fixture.activity.emit(true)
        await fixture.waitForFetchCount(1)
        let presentations = fixture.presenter.representCount

        fixture.presenter.emitManualRefresh()
        await fixture.waitForFetchCount(2)

        XCTAssertEqual(fixture.presenter.shown, [first, second])
        XCTAssertEqual(fixture.presenter.representCount, presentations)
    }

    func testQuotaTapMarksRenderedStatusStaleAndFetchesImmediately() async {
        let fixture = makeFixture(
            results: [
                .success(snapshot(observedAt: 1)),
                .success(snapshot(observedAt: 2)),
            ],
            cached: cachedSnapshot()
        )
        await fixture.waitForFetchCount(1, completedPresentations: 2)

        fixture.presenter.emitExplicitRestore()
        await fixture.waitForFetchCount(2, completedPresentations: 3)

        XCTAssertEqual(fixture.presenter.staleMarkCount, 2)
        XCTAssertEqual(fixture.presenter.shown.last, snapshot(observedAt: 2))
    }

    func testTrayRestoreRefreshesAndStartsCadenceOutsideCodex() async {
        let first = snapshot(observedAt: 1)
        let second = snapshot(observedAt: 2)
        let fixture = makeFixture(results: [.success(first), .success(second)])
        await fixture.waitForFetchCount(1)

        fixture.presenter.emitManualRefresh()
        await fixture.waitForFetchCount(2)

        XCTAssertEqual(fixture.presenter.shown, [first, second])
        XCTAssertEqual(fixture.scheduler.intervals, [15, 30])
        XCTAssertEqual(fixture.scheduler.activeTimerCount, 2)
    }

    func testApplicationMenuRestoreRepresentsAndRefreshes() async {
        let fixture = makeFixture(results: [
            .success(snapshot(observedAt: 1)),
            .success(snapshot(observedAt: 2)),
        ])
        await fixture.waitForFetchCount(1)

        fixture.coordinator.restoreFromApplicationMenu()
        await fixture.waitForFetchCount(2)

        XCTAssertEqual(fixture.presenter.representCount, 1)
        XCTAssertEqual(fixture.presenter.shown.last, snapshot(observedAt: 2))
    }

    func testWakeKeepsCollapsedMarksStaleAndFetchesImmediatelyWithoutDuplicateTimer() async {
        let fixture = makeFixture(results: [
            .success(snapshot(observedAt: 1)),
            .success(snapshot(observedAt: 2)),
        ])
        await fixture.waitForFetchCount(1)
        let intervals = fixture.scheduler.intervals

        fixture.wake.emit()
        await fixture.waitForFetchCount(2)

        XCTAssertEqual(fixture.presenter.staleMarkCount, 1)
        XCTAssertEqual(fixture.presenter.representCount, 0)
        XCTAssertEqual(fixture.scheduler.intervals, intervals)
    }

    func testManualRefreshFailurePreservesRenderedStatus() async {
        let first = snapshot(observedAt: 1)
        let fixture = makeFixture(results: [
            .success(first),
            .failure(UsageError.unavailable),
        ])
        fixture.activity.emit(true)
        await fixture.waitForFetchCount(1)

        fixture.presenter.emitManualRefresh()
        await fixture.waitForFetchCount(2, completedPresentations: 1)

        XCTAssertEqual(fixture.presenter.unavailableCount, 0)
        XCTAssertEqual(fixture.presenter.shown.last, first)
    }

    func testDeactivationKeepsFullBarAndRefreshCadenceAcrossApps() async {
        let fixture = makeFixture(results: [
            .success(snapshot(observedAt: 1)),
            .success(snapshot(observedAt: 2)),
            .success(snapshot(observedAt: 3)),
        ])
        fixture.activity.emit(true)
        await fixture.waitForFetchCount(1)

        fixture.activity.emit(false)

        XCTAssertEqual(fixture.presenter.hideCount, 0)
        XCTAssertEqual(fixture.scheduler.cancellationCount, 0)
        XCTAssertEqual(fixture.scheduler.activeTimerCount, 2)
        fixture.scheduler.fire()
        await fixture.waitForFetchCount(2)
        XCTAssertEqual(fixture.presenter.shown, [snapshot(observedAt: 1), snapshot(observedAt: 2)])

        fixture.activity.emit(true)
        await drainTasks()
        let fetchCount = await fixture.fetcher.fetchCount
        XCTAssertEqual(fetchCount, 2)
        XCTAssertEqual(fixture.presenter.activatePersistentAccessCount, 0)
        XCTAssertEqual(fixture.presenter.shown.last, snapshot(observedAt: 2))
    }

    func testFetchFailureShowsUnavailable() async {
        let fixture = makeFixture(results: [.failure(UsageError.unavailable)])

        fixture.activity.emit(true)
        await fixture.waitForFetchCount(1)

        XCTAssertEqual(fixture.presenter.unavailableCount, 1)
        XCTAssertTrue(fixture.presenter.shown.isEmpty)
    }

    func testRepeatedActivationDoesNotCreateDuplicateTimers() async {
        let fixture = makeFixture(results: [.success(snapshot(observedAt: 1))])

        fixture.activity.emit(true)
        await fixture.waitForFetchCount(1)
        fixture.activity.emit(true)

        XCTAssertEqual(fixture.scheduler.intervals, [15, 30])
        XCTAssertEqual(fixture.scheduler.activeTimerCount, 2)
        let fetchCount = await fixture.fetcher.fetchCount
        XCTAssertEqual(fetchCount, 1)
    }

    func testIdleHealthCheckDoesNotRepresentWithoutAPendingFailure() async {
        let fixture = makeFixture(results: [.success(snapshot(observedAt: 1))])
        await fixture.waitForFetchCount(1)
        let presentationsAfterStartup = fixture.presenter.representCount

        fixture.scheduler.fireHealthCheck()

        XCTAssertEqual(fixture.presenter.representCount, presentationsAfterStartup)
    }

    func testSuccessfulRefreshPublishesTheSameStatusToCache() async {
        let activity = FakeActivityMonitor()
        let fetcher = FakeUsageFetcher(results: [.success(snapshot(observedAt: 1))])
        let presenter = FakeUsagePresenter()
        let scheduler = FakeRefreshScheduler()
        let publisher = FakeStatusPublisher()
        let coordinator = AppCoordinator(
            activityMonitor: activity,
            fetcher: fetcher,
            presenter: presenter,
            scheduler: scheduler,
            statusPublisher: publisher
        )
        coordinator.start()

        activity.emit(true)
        for _ in 0..<30 { await Task.yield() }

        XCTAssertEqual(publisher.statuses, [.init(usage: snapshot(observedAt: 1), session: nil)])
    }

    func testActivityAfterStopCannotFetchScheduleOrShow() async {
        let fixture = makeFixture(results: [.success(snapshot(observedAt: 1))])
        await fixture.waitForFetchCount(1)

        fixture.coordinator.stop()
        fixture.activity.emit(true)
        await drainTasks()

        XCTAssertEqual(fixture.activity.stopCount, 1)
        XCTAssertEqual(fixture.presenter.preparePersistentAccessCount, 1)
        let fetchCount = await fixture.fetcher.fetchCount
        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(fixture.scheduler.intervals, [15, 30])
        XCTAssertEqual(fixture.presenter.shown, [snapshot(observedAt: 1)])
        XCTAssertEqual(fixture.presenter.unavailableCount, 0)
        XCTAssertEqual(fixture.presenter.hideCount, 1)
    }

    func testBackgroundEventsNeverPresentAfterFailedMenuRequest() async {
        let fixture = makeFixture(results: (1...5).map { .success(snapshot(observedAt: Double($0))) })
        await fixture.waitForFetchCount(1)
        fixture.presenter.representResult = false
        fixture.coordinator.restoreFromApplicationMenu()
        await fixture.waitForFetchCount(2)
        fixture.scheduler.fireHealthCheck()
        fixture.scheduler.fire()
        await fixture.waitForFetchCount(3)
        fixture.activity.emit(true)
        fixture.activity.emit(false)
        fixture.selectedThreadMonitor.emitChange()
        await fixture.waitForFetchCount(4)
        fixture.wake.emit()
        await fixture.waitForFetchCount(5)
        fixture.scheduler.fireHealthCheck()
        XCTAssertEqual(fixture.presenter.representCount, 1)
        XCTAssertEqual(fixture.presenter.activatePersistentAccessCount, 0)
    }

    private func makeFixture(
        results: [Result<UsageSnapshot, Error>],
        cached: StatusCacheSnapshot = .unavailable
    ) -> Fixture {
        let activity = FakeActivityMonitor()
        let fetcher = FakeUsageFetcher(results: results)
        let presenter = FakeUsagePresenter()
        let scheduler = FakeRefreshScheduler()
        let wake = FakeWakeMonitor()
        let selectedThreadMonitor = FakeSelectedThreadMonitor()
        let coordinator = AppCoordinator(
            activityMonitor: activity,
            fetcher: fetcher,
            presenter: presenter,
            scheduler: scheduler,
            statusCache: FakeStatusCache(snapshot: cached),
            selectedThreadMonitor: selectedThreadMonitor,
            wakeMonitor: wake
        )
        coordinator.start()
        return Fixture(
            coordinator: coordinator,
            activity: activity,
            fetcher: fetcher,
            presenter: presenter,
            scheduler: scheduler,
            selectedThreadMonitor: selectedThreadMonitor,
            wake: wake
        )
    }

    private func snapshot(observedAt: TimeInterval) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(label: "5H", usedPercent: 20, windowMinutes: 300, resetsAt: 100),
            secondary: RateWindow(label: "7D", usedPercent: 40, windowMinutes: 10_080, resetsAt: 200),
            observedAt: Date(timeIntervalSince1970: observedAt),
            isStale: false
        )
    }

    private func cachedSnapshot() -> StatusCacheSnapshot {
        .init(
            primaryRemainingPercent: 72,
            secondaryRemainingPercent: 41,
            sessionUsedTokens: 98_000,
            sessionContextWindow: 258_000,
            model: "gpt-5.6-sol",
            effort: "high",
            observedAt: Date(timeIntervalSince1970: 1),
            primaryResetAt: Date(timeIntervalSince1970: 100),
            secondaryResetAt: Date(timeIntervalSince1970: 200)
        )
    }

    private func drainTasks() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () async -> Bool
    ) async {
        for _ in 0..<300 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for condition")
    }

    private struct Fixture {
        let coordinator: AppCoordinator
        let activity: FakeActivityMonitor
        let fetcher: FakeUsageFetcher
        let presenter: FakeUsagePresenter
        let scheduler: FakeRefreshScheduler
        let selectedThreadMonitor: FakeSelectedThreadMonitor
        let wake: FakeWakeMonitor

        @MainActor
        func waitForFetchCount(
            _ expected: Int,
            completedPresentations expectedPresentations: Int? = nil
        ) async {
            for _ in 0..<200 {
                let completedPresentations = presenter.shown.count + presenter.unavailableCount
                if await fetcher.fetchCount == expected,
                   completedPresentations == expectedPresentations ?? expected {
                    return
                }
                await Task.yield()
            }
            XCTFail("Timed out waiting for \(expected) fetches")
        }
    }
}

@MainActor
private final class FakeSelectedThreadMonitor: SelectedThreadMonitoring {
    private var handler: (@MainActor @Sendable () -> Void)?
    private(set) var activeStates: [Bool] = []
    private(set) var stopCount = 0

    func start(_ handler: @escaping @MainActor @Sendable () -> Void) {
        self.handler = handler
    }

    func setCodexActive(_ active: Bool) {
        activeStates.append(active)
    }

    func stop() {
        stopCount += 1
        handler = nil
    }

    func emitChange() {
        handler?()
    }
}

@MainActor
private final class FakeActivityMonitor: ActivityMonitoring {
    private var handler: (@MainActor @Sendable (Bool) -> Void)?
    private(set) var stopCount = 0

    func start(_ handler: @escaping @MainActor @Sendable (Bool) -> Void) {
        self.handler = handler
    }

    func stop() {
        stopCount += 1
    }

    func emit(_ isActive: Bool) {
        handler?(isActive)
    }
}

@MainActor
private final class FakeWakeMonitor: WakeMonitoring {
    private var handler: (@MainActor @Sendable () -> Void)?
    private(set) var stopCount = 0
    func start(_ handler: @escaping @MainActor @Sendable () -> Void) { self.handler = handler }
    func stop() { stopCount += 1 }
    func emit() { handler?() }
}

@MainActor
private final class FakeDataChangeMonitor: DataChangeMonitoring {
    private var handler: (@MainActor @Sendable () -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start(_ handler: @escaping @MainActor @Sendable () -> Void) {
        startCount += 1
        self.handler = handler
    }

    func stop() {
        stopCount += 1
        handler = nil
    }

    func emit() { handler?() }
}

private actor FakeUsageFetcher: UsageFetching {
    private var results: [Result<UsageSnapshot, Error>]
    private(set) var fetchCount = 0

    init(results: [Result<UsageSnapshot, Error>]) {
        self.results = results
    }

    func fetch() async throws -> UsageSnapshot {
        fetchCount += 1
        guard !results.isEmpty else { throw UsageError.unavailable }
        return try results.removeFirst().get()
    }
}

private actor SuspendedStartupFetcher: StatusFetching {
    private var continuation: CheckedContinuation<TouchBarStatusSnapshot, Never>?
    var isWaiting: Bool { continuation != nil }

    func fetchStatus() async throws -> TouchBarStatusSnapshot {
        await withCheckedContinuation { continuation = $0 }
    }

    func finish() {
        continuation?.resume(returning: .init(usage: nil, session: .init(
            sessionID: "before-wake", usedTokens: 0, contextWindow: 0,
            model: nil, effort: nil, observedAt: .now
        )))
        continuation = nil
    }
}

private actor FakeStatusFetcher: StatusFetching {
    private var results: [TouchBarStatusSnapshot]
    private(set) var fetchCount = 0

    init(results: [TouchBarStatusSnapshot]) { self.results = results }

    func fetchStatus() async throws -> TouchBarStatusSnapshot {
        fetchCount += 1
        guard !results.isEmpty else { throw UsageError.unavailable }
        return results.removeFirst()
    }
}

private actor FailingLiveStatusFetcher: StatusFetching {
    private var results: [Result<TouchBarStatusSnapshot, Error>]
    private(set) var fetchCount = 0

    init(results: [Result<TouchBarStatusSnapshot, Error>]) { self.results = results }

    func fetchStatus() async throws -> TouchBarStatusSnapshot {
        fetchCount += 1
        guard !results.isEmpty else { throw UsageError.unavailable }
        return try results.removeFirst().get()
    }
}

@MainActor
private final class FakeUsagePresenter: UsagePresenting, ManualRefreshBinding,
    PresentationRestoreBinding {
    var onManualRefresh: (@MainActor @Sendable () -> Void)?
    var onExplicitRestore: (@MainActor @Sendable () -> Void)?
    private(set) var shown: [UsageSnapshot] = []
    private(set) var unavailableCount = 0
    private(set) var hideCount = 0
    private(set) var preparePersistentAccessCount = 0
    private(set) var activatePersistentAccessCount = 0
    private(set) var staleMarkCount = 0
    private(set) var representCount = 0

    func preparePersistentAccess() { preparePersistentAccessCount += 1 }
    func activatePersistentAccess() { activatePersistentAccessCount += 1 }
    func show(_ snapshot: UsageSnapshot) { shown.append(snapshot) }
    func showUnavailable() { unavailableCount += 1 }
    func markRenderedStatusStale() { staleMarkCount += 1 }
    var representResult = true
    func represent() -> Bool { representCount += 1; return representResult }
    func hide() { hideCount += 1 }
    func emitManualRefresh() { onManualRefresh?() }
    func emitExplicitRestore() { onExplicitRestore?() }
}

@MainActor
private final class FakeTouchBarStatusPresenter: UsagePresenting {
    private(set) var statuses: [TouchBarStatusSnapshot] = []
    private(set) var unavailableCount = 0
    private(set) var representCount = 0
    func show(_ snapshot: UsageSnapshot) {}
    func showStatus(_ status: TouchBarStatusSnapshot) { statuses.append(status) }
    func showUnavailable() { unavailableCount += 1 }
    var representResult = true
    func represent() -> Bool { representCount += 1; return representResult }
    func hide() {}
}

@MainActor
private final class FakeStatusCache: StatusCacheLoading {
    private let snapshot: StatusCacheSnapshot

    init(snapshot: StatusCacheSnapshot) { self.snapshot = snapshot }

    func loadStatusCache() -> StatusCacheSnapshot { snapshot }
}

@MainActor
private final class FakeStatusPublisher: StatusPublishing {
    private(set) var statuses: [TouchBarStatusSnapshot] = []

    func publish(_ status: TouchBarStatusSnapshot) {
        statuses.append(status)
    }
}

@MainActor
private final class FakeRefreshScheduler: RefreshScheduling {
    private(set) var intervals: [TimeInterval] = []
    private(set) var cancellationCount = 0
    private var handlers: [UUID: (TimeInterval, @MainActor @Sendable () -> Void)] = [:]
    private var oneShotIDs = Set<UUID>()

    var activeTimerCount: Int { handlers.count }

    func scheduleRepeating(
        every interval: TimeInterval,
        _ handler: @escaping @MainActor @Sendable () -> Void
    ) -> any RefreshCancellation {
        intervals.append(interval)
        let id = UUID()
        handlers[id] = (interval, handler)
        return FakeCancellation { [weak self] in
            guard let self, self.handlers.removeValue(forKey: id) != nil else { return }
            self.cancellationCount += 1
        }
    }

    func scheduleOnce(
        after interval: TimeInterval,
        _ handler: @escaping @MainActor @Sendable () -> Void
    ) -> any RefreshCancellation {
        intervals.append(interval)
        let id = UUID()
        oneShotIDs.insert(id)
        handlers[id] = (interval, handler)
        return FakeCancellation { [weak self] in
            guard let self, self.handlers.removeValue(forKey: id) != nil else { return }
            self.oneShotIDs.remove(id)
            self.cancellationCount += 1
        }
    }

    func fire() {
        handlers.values.first(where: { $0.0 == 30 })?.1()
    }

    func fireHealthCheck() {
        handlers.values.first(where: { $0.0 == 15 })?.1()
    }

    func fireLive() {
        guard let id = oneShotIDs.first,
              let handler = handlers.removeValue(forKey: id)?.1 else { return }
        oneShotIDs.remove(id)
        handler()
    }
}

@MainActor
private final class FakeCancellation: RefreshCancellation {
    private let onCancel: @MainActor () -> Void

    init(onCancel: @escaping @MainActor () -> Void) {
        self.onCancel = onCancel
    }

    func cancel() { onCancel() }
}
