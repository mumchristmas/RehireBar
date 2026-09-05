import AgentStatusCore
import AppKit
import XCTest
@testable import RehireBar

@MainActor
final class TouchBarPresenterTests: XCTestCase {
    func testUpdatedModelPolicyReachesRenderedCardsOnTheNextStatusRefresh() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "model-display.json")
        let loader = ModelDisplayConfigurationLoader(overrideURL: url)
        let presenter = TouchBarPresenter(
            bridge: UnavailableBridge(),
            modelDisplayConfiguration: { loader.load() },
            logger: { _ in }
        )
        let status = TouchBarStatusSnapshot(usage: nil, session: .init(
            sessionID: "task", usedTokens: 0, contextWindow: 0,
            model: "GPT6-astra", effort: "xhigh", observedAt: .now
        ))
        presenter.showStatus(status)
        let item = try XCTUnwrap(presenter.touchBar(
            NSTouchBar(), makeItemForIdentifier: TouchBarLayout.sessionIdentifier
        ) as? NSCustomTouchBarItem)
        let scrubber = try XCTUnwrap(item.view as? NSScrubber)
        let source = try XCTUnwrap(scrubber.dataSource)
        func labels() -> [String] {
            descendants(of: source.scrubber(scrubber, viewForItemAt: 0))
                .compactMap { ($0 as? NSTextField)?.stringValue }
        }
        XCTAssertTrue(labels().contains("6.0A·XH"))

        var configuration = ModelDisplayConfigurationLoader.bundledConfiguration
        configuration.modelAliases["gpt6-astra"] = "Astra"
        try JSONEncoder().encode(configuration).write(to: url, options: .atomic)
        presenter.showStatus(status)

        XCTAssertTrue(labels().contains("Astra·XH"))
        XCTAssertFalse(labels().contains("6.0A·XH"))
    }

    func testSevenDayOnlyStatusHidesPrimaryAndRendersSecondary() throws {
        let usage = try UsageSnapshot.from(
            primary: .init(usedPercent: 0, windowMinutes: 10_080, resetsAt: 100),
            secondary: nil,
            observedAt: .now
        )
        let model = TouchBarStatusViewModel(
            status: .init(usage: usage, session: nil),
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertEqual(model.primary.percentText, "N/A")
        XCTAssertEqual(model.secondary.percentText, "100%")

        let presenter = TouchBarPresenter(bridge: UnavailableBridge(), logger: { _ in })
        presenter.showStatus(.init(usage: usage, session: nil))
        XCTAssertEqual(presenter.displayedItemIdentifiers, [
            TouchBarLayout.secondaryIdentifier,
            TouchBarLayout.sessionIdentifier,
            .otherItemsProxy,
        ])
        XCTAssertEqual(
            TouchBarLayout.sessionWidth(primaryAvailable: false),
            TouchBarLayout.sessionPreferredWidth
        )
        XCTAssertEqual(TouchBarLayout.sessionMinimumWidth, 188)
        XCTAssertEqual(TouchBarLayout.sessionCardMinimumWidth, 180)
        XCTAssertEqual(TouchBarLayout.sessionPreferredWidth, 607)
    }

    func testVisibleSessionCardCountUsesAvailableWidthWithoutBreakingReadableMinimum() {
        XCTAssertEqual(
            TouchBarLayout.visibleSessionCardCount(sessionWidth: 302, sessionCount: 8),
            1
        )
        XCTAssertEqual(
            TouchBarLayout.visibleSessionCardCount(sessionWidth: 447, sessionCount: 8),
            2
        )
        XCTAssertEqual(
            TouchBarLayout.visibleSessionCardCount(sessionWidth: 607, sessionCount: 8),
            3
        )
        XCTAssertEqual(
            TouchBarLayout.visibleSessionCardCount(sessionWidth: 767, sessionCount: 8),
            4
        )
        XCTAssertEqual(
            TouchBarLayout.visibleSessionCardCount(sessionWidth: 607, sessionCount: 1),
            1
        )
    }

    func testSessionWidthAdaptsToHardwareQuotaAndControlStripGeometry() {
        XCTAssertEqual(
            TouchBarLayout.sessionWidth(primaryAvailable: false, geometry: .compactBaseline),
            607
        )
        XCTAssertEqual(
            TouchBarLayout.sessionWidth(primaryAvailable: true, geometry: .compactBaseline),
            462
        )
        XCTAssertEqual(
            TouchBarLayout.sessionWidth(
                primaryAvailable: false,
                geometry: .init(
                    screenWidth: 1_085,
                    compactControlStripItemCount: 2,
                    controlStripVisible: true
                )
            ),
            688
        )
        XCTAssertEqual(
            TouchBarLayout.sessionWidth(
                primaryAvailable: false,
                geometry: .init(
                    screenWidth: 1_004,
                    compactControlStripItemCount: 3,
                    controlStripVisible: true
                )
            ),
            563
        )
        XCTAssertEqual(
            TouchBarLayout.sessionWidth(
                primaryAvailable: false,
                geometry: .init(
                    screenWidth: 1_004,
                    compactControlStripItemCount: 2,
                    controlStripVisible: false
                )
            ),
            767
        )
    }

    func testGeometryReaderKeepsLastValidPhysicalWidthAcrossTransientDFRFailure() {
        var observations: [CGSize?] = [
            CGSize(width: 1_085, height: 30),
            nil,
        ]
        let reader = SystemTouchBarGeometryReader {
            observations.removeFirst()
        }

        XCTAssertEqual(reader.read().screenWidth, 1_085)
        XCTAssertEqual(reader.read().screenWidth, 1_085)
    }

    func testPrimaryQuotaReturningRestoresFullMetricComposition() throws {
        let sevenDayOnly = try UsageSnapshot.from(
            primary: .init(usedPercent: 0, windowMinutes: 10_080, resetsAt: 100),
            secondary: nil,
            observedAt: .now
        )
        let allWindows = try UsageSnapshot.from(
            primary: .init(usedPercent: 20, windowMinutes: 300, resetsAt: 100),
            secondary: .init(usedPercent: 30, windowMinutes: 10_080, resetsAt: 200),
            observedAt: .now
        )
        let presenter = TouchBarPresenter(bridge: UnavailableBridge(), logger: { _ in })

        presenter.showStatus(.init(usage: sevenDayOnly, session: nil))
        presenter.showStatus(.init(usage: allWindows, session: nil))

        XCTAssertEqual(
            presenter.displayedItemIdentifiers,
            TouchBarLayout.metricItemIdentifiers(primaryAvailable: true)
        )
    }
    func testApprovalTypographyUsesApprovedReadableSizes() {
        XCTAssertEqual(ApprovalTouchBarStyle.questionFontSize, 14)
        XCTAssertEqual(ApprovalTouchBarStyle.actionFontSize, 13)
        XCTAssertGreaterThanOrEqual(ApprovalTouchBarStyle.actionMinimumWidth, 96)
    }

    func testSessionAreaHasARequiredMinimumAndBreakablePreferredWidth() throws {
        let presenter = TouchBarPresenter(bridge: UnavailableBridge(), logger: { _ in })
        let item = try XCTUnwrap(
            presenter.touchBar(
                NSTouchBar(),
                makeItemForIdentifier: TouchBarLayout.sessionIdentifier
            ) as? NSCustomTouchBarItem
        )
        let constraints = try XCTUnwrap(item.view).constraints
        let minimum = constraints.first {
            $0.firstAttribute == .width && $0.relation == .greaterThanOrEqual
        }
        let preferred = constraints.first {
            $0.firstAttribute == .width && $0.relation == .equal
        }

        XCTAssertEqual(minimum?.constant, TouchBarLayout.sessionMinimumWidth)
        XCTAssertEqual(minimum?.priority, .required)
        XCTAssertEqual(preferred?.priority, TouchBarLayout.sessionPreferredPriority)
        XCTAssertLessThan(preferred?.priority.rawValue ?? 0, NSLayoutConstraint.Priority.defaultHigh.rawValue)
    }

    func testWeeklyQuotaAndSessionOutrankOptionalFiveHourQuota() throws {
        let presenter = TouchBarPresenter(bridge: UnavailableBridge(), logger: { _ in })
        let sessionItem = try XCTUnwrap(
            presenter.touchBar(
                NSTouchBar(),
                makeItemForIdentifier: TouchBarLayout.sessionIdentifier
            )
        )
        let weeklyItem = try XCTUnwrap(
            presenter.touchBar(
                NSTouchBar(),
                makeItemForIdentifier: TouchBarLayout.secondaryIdentifier
            )
        )
        let fiveHourItem = try XCTUnwrap(
            presenter.touchBar(
                NSTouchBar(),
                makeItemForIdentifier: TouchBarLayout.primaryIdentifier
            )
        )

        XCTAssertEqual(sessionItem.visibilityPriority, .high)
        XCTAssertEqual(weeklyItem.visibilityPriority, .high)
        XCTAssertEqual(fiveHourItem.visibilityPriority, .low)
    }

    func testFiveHourPreferenceReservesItsSpaceForWeeklyQuotaAndTasks() throws {
        let usage = try UsageSnapshot.from(
            primary: .init(usedPercent: 0, windowMinutes: 300, resetsAt: 100),
            secondary: .init(usedPercent: 10, windowMinutes: 10_080, resetsAt: 200),
            observedAt: .now
        )
        let presenter = TouchBarPresenter(
            bridge: UnavailableBridge(),
            showsPrimaryQuota: false,
            logger: { _ in }
        )
        presenter.showStatus(.init(usage: usage, session: nil))

        XCTAssertEqual(
            presenter.displayedItemIdentifiers,
            TouchBarLayout.metricItemIdentifiers(primaryAvailable: false)
        )
        let sessionItem = try XCTUnwrap(
            presenter.touchBar(
                NSTouchBar(),
                makeItemForIdentifier: TouchBarLayout.sessionIdentifier
            ) as? NSCustomTouchBarItem
        )
        let preferred = try XCTUnwrap(sessionItem.view.constraints.first {
            $0.firstAttribute == .width && $0.relation == .equal
        })
        XCTAssertEqual(preferred.constant, TouchBarLayout.sessionPreferredWidth)
    }

    func testMetricRefreshNeverDropsQuotaFromTheDeclaredComposition() throws {
        let sevenDayOnly = try UsageSnapshot.from(
            primary: .init(usedPercent: 13, windowMinutes: 10_080, resetsAt: 100),
            secondary: nil,
            observedAt: .now
        )
        let presenter = TouchBarPresenter(bridge: UnavailableBridge(), logger: { _ in })
        presenter.showStatus(.init(usage: sevenDayOnly, session: nil))
        presenter.showStatus(.init(usage: sevenDayOnly, session: nil))

        XCTAssertEqual(
            presenter.displayedItemIdentifiers,
            TouchBarLayout.metricItemIdentifiers(primaryAvailable: false)
        )
    }

    func testControlStripRestoreKeepsNormalQuotaComposition() throws {
        let sevenDayOnly = try UsageSnapshot.from(
            primary: .init(usedPercent: 13, windowMinutes: 10_080, resetsAt: 100),
            secondary: nil,
            observedAt: .now
        )
        let bridge = UnavailableBridge()
        let presenter = TouchBarPresenter(bridge: bridge, logger: { _ in })
        presenter.showStatus(.init(usage: sevenDayOnly, session: nil))
        XCTAssertEqual(
            presenter.displayedItemIdentifiers,
            TouchBarLayout.metricItemIdentifiers(primaryAvailable: false)
        )
        var refreshCount = 0
        presenter.onExplicitRestore = { refreshCount += 1 }

        bridge.emitRestore()

        XCTAssertEqual(
            presenter.displayedItemIdentifiers,
            TouchBarLayout.metricItemIdentifiers(primaryAvailable: false)
        )
        XCTAssertEqual(refreshCount, 1)
    }

    func testCodexFocusChangePreservesTheMonitoringViewport() throws {
        let first = CurrentSessionSnapshot(
            sessionID: "first-session",
            threadID: "first-thread",
            title: "First task",
            usedTokens: 20_000,
            contextWindow: 100_000,
            model: "gpt-5.6-sol",
            effort: "medium",
            observedAt: .now
        )
        let second = CurrentSessionSnapshot(
            sessionID: "second-session",
            threadID: "second-thread",
            title: "Second task",
            usedTokens: 40_000,
            contextWindow: 100_000,
            model: "gpt-5.6-terra",
            effort: "high",
            observedAt: .now
        )
        let presenter = TouchBarPresenter(bridge: UnavailableBridge(), logger: { _ in })
        presenter.showStatus(.init(usage: nil, session: first, sessions: [first, second]))
        let item = try XCTUnwrap(
            presenter.touchBar(
                NSTouchBar(),
                makeItemForIdentifier: TouchBarLayout.sessionIdentifier
            ) as? NSCustomTouchBarItem
        )
        let scrubber = try XCTUnwrap(item.view as? NSScrubber)
        XCTAssertEqual(scrubber.selectedIndex, 0)

        presenter.showStatus(.init(usage: nil, session: second, sessions: [first, second]))

        XCTAssertEqual(scrubber.selectedIndex, 0)
    }

    func testSingleSessionScrubberStillProducesAFullWidthCard() throws {
        let presenter = TouchBarPresenter(bridge: UnavailableBridge(), logger: { _ in })
        presenter.showStatus(status(sessionUsed: 38_000, contextWindow: 100_000))
        let item = try XCTUnwrap(
            presenter.touchBar(
                NSTouchBar(),
                makeItemForIdentifier: TouchBarLayout.sessionIdentifier
            ) as? NSCustomTouchBarItem
        )
        let scrubber = try XCTUnwrap(item.view as? NSScrubber)
        scrubber.frame = NSRect(
            x: 0,
            y: 0,
            width: TouchBarLayout.sessionPreferredWidth,
            height: 30
        )
        let dataSource = try XCTUnwrap(scrubber.dataSource)
        XCTAssertEqual(dataSource.numberOfItems(for: scrubber), 1)
        let itemView = dataSource.scrubber(scrubber, viewForItemAt: 0)
        itemView.frame = scrubber.bounds
        itemView.layoutSubtreeIfNeeded()
        let card = try XCTUnwrap(
            descendants(of: itemView).first { $0.accessibilityRole() == .button }
        )

        XCTAssertGreaterThan(card.frame.width, 0)
        XCTAssertEqual(card.frame.height, 30)
        XCTAssertEqual(scrubber.mode, .free)
        XCTAssertTrue(scrubber.showsAdditionalContentIndicators)
    }

    func testSessionScrubberShowsThreeCardsAtBaselineTaskWidth() throws {
        let usage = try UsageSnapshot.from(
            primary: .init(usedPercent: 14, windowMinutes: 10_080, resetsAt: 100),
            secondary: nil,
            observedAt: .now
        )
        let sessions = (1...3).map { index in
            CurrentSessionSnapshot(
                sessionID: "session-\(index)",
                threadID: "thread-\(index)",
                title: "Task \(index)",
                usedTokens: index * 10_000,
                contextWindow: 100_000,
                model: "gpt-5.6-sol",
                effort: "medium",
                observedAt: .now
            )
        }
        let presenter = TouchBarPresenter(bridge: UnavailableBridge(), logger: { _ in })
        presenter.showStatus(.init(usage: usage, session: sessions[0], sessions: sessions))
        let item = try XCTUnwrap(
            presenter.touchBar(
                NSTouchBar(),
                makeItemForIdentifier: TouchBarLayout.sessionIdentifier
            ) as? NSCustomTouchBarItem
        )
        let scrubber = try XCTUnwrap(item.view as? NSScrubber)
        let layout = try XCTUnwrap(scrubber.scrubberLayout as? NSScrubberProportionalLayout)

        XCTAssertEqual(scrubber.dataSource?.numberOfItems(for: scrubber), 3)
        XCTAssertEqual(layout.numberOfVisibleItems, 3)
        XCTAssertEqual(scrubber.selectedIndex, 0)
    }

    func testModelHasNoStandaloneItemBecauseEachSessionOwnsItsModel() {
        XCTAssertEqual(
            TouchBarLayout.metricItemIdentifiers(primaryAvailable: false),
            [
                TouchBarLayout.secondaryIdentifier,
                TouchBarLayout.sessionIdentifier,
                .otherItemsProxy,
            ]
        )
    }
    func testTrayButtonUsesIconAndRestoreActionInsteadOfC() {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        let target = RestoreTarget()
        let button = StatusTrayButtonFactory(iconResolver: { image })
            .make(target: target, action: #selector(RestoreTarget.restore))

        XCTAssertEqual(button.title, "")
        XCTAssertTrue(button.image === image)
        XCTAssertTrue(button.target === target)
        XCTAssertEqual(button.action, #selector(RestoreTarget.restore))
    }

    func testRestoreActionRepresentsRetainedTouchBarEveryTime() {
        let touchBar = NSTouchBar()
        var restored: [NSTouchBar] = []
        let action = RetainedTouchBarRestoreAction { restored.append($0) }
        action.touchBar = touchBar

        action.restore()
        action.restore()

        XCTAssertEqual(restored, [touchBar, touchBar])
    }

    func testSystemModalPlanPreservesNativeControlStrip() {
        let plan = SystemModalPresentationPlan.controlStripPreserving
        XCTAssertEqual(plan.selectorName, "presentSystemModalTouchBar:systemTrayItemIdentifier:")
        XCTAssertFalse(plan.usesPlacement)
        XCTAssertNotNil(plan.systemTrayIdentifier)
    }

    func testMainBarEndsWithOtherItemsProxy() {
        XCTAssertEqual(TouchBarLayout.mainItemIdentifiers.last, .otherItemsProxy)
    }

    func testPresenterLetsAppKitCreateOtherItemsProxy() {
        let presenter = TouchBarPresenter(bridge: UnavailableBridge(), logger: { _ in })

        XCTAssertNil(
            presenter.touchBar(
                NSTouchBar(),
                makeItemForIdentifier: .otherItemsProxy
            )
        )
    }

    func testPreparationRegistersRetainsAndShowsTrayWithoutPresenting() {
        let runtime = FakeSystemModalRuntime()
        let bridge = SystemModalTouchBarBridge(runtime: runtime)
        let bar = NSTouchBar()

        XCTAssertTrue(bridge.preparePersistentAccess(bar))
        XCTAssertTrue(bridge.preparePersistentAccess(bar))

        XCTAssertEqual(runtime.addTrayCount, 1)
        XCTAssertEqual(runtime.trayPresence, [true])
        XCTAssertTrue(runtime.closeBoxVisibility.isEmpty)
        XCTAssertTrue(runtime.presentedBars.isEmpty)

        XCTAssertTrue(bridge.restorePresentedTouchBar())
        XCTAssertEqual(runtime.presentedBars, [bar])
        XCTAssertEqual(runtime.closeBoxVisibility, [false])
    }

    func testExplicitActivationForcesNativePresentationWithoutManualRestoreCallback() {
        let runtime = FakeSystemModalRuntime()
        let bridge = SystemModalTouchBarBridge(runtime: runtime)
        let bar = NSTouchBar()
        var restoreCount = 0
        bridge.onRestore = { restoreCount += 1 }

        XCTAssertTrue(bridge.preparePersistentAccess(bar))
        XCTAssertTrue(bridge.activatePersistentAccess(bar))
        XCTAssertTrue(bridge.activatePersistentAccess(bar))

        XCTAssertEqual(runtime.presentedBars, [bar, bar])
        XCTAssertEqual(runtime.closeBoxVisibility, [false])
        XCTAssertEqual(restoreCount, 0)
    }

    func testPresenterActivationDoesNotForceAnAlreadyRetainedBarToReopen() {
        let runtime = FakeSystemModalRuntime()
        let bridge = SystemModalTouchBarBridge(runtime: runtime)
        let presenter = TouchBarPresenter(bridge: bridge, logger: { _ in })

        presenter.preparePersistentAccess()
        presenter.activatePersistentAccess()
        presenter.activatePersistentAccess()

        XCTAssertEqual(runtime.presentedBars.count, 1)
    }

    func testSuccessfulTrayRestoreNotifiesPresenterForAnOutsideCodexRefresh() {
        let runtime = FakeSystemModalRuntime()
        let bridge = SystemModalTouchBarBridge(runtime: runtime)
        let presenter = TouchBarPresenter(bridge: bridge, logger: { _ in })
        var restoreCount = 0
        presenter.onExplicitRestore = { restoreCount += 1 }

        presenter.preparePersistentAccess()
        XCTAssertTrue(bridge.restorePresentedTouchBar())

        XCTAssertEqual(restoreCount, 1)
    }

    func testDismissBalancesTrayAndCloseBoxState() {
        let runtime = FakeSystemModalRuntime()
        let bridge = SystemModalTouchBarBridge(runtime: runtime)
        let bar = NSTouchBar()

        XCTAssertTrue(bridge.present(bar))
        bridge.restorePresentedTouchBar()
        bridge.dismissOwnTouchBar()

        XCTAssertEqual(runtime.trayPresence, [true, false])
        XCTAssertEqual(runtime.closeBoxVisibility, [false, true])
        XCTAssertEqual(runtime.addTrayCount, 1)
        XCTAssertEqual(runtime.presentedBars, [bar, bar])
        XCTAssertEqual(runtime.dismissedBars, [bar])
    }

    func testFailedDismissRetainsOwnershipUntilARetrySucceeds() {
        let runtime = FakeSystemModalRuntime()
        let bridge = SystemModalTouchBarBridge(runtime: runtime)
        let bar = NSTouchBar()

        XCTAssertTrue(bridge.present(bar))
        runtime.dismissResult = false
        bridge.dismissOwnTouchBar()

        XCTAssertEqual(runtime.dismissedBars, [bar])
        XCTAssertEqual(runtime.trayPresence, [true])
        XCTAssertEqual(runtime.closeBoxVisibility, [false])
        XCTAssertTrue(bridge.restorePresentedTouchBar())
        XCTAssertEqual(runtime.presentedBars, [bar, bar])
        XCTAssertEqual(runtime.trayPresence, [true])

        runtime.dismissResult = true
        bridge.dismissOwnTouchBar()
        bridge.dismissOwnTouchBar()

        XCTAssertEqual(runtime.dismissedBars, [bar, bar])
        XCTAssertEqual(runtime.trayPresence, [true, false])
        XCTAssertEqual(runtime.closeBoxVisibility, [false, true])
        XCTAssertFalse(bridge.restorePresentedTouchBar())
    }

    func testRepeatedPresentationCyclesRegisterTrayOnlyOnceAndBalanceState() {
        let runtime = FakeSystemModalRuntime()
        let bridge = SystemModalTouchBarBridge(runtime: runtime)
        let firstBar = NSTouchBar()
        let secondBar = NSTouchBar()

        XCTAssertTrue(bridge.present(firstBar))
        XCTAssertTrue(bridge.present(firstBar))
        bridge.dismissOwnTouchBar()
        XCTAssertTrue(bridge.present(secondBar))
        bridge.dismissOwnTouchBar()

        XCTAssertEqual(runtime.addTrayCount, 1)
        XCTAssertEqual(runtime.trayPresence, [true, false, true, false])
        XCTAssertEqual(runtime.closeBoxVisibility, [false, true, false, true])
        XCTAssertEqual(runtime.presentedBars, [firstBar, secondBar])
        XCTAssertEqual(runtime.dismissedBars, [firstBar, secondBar])
    }

    func testFailedPresentationReturnsToPreparedTrayAccess() {
        let runtime = FakeSystemModalRuntime()
        let bridge = SystemModalTouchBarBridge(runtime: runtime)
        let bar = NSTouchBar()

        XCTAssertTrue(bridge.preparePersistentAccess(bar))
        runtime.presentResult = false

        XCTAssertFalse(bridge.restorePresentedTouchBar())

        XCTAssertEqual(runtime.trayPresence, [true])
        XCTAssertEqual(runtime.closeBoxVisibility, [false, true])
        XCTAssertEqual(runtime.addTrayCount, 1)

        runtime.presentResult = true
        XCTAssertTrue(bridge.restorePresentedTouchBar())
        XCTAssertEqual(runtime.addTrayCount, 1)
        XCTAssertEqual(runtime.presentedBars, [bar, bar])
    }

    func testFailedRestoreKeepsPreparedOwnershipAndAllowsRetry() {
        let runtime = FakeSystemModalRuntime()
        let bridge = SystemModalTouchBarBridge(runtime: runtime)
        let firstBar = NSTouchBar()

        XCTAssertTrue(bridge.preparePersistentAccess(firstBar))
        runtime.presentResult = false
        XCTAssertFalse(bridge.restorePresentedTouchBar())

        XCTAssertEqual(runtime.trayPresence, [true])
        XCTAssertEqual(runtime.closeBoxVisibility, [false, true])
        XCTAssertEqual(runtime.addTrayCount, 1)

        runtime.presentResult = true
        XCTAssertTrue(bridge.restorePresentedTouchBar())
        XCTAssertEqual(runtime.addTrayCount, 1)
        XCTAssertEqual(runtime.presentedBars, [firstBar, firstBar])

        bridge.dismissOwnTouchBar()
        XCTAssertEqual(runtime.trayPresence, [true, false])
        XCTAssertEqual(runtime.closeBoxVisibility, [false, true, false, true])
        XCTAssertEqual(runtime.dismissedBars, [firstBar])
    }

    func testMissingRequiredRuntimeAPIsDoNotMutateCompositionState() {
        let runtime = FakeSystemModalRuntime()
        runtime.addTrayResult = false
        let bridge = SystemModalTouchBarBridge(runtime: runtime)

        XCTAssertFalse(bridge.present(NSTouchBar()))

        XCTAssertEqual(runtime.addTrayCount, 1)
        XCTAssertTrue(runtime.trayPresence.isEmpty)
        XCTAssertTrue(runtime.closeBoxVisibility.isEmpty)
        XCTAssertTrue(runtime.presentedBars.isEmpty)
    }

    func testApprovedStatusLayoutFormatsAllFourMetrics() {
        let model = TouchBarStatusViewModel(
            status: status(sessionUsed: 98_321, contextWindow: 258_400),
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(model.primary.label, "5H")
        XCTAssertEqual(model.primary.resetText, "reset 03:04")
        XCTAssertEqual(model.primary.percentText, "72%")
        XCTAssertEqual(model.primary.progress, 0.72, accuracy: 0.001)
        XCTAssertEqual(model.secondary.label, "7D")
        XCTAssertEqual(model.secondary.percentText, "41%")
        XCTAssertEqual(model.sessions.first?.modelEffortText, "5.6S·M")
        XCTAssertEqual(model.sessions.first?.contextPercent, 38)
    }

    func testSessionLabelUsesSelectedThreadTitle() {
        let model = TouchBarStatusViewModel(
            status: TouchBarStatusSnapshot(
                usage: nil,
                session: CurrentSessionSnapshot(
                    sessionID: "session",
                    threadID: "10000000-0000-4000-8000-000000000002",
                    title: "Touch Bar selected thread",
                    usedTokens: 98_321,
                    contextWindow: 258_400,
                    model: "gpt-5.6-sol",
                    effort: "high",
                    observedAt: .now
                )
            )
        )

        XCTAssertEqual(model.sessions.first?.taskText, "Touch Bar selected thread")
        XCTAssertEqual(model.sessions.first?.contextPercent, 38)
    }

    func testCompactModelAndEffortNamesPreserveMeaningInLessSpace() {
        let formatter = ModelDisplayFormatter(configuration: ModelDisplayConfigurationLoader.bundledConfiguration)
        XCTAssertEqual(formatter.modelName("gpt-5.6-sol"), "5.6S")
        XCTAssertEqual(formatter.modelName("gpt-5.4-mini"), "5.4m")
        XCTAssertEqual(formatter.modelName("gpt-5.8-sol"), "5.8S")
        XCTAssertEqual(formatter.modelName("gpt-6.1-nova"), "6.1-nova")
        XCTAssertEqual(formatter.modelName("o4-mini"), "o4m")
        XCTAssertEqual(formatter.effortName("xhigh"), "XH")
        XCTAssertEqual(formatter.effortName("medium"), "M")
        XCTAssertEqual(formatter.effortName("extreme"), "EXTREME")
    }

    func testRemoteSessionOmitsUnavailableContextInsteadOfRenderingAPlaceholder() {
        let remote = CurrentSessionSnapshot(
            sessionID: "remote-session",
            threadID: "remote-thread",
            title: "Room control",
            usedTokens: 0,
            contextWindow: 0,
            model: nil,
            effort: nil,
            observedAt: .now,
            projectName: "climate-agent",
            hostName: "TestHost",
            isRemote: true,
            executionState: .working
        )
        let model = TouchBarStatusViewModel(
            status: .init(usage: nil, session: nil, sessions: [remote])
        )

        XCTAssertEqual(model.sessions.first?.taskText, "Room control")
        XCTAssertEqual(model.sessions.first?.stateText, "RUN")
        XCTAssertEqual(model.sessions.first?.remoteText, "REMOTE")
        XCTAssertNil(model.sessions.first?.contextPercent)
        XCTAssertNil(model.sessions.first?.contextProgress)
        XCTAssertNil(model.sessions.first?.modelEffortText)
    }

    func testLocalAndRemoteCardsShareTaskFirstInformationHierarchy() {
        let commonObservedAt = Date(timeIntervalSince1970: 200)
        let commonActiveSince = Date(timeIntervalSince1970: 75)
        let local = CurrentSessionSnapshot(
            sessionID: "local-session",
            threadID: "local-thread",
            title: "检查代理隧道",
            usedTokens: 42_000,
            contextWindow: 100_000,
            model: "gpt-5.6-sol",
            effort: "xhigh",
            observedAt: commonObservedAt,
            activeSince: commonActiveSince,
            projectName: "network-agent",
            executionState: .working
        )
        let remote = CurrentSessionSnapshot(
            sessionID: "remote-session",
            threadID: "remote-thread",
            title: "检查代理隧道",
            usedTokens: 42_000,
            contextWindow: 100_000,
            model: "gpt-5.6-sol",
            effort: "xhigh",
            observedAt: commonObservedAt,
            activeSince: commonActiveSince,
            projectName: "network-agent",
            hostName: "TestHost",
            isRemote: true,
            executionState: .working
        )

        let cards = TouchBarStatusViewModel(
            status: .init(usage: nil, session: local, sessions: [local, remote]),
            now: commonObservedAt
        ).sessions

        XCTAssertEqual(cards.map(\.taskText), ["检查代理隧道", "检查代理隧道"])
        XCTAssertEqual(cards.map(\.stateText), ["RUN", "RUN"])
        XCTAssertEqual(cards.map(\.elapsedText), ["2m5s", "2m5s"])
        XCTAssertEqual(cards.map(\.modelEffortText), ["5.6S·XH", "5.6S·XH"])
        XCTAssertEqual(cards.map(\.contextPercent), [42, 42])
        XCTAssertEqual(cards.map(\.remoteText), [nil, "REMOTE"])
    }

    func testRemoteTaskNameFallsBackWithoutChangingTheCardSchema() {
        let projectFallback = CurrentSessionSnapshot(
            sessionID: "remote-project-fallback",
            threadID: "remote-project-thread",
            title: "  ",
            usedTokens: 0,
            contextWindow: 0,
            model: nil,
            effort: nil,
            observedAt: .now,
            projectName: "climate-agent",
            hostName: "TestHost",
            isRemote: true,
            executionState: .unknown
        )
        let genericFallback = CurrentSessionSnapshot(
            sessionID: "remote-generic-fallback",
            threadID: "remote-generic-thread",
            usedTokens: 0,
            contextWindow: 0,
            model: nil,
            effort: nil,
            observedAt: .now,
            hostName: "TestHost",
            isRemote: true,
            executionState: .unknown
        )

        let cards = TouchBarStatusViewModel(
            status: .init(
                usage: nil,
                session: projectFallback,
                sessions: [projectFallback, genericFallback]
            )
        ).sessions

        XCTAssertEqual(cards.map(\.taskText), ["climate-agent", "Task"])
        XCTAssertEqual(cards.map(\.stateText), ["—", "—"])
        XCTAssertEqual(cards.map(\.remoteText), ["REMOTE", "REMOTE"])
        XCTAssertTrue(cards.allSatisfy { $0.elapsedText == nil })
        XCTAssertTrue(cards.allSatisfy { $0.modelEffortText == nil })
        XCTAssertTrue(cards.allSatisfy { $0.contextPercent == nil })
    }

    func testRemoteTagIsAdditiveAndMissingDetailsCollapseAsOneRow() throws {
        let remote = CurrentSessionSnapshot(
            sessionID: "remote-session",
            threadID: "remote-thread",
            title: "分析网络问题",
            usedTokens: 0,
            contextWindow: 0,
            model: nil,
            effort: nil,
            observedAt: .now,
            projectName: "network-agent",
            hostName: "TestHost",
            isRemote: true,
            executionState: .unknown
        )
        let presenter = TouchBarPresenter(bridge: UnavailableBridge(), logger: { _ in })
        presenter.showStatus(.init(usage: nil, session: remote, sessions: [remote]))
        let item = try XCTUnwrap(
            presenter.touchBar(
                NSTouchBar(),
                makeItemForIdentifier: TouchBarLayout.sessionIdentifier
            ) as? NSCustomTouchBarItem
        )
        let scrubber = try XCTUnwrap(item.view as? NSScrubber)
        let dataSource = try XCTUnwrap(scrubber.dataSource)
        let itemView = dataSource.scrubber(scrubber, viewForItemAt: 0)
        itemView.frame = NSRect(x: 0, y: 0, width: 200, height: 30)
        itemView.layoutSubtreeIfNeeded()

        let allViews = [itemView] + descendants(of: itemView)
        let taskName = try XCTUnwrap(
            allViews.first { $0.identifier?.rawValue == "codex.task-name" } as? NSTextField
        )
        let remoteTag = try XCTUnwrap(
            allViews.first { $0.identifier?.rawValue == "codex.remote-tag" } as? NSTextField
        )
        let details = try XCTUnwrap(
            allViews.first { $0.identifier?.rawValue == "codex.task-details" }
        )

        XCTAssertEqual(taskName.stringValue, "分析网络问题")
        XCTAssertEqual(remoteTag.stringValue, "REMOTE")
        XCTAssertFalse(remoteTag.isHidden)
        XCTAssertTrue(details.isHidden)
        XCTAssertFalse(
            allViews.compactMap { ($0 as? NSTextField)?.stringValue }.contains("network-agent")
        )
    }

    func testLocalCardUsesTaskTitleInsteadOfOpaqueFolderAndShowsContextPercentage() {
        let local = CurrentSessionSnapshot(
            sessionID: "local-session",
            threadID: "local-thread",
            title: "查找 Chrome 控制 Touch Bar 方案",
            usedTokens: 196_000,
            contextWindow: 258_000,
            model: "gpt-5.6-sol",
            effort: "xhigh",
            observedAt: Date(timeIntervalSince1970: 200),
            activeSince: Date(timeIntervalSince1970: 75),
            isCompactingContext: true,
            projectName: "wh",
            executionState: .working
        )

        let model = TouchBarStatusViewModel(
            status: .init(usage: nil, session: local, sessions: [local]),
            now: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(model.sessions.first?.taskText, "查找 Chrome 控制 Touch Bar 方案")
        XCTAssertEqual(model.sessions.first?.elapsedText, "2m5s")
        XCTAssertEqual(model.sessions.first?.modelEffortText, "5.6S·XH")
        XCTAssertEqual(model.sessions.first?.contextPercent, 76)
        XCTAssertEqual(model.sessions.first?.contextProgress, 0.76)
        XCTAssertEqual(model.sessions.first?.isCompactingContext, true)
        XCTAssertEqual(model.sessions.first?.stateText, "COMPACT")
    }

    func testCompactionUsesOrangePulsingSquareStatusWithoutLegacyIcon() throws {
        let compacting = CurrentSessionSnapshot(
            sessionID: "remote-session",
            threadID: "remote-thread",
            title: "Remote compacting task",
            usedTokens: 0,
            contextWindow: 0,
            model: nil,
            effort: nil,
            observedAt: .now,
            isCompactingContext: true,
            hostName: "TestHost",
            isRemote: true,
            openURL: URL(string: "https://agent.example/remote-thread"),
            executionState: .working
        )
        let presenter = TouchBarPresenter(bridge: UnavailableBridge(), logger: { _ in })
        presenter.showStatus(.init(usage: nil, session: compacting, sessions: [compacting]))
        let item = try XCTUnwrap(
            presenter.touchBar(
                NSTouchBar(),
                makeItemForIdentifier: TouchBarLayout.sessionIdentifier
            ) as? NSCustomTouchBarItem
        )
        let scrubber = try XCTUnwrap(item.view as? NSScrubber)
        let dataSource = try XCTUnwrap(scrubber.dataSource)
        let itemView = dataSource.scrubber(scrubber, viewForItemAt: 0)
        itemView.layoutSubtreeIfNeeded()
        let indicator = try XCTUnwrap(
            descendants(of: itemView).first {
                $0.identifier?.rawValue == "codex.status-indicator"
            }
        )
        let indicatorLayer = try XCTUnwrap(indicator.layer?.sublayers?.first)
        let actualColor = try XCTUnwrap(
            NSColor(cgColor: try XCTUnwrap(indicatorLayer.backgroundColor))?
                .usingColorSpace(.deviceRGB)
        )
        let expectedColor = try XCTUnwrap(NSColor.systemOrange.usingColorSpace(.deviceRGB))
        let card = try XCTUnwrap(
            descendants(of: itemView).first { $0.accessibilityRole() == .button }
        )
        let labels = descendants(of: itemView).compactMap { $0 as? NSTextField }

        XCTAssertFalse(indicator.isHidden)
        XCTAssertFalse(indicatorLayer.isHidden)
        XCTAssertEqual(indicatorLayer.cornerRadius, 1)
        XCTAssertEqual(indicatorLayer.anchorPoint, CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(actualColor.redComponent, expectedColor.redComponent, accuracy: 0.01)
        XCTAssertEqual(actualColor.greenComponent, expectedColor.greenComponent, accuracy: 0.01)
        XCTAssertEqual(actualColor.blueComponent, expectedColor.blueComponent, accuracy: 0.01)
        XCTAssertTrue(labels.contains { $0.stringValue == "COMPACT" })
        XCTAssertTrue(
            descendants(of: itemView)
                .compactMap { $0 as? NSImageView }
                .allSatisfy(\.isHidden)
        )
        XCTAssertTrue(card.accessibilityLabel()?.contains("compacting context") == true)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            XCTAssertNotNil(indicatorLayer.animation(forKey: "codex-compacting"))
        }
    }

    func testIdleUsesAVisibleStaticGreyCirclePlaceholder() throws {
        let idle = CurrentSessionSnapshot(
            sessionID: "idle-session",
            threadID: "idle-thread",
            title: "Idle task",
            usedTokens: 10_000,
            contextWindow: 100_000,
            model: "gpt-5.6-sol",
            effort: "medium",
            observedAt: .now,
            executionState: .idle
        )
        let presenter = TouchBarPresenter(bridge: UnavailableBridge(), logger: { _ in })
        presenter.showStatus(.init(usage: nil, session: idle, sessions: [idle]))
        let item = try XCTUnwrap(
            presenter.touchBar(
                NSTouchBar(),
                makeItemForIdentifier: TouchBarLayout.sessionIdentifier
            ) as? NSCustomTouchBarItem
        )
        let scrubber = try XCTUnwrap(item.view as? NSScrubber)
        let dataSource = try XCTUnwrap(scrubber.dataSource)
        let itemView = dataSource.scrubber(scrubber, viewForItemAt: 0)
        itemView.layoutSubtreeIfNeeded()
        let indicator = try XCTUnwrap(
            descendants(of: itemView).first {
                $0.identifier?.rawValue == "codex.status-indicator"
            }
        )
        let indicatorLayer = try XCTUnwrap(indicator.layer?.sublayers?.first)
        let color = try XCTUnwrap(
            NSColor(cgColor: try XCTUnwrap(indicatorLayer.backgroundColor))?
                .usingColorSpace(.deviceRGB)
        )

        XCTAssertFalse(indicator.isHidden)
        XCTAssertFalse(indicatorLayer.isHidden)
        XCTAssertEqual(indicatorLayer.cornerRadius, 3.5)
        XCTAssertEqual(indicatorLayer.bounds.size, CGSize(width: 7, height: 7))
        XCTAssertEqual(color.redComponent, 0.58, accuracy: 0.01)
        XCTAssertEqual(color.greenComponent, 0.58, accuracy: 0.01)
        XCTAssertEqual(color.blueComponent, 0.58, accuracy: 0.01)
        XCTAssertNil(indicatorLayer.animationKeys())
    }

    func testRemoteSyncUsesBlueAnimatedStatusAndKeepsCachedContext() throws {
        let syncing = CurrentSessionSnapshot(
            sessionID: "sync-session",
            threadID: "sync-thread",
            title: "Remote analysis",
            usedTokens: 60_000,
            contextWindow: 100_000,
            model: "gpt-5.6-sol",
            effort: "high",
            observedAt: .now,
            projectName: "remote-analysis",
            hostName: "TestHost",
            isRemote: true,
            executionState: .syncing
        )
        let presenter = TouchBarPresenter(bridge: UnavailableBridge(), logger: { _ in })
        presenter.showStatus(.init(usage: nil, session: syncing, sessions: [syncing]))
        let item = try XCTUnwrap(
            presenter.touchBar(
                NSTouchBar(),
                makeItemForIdentifier: TouchBarLayout.sessionIdentifier
            ) as? NSCustomTouchBarItem
        )
        let scrubber = try XCTUnwrap(item.view as? NSScrubber)
        let dataSource = try XCTUnwrap(scrubber.dataSource)
        let itemView = dataSource.scrubber(scrubber, viewForItemAt: 0)
        itemView.layoutSubtreeIfNeeded()
        let labels = descendants(of: itemView).compactMap { $0 as? NSTextField }
        let indicator = try XCTUnwrap(
            descendants(of: itemView).first {
                $0.identifier?.rawValue == "codex.status-indicator"
            }
        )
        let indicatorLayer = try XCTUnwrap(indicator.layer?.sublayers?.first)
        let actualColor = try XCTUnwrap(
            NSColor(cgColor: try XCTUnwrap(indicatorLayer.backgroundColor))?
                .usingColorSpace(.deviceRGB)
        )
        let expectedColor = try XCTUnwrap(NSColor.systemBlue.usingColorSpace(.deviceRGB))

        XCTAssertTrue(labels.contains { $0.stringValue == "SYNC" })
        XCTAssertTrue(labels.contains { $0.stringValue == "60%" })
        XCTAssertEqual(actualColor.redComponent, expectedColor.redComponent, accuracy: 0.01)
        XCTAssertEqual(actualColor.greenComponent, expectedColor.greenComponent, accuracy: 0.01)
        XCTAssertEqual(actualColor.blueComponent, expectedColor.blueComponent, accuracy: 0.01)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            XCTAssertNotNil(indicatorLayer.animation(forKey: "codex-syncing"))
        }
    }

    func testFastModePlacesACompactLightningIconImmediatelyBeforeModel() throws {
        let fast = CurrentSessionSnapshot(
            sessionID: "fast-session",
            threadID: "fast-thread",
            title: "Fast task",
            usedTokens: 10_000,
            contextWindow: 100_000,
            model: "gpt-5.8-sol",
            effort: "xhigh",
            serviceTier: "priority",
            observedAt: .now,
            openURL: URL(string: "https://agent.example/fast-thread"),
            executionState: .working
        )
        let presenter = TouchBarPresenter(bridge: UnavailableBridge(), logger: { _ in })
        presenter.showStatus(.init(usage: nil, session: fast, sessions: [fast]))
        let item = try XCTUnwrap(
            presenter.touchBar(
                NSTouchBar(),
                makeItemForIdentifier: TouchBarLayout.sessionIdentifier
            ) as? NSCustomTouchBarItem
        )
        let scrubber = try XCTUnwrap(item.view as? NSScrubber)
        let dataSource = try XCTUnwrap(scrubber.dataSource)
        let itemView = dataSource.scrubber(scrubber, viewForItemAt: 0)
        itemView.layoutSubtreeIfNeeded()
        let fastIcon = try XCTUnwrap(
            descendants(of: itemView).first {
                $0.identifier?.rawValue == "codex.fast-mode-indicator"
            } as? NSImageView
        )
        let labels = descendants(of: itemView).compactMap { $0 as? NSTextField }
        let card = try XCTUnwrap(
            descendants(of: itemView).first { $0.accessibilityRole() == .button }
        )

        XCTAssertFalse(fastIcon.isHidden)
        XCTAssertNotNil(fastIcon.image)
        XCTAssertTrue(labels.contains { $0.stringValue == "5.8S·XH" })
        XCTAssertTrue(card.accessibilityLabel()?.contains("fast mode") == true)
    }

    func testEachSessionCardKeepsItsOwnModelValueWithoutStandaloneItem() {
        let presenter = TouchBarPresenter(bridge: UnavailableBridge(), logger: { _ in })
        let first = CurrentSessionSnapshot(
                sessionID: "first",
                threadID: "10000000-0000-4000-8000-000000000002",
                usedTokens: 1,
                contextWindow: 100,
                model: "gpt-5.6-sol",
                effort: "xhigh",
                observedAt: .now
            )
        let second = CurrentSessionSnapshot(
                sessionID: "second",
                threadID: "10000000-0000-4000-8000-000000000003",
                usedTokens: 2,
                contextWindow: 100,
                model: "gpt-5.6-terra",
                effort: "low",
                observedAt: .now
            )
        let status = TouchBarStatusSnapshot(
            usage: nil,
            session: first,
            sessions: [first, second]
        )
        presenter.showStatus(status)

        XCTAssertEqual(
            TouchBarStatusViewModel(status: status).sessions.map(\.modelEffortText),
            ["5.6S·XH", "5.6T·L"]
        )
        XCTAssertFalse(
            presenter.displayedItemIdentifiers.contains {
                $0.rawValue.contains("model")
            }
        )
    }

    func testMissingSessionUsesPlaceholders() {
        let model = TouchBarStatusViewModel(status: TouchBarStatusSnapshot(usage: nil, session: nil))
        XCTAssertNil(model.sessions.first?.contextPercent)
        XCTAssertNil(model.sessions.first?.modelEffortText)
    }

    func testUnavailableQuotaWindowIsDistinctFromRefreshFailure() throws {
        let usage = try UsageSnapshot.from(
            primary: .init(usedPercent: 4, windowMinutes: 10_080, resetsAt: 1_800_086_400),
            secondary: nil,
            observedAt: Date(timeIntervalSince1970: 1_799_999_000)
        )
        let model = TouchBarStatusViewModel(
            status: .init(usage: usage, session: nil),
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(model.primary.resetText, "not included")
        XCTAssertEqual(model.primary.percentText, "N/A")
        XCTAssertEqual(model.primary.progress, 0)
        XCTAssertEqual(model.primary.color, .neutral)
        XCTAssertEqual(model.secondary.percentText, "96%")
    }

    func testRefreshFailureKeepsQuotaFailurePlaceholder() {
        let model = TouchBarStatusViewModel(status: .init(usage: nil, session: nil))

        XCTAssertEqual(model.primary.resetText, "reset --")
        XCTAssertEqual(model.primary.percentText, "--")
        XCTAssertEqual(model.primary.color, .red)
        XCTAssertEqual(model.secondary.percentText, "--")
    }

    func testStaleQuotaUsesASeparateYellowAttentionDot() throws {
        let usage = UsageSnapshot(
            primary: RateWindow(
                label: "5H",
                usedPercent: 100,
                windowMinutes: 300,
                resetsAt: 0
            ),
            secondary: RateWindow(
                label: "7D",
                usedPercent: 13,
                windowMinutes: 10_080,
                resetsAt: 1_800_000_000
            ),
            observedAt: .now,
            isStale: true,
            primaryAvailable: false,
            secondaryAvailable: true
        )
        let status = TouchBarStatusSnapshot(usage: usage, session: nil)
        let model = TouchBarStatusViewModel(status: status)
        XCTAssertEqual(model.secondary.percentText, "87%")
        XCTAssertEqual(model.secondary.color, TouchBarItemColor.green)
        XCTAssertTrue(model.secondary.isStale)

        let presenter = TouchBarPresenter(bridge: UnavailableBridge(), logger: { _ in })
        presenter.showStatus(status)
        let item = try XCTUnwrap(
            presenter.touchBar(
                NSTouchBar(),
                makeItemForIdentifier: TouchBarLayout.secondaryIdentifier
            ) as? NSCustomTouchBarItem
        )
        let quotaView = try XCTUnwrap(item.view)
        let labels = ([quotaView] + descendants(of: quotaView))
            .compactMap { $0 as? NSTextField }
        let staleDot = try XCTUnwrap(labels.first { $0.stringValue == "•" })
        XCTAssertFalse(staleDot.isHidden)
        XCTAssertEqual(staleDot.textColor, NSColor.systemYellow)
    }

    func testPresentationUnavailabilityIsLoggedOnlyOnce() {
        let bridge = UnavailableBridge()
        var messages: [String] = []
        let presenter = TouchBarPresenter(bridge: bridge, logger: { messages.append($0) })
        presenter.showUnavailable()
        presenter.showUnavailable()
        XCTAssertEqual(messages.count, 1)
    }

    func testPresentationFailureCanBeLoggedAgainAfterRecovery() {
        let bridge = UnavailableBridge()
        var messages: [String] = []
        let presenter = TouchBarPresenter(bridge: bridge, logger: { messages.append($0) })
        presenter.showUnavailable()
        bridge.presentResult = true
        presenter.showUnavailable()
        bridge.presentResult = false
        presenter.showUnavailable()

        XCTAssertEqual(messages.count, 2)
    }

    func testBothQuotaViewsInvokeTheSameManualRefreshCallback() {
        let presenter = TouchBarPresenter(bridge: UnavailableBridge(), logger: { _ in })
        var refreshCount = 0
        presenter.onManualRefresh = { refreshCount += 1 }

        for rawIdentifier in ["com.codex.touchbar.primary", "com.codex.touchbar.secondary"] {
            let item = presenter.touchBar(
                NSTouchBar(),
                makeItemForIdentifier: .init(rawIdentifier)
            )
            XCTAssertEqual(item?.view?.gestureRecognizers.count, 1)
            guard let recognizer = item?.view?.gestureRecognizers.first,
                  let action = recognizer.action else {
                XCTFail("Missing tap recognizer for \(rawIdentifier)")
                continue
            }
            NSApplication.shared.sendAction(
                action,
                to: recognizer.target,
                from: recognizer
            )
        }

        XCTAssertEqual(refreshCount, 2)
    }

    func testTappingEachSessionCardOpensItsExactTaskWithoutShowingSettings() throws {
        let opener = RecordingTaskOpener()
        let presenter = TouchBarPresenter(
            bridge: UnavailableBridge(),
            taskOpener: opener,
            logger: { _ in }
        )
        let local = CurrentSessionSnapshot(
            sessionID: "local-session",
            threadID: "20000000-0000-4000-8000-000000000001",
            title: "Local task",
            usedTokens: 1_000,
            contextWindow: 100_000,
            model: "gpt-5.6-sol",
            effort: "medium",
            observedAt: .now
        )
        let remote = CurrentSessionSnapshot(
            sessionID: "remote-session",
            threadID: "20000000-0000-4000-8000-000000000002",
            title: "Remote task",
            usedTokens: 0,
            contextWindow: 0,
            model: nil,
            effort: nil,
            observedAt: .now,
            hostName: "TestHost",
            isRemote: true
        )
        presenter.showStatus(.init(usage: nil, session: local, sessions: [local, remote]))
        let item = try XCTUnwrap(
            presenter.touchBar(NSTouchBar(), makeItemForIdentifier: TouchBarLayout.sessionIdentifier)
                as? NSCustomTouchBarItem
        )
        let scrubber = try XCTUnwrap(item.view as? NSScrubber)
        let delegate = try XCTUnwrap(scrubber.delegate)
        delegate.scrubber?(scrubber, didSelectItemAt: 0)
        delegate.scrubber?(scrubber, didSelectItemAt: 1)

        XCTAssertEqual(
            opener.urls.map(\.absoluteString),
            [
                "codex://threads/20000000-0000-4000-8000-000000000001",
                "codex://threads/20000000-0000-4000-8000-000000000002",
            ]
        )
        XCTAssertEqual(
            presenter.displayedItemIdentifiers,
            TouchBarLayout.metricItemIdentifiers(primaryAvailable: true)
        )
    }

    func testFailedTaskNavigationLeavesTheFocusedCardUnchangedAndLogs() throws {
        let opener = RecordingTaskOpener(result: false)
        var messages: [String] = []
        let presenter = TouchBarPresenter(
            bridge: UnavailableBridge(),
            taskOpener: opener,
            logger: { messages.append($0) }
        )
        presenter.showStatus(status(sessionUsed: 1_000, contextWindow: 100_000))
        let item = try XCTUnwrap(
            presenter.touchBar(NSTouchBar(), makeItemForIdentifier: TouchBarLayout.sessionIdentifier)
                as? NSCustomTouchBarItem
        )
        let scrubber = try XCTUnwrap(item.view as? NSScrubber)
        scrubber.delegate?.scrubber?(scrubber, didSelectItemAt: 0)

        XCTAssertEqual(opener.urls.map(\.absoluteString), ["codex://threads/thread-id"])
        XCTAssertEqual(messages.last, "Could not open task thread-i.")
    }

    func testQuotaViewsExposeDistinctAccessibleRefreshButtons() {
        let presenter = TouchBarPresenter(bridge: UnavailableBridge(), logger: { _ in })
        var refreshCount = 0
        presenter.onManualRefresh = { refreshCount += 1 }
        let expectedLabels = [
            "com.codex.touchbar.primary": "Refresh 5H quota",
            "com.codex.touchbar.secondary": "Refresh 7D quota",
        ]

        for (rawIdentifier, expectedLabel) in expectedLabels {
            let item = presenter.touchBar(
                NSTouchBar(),
                makeItemForIdentifier: .init(rawIdentifier)
            )
            guard let view = item?.view else {
                XCTFail("Missing quota view for \(rawIdentifier)")
                continue
            }

            XCTAssertEqual(view.accessibilityLabel(), expectedLabel)
            XCTAssertEqual(view.accessibilityRole(), .button)
            XCTAssertTrue(view.accessibilityPerformPress())
        }

        XCTAssertEqual(refreshCount, 2)
    }

    private func snapshot(
        primaryRemaining: Int,
        secondaryRemaining: Int,
        isStale: Bool = false
    ) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                label: "5H",
                usedPercent: Double(100 - primaryRemaining),
                windowMinutes: 300,
                resetsAt: DateComponents(
                    calendar: Calendar(identifier: .gregorian),
                    timeZone: TimeZone(secondsFromGMT: 0),
                    year: 2026,
                    month: 7,
                    day: 12,
                    hour: 3,
                    minute: 4
                ).date!.timeIntervalSince1970
            ),
            secondary: RateWindow(
                label: "7D",
                usedPercent: Double(100 - secondaryRemaining),
                windowMinutes: 10_080,
                resetsAt: 0
            ),
            observedAt: .now,
            isStale: isStale
        )
    }

    private func status(sessionUsed: Int, contextWindow: Int) -> TouchBarStatusSnapshot {
        TouchBarStatusSnapshot(
            usage: snapshot(primaryRemaining: 72, secondaryRemaining: 41),
            session: CurrentSessionSnapshot(
                sessionID: "session",
                threadID: "thread-id",
                usedTokens: sessionUsed,
                contextWindow: contextWindow,
                model: "gpt-5.6-sol",
                effort: "medium",
                observedAt: .now,
                openURL: URL(string: "codex://threads/thread-id")
            )
        )
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }

}

@MainActor
private final class RestoreTarget: NSObject {
    @objc func restore() {}
}

@MainActor
private final class RecordingTaskOpener: TaskOpening {
    private(set) var urls: [URL] = []
    private let result: Bool

    init(result: Bool = true) {
        self.result = result
    }

    func open(_ url: URL) -> Bool {
        urls.append(url)
        return result
    }
}

@MainActor
private final class UnavailableBridge: TouchBarBridging {
    var onRestore: (@MainActor @Sendable () -> Void)?
    var presentResult = false
    func preparePersistentAccess(_ touchBar: NSTouchBar) -> Bool { false }
    func activatePersistentAccess(_ touchBar: NSTouchBar) -> Bool { false }
    func present(_ touchBar: NSTouchBar) -> Bool { presentResult }
    func dismissOwnTouchBar() {}

    func emitRestore() { onRestore?() }
}

@MainActor
private final class FakeSystemModalRuntime: SystemModalRuntime {
    var addTrayResult = true
    var presentResult = true
    var dismissResult = true
    private(set) var addTrayCount = 0
    private(set) var trayPresence: [Bool] = []
    private(set) var closeBoxVisibility: [Bool] = []
    private(set) var presentedBars: [NSTouchBar] = []
    private(set) var dismissedBars: [NSTouchBar] = []

    func addSystemTrayItem(_ item: NSTouchBarItem) -> Bool {
        addTrayCount += 1
        return addTrayResult
    }

    func setTrayPresence(_ visible: Bool, identifier: NSTouchBarItem.Identifier) {
        trayPresence.append(visible)
    }

    func setCloseBoxVisible(_ visible: Bool) {
        closeBoxVisibility.append(visible)
    }

    func present(_ touchBar: NSTouchBar, trayIdentifier: NSTouchBarItem.Identifier) -> Bool {
        presentedBars.append(touchBar)
        return presentResult
    }

    func dismiss(_ touchBar: NSTouchBar) -> Bool {
        dismissedBars.append(touchBar)
        return dismissResult
    }
}
