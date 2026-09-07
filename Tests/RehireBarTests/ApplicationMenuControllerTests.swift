import AppKit
import XCTest
@testable import RehireBar

@MainActor
final class ApplicationMenuControllerTests: XCTestCase {
    func testAgentSettingsRemainScopedAndMissingSourceLosesEvidence() throws {
        let suite = "AgentMenuTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AgentMenuSettings(defaults: defaults)
        var shows = 0
        var changes = 0
        let controller = ApplicationMenuController(
            onShow: { shows += 1 }, agentSettings: settings,
            onAgentSettingsChange: { changes += 1 }
        )
        controller.receiveAgentEntries([
            .init(providerID: "codex", observedAt: .now),
            .init(providerID: "other.agent", observedAt: .now)
        ])
        let menu = ApplicationMenuController.makeMenu(target: controller)
        let agents = try XCTUnwrap(menu.items.first { $0.title == "Agents" }?.submenu)
        let other = try XCTUnwrap(agents.items.first { $0.title == "other.agent" }?.submenu)
        XCTAssertEqual(other.items[0].title, AgentMenuEntry.Status.current.title)
        XCTAssertEqual(other.items[0].image?.name(), NSImage.statusAvailableName)
        let toggle = other.items[2]
        NSApplication.shared.sendAction(toggle.action!, to: toggle.target, from: toggle)
        XCTAssertFalse(settings.value(.showTasks, providerID: "other.agent"))
        XCTAssertTrue(settings.value(.showTasks, providerID: "codex"))
        XCTAssertFalse(AgentMenuSettings(defaults: defaults).value(.showTasks, providerID: "other.agent"))
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(shows, 0)
        controller.receiveAgentEntries([])
        controller.menuWillOpen(other)
        XCTAssertEqual(other.items[0].title, AgentMenuEntry.Status.unavailable.title)
        XCTAssertEqual(other.items[0].image?.name(), NSImage.statusUnavailableName)
        XCTAssertEqual(other.items[2].state, .off)
        controller.receiveAgentEntries([
            .init(providerID: "other.agent", observedAt: Date.now.addingTimeInterval(-31))
        ])
        controller.menuWillOpen(other)
        XCTAssertEqual(other.items[0].image?.name(), NSImage.statusPartiallyAvailableName)
        XCTAssertNil(other.items[0].action)
        XCTAssertFalse(other.items[0].isEnabled)
    }

    func testConnectionEvidenceExpiresAndDoesNotUseCatalogReadTime() {
        let now = Date.now
        XCTAssertEqual(AgentMenuEntry(providerID: "agent", observedAt: now.addingTimeInterval(-31))
            .status(at: now), .stale)
        XCTAssertEqual(AgentMenuEntry(providerID: "agent", observedAt: now.addingTimeInterval(6))
            .status(at: now), .invalidTime)
        let session = CurrentSessionSnapshot(
            sessionID: "catalog", usedTokens: 0, contextWindow: 0,
            model: nil, effort: nil, observedAt: now
        )
        XCTAssertNil(AgentMenuEntry.codex(sessions: [session]).observedAt)
    }

    func testMenuOffersExplicitShowAndQuitCommands() {
        var showCount = 0
        var quitCount = 0
        let controller = ApplicationMenuController(
            onShow: { showCount += 1 },
            onQuit: { quitCount += 1 },
            version: .init(info: ["CFBundleName": "RehireBar", "CFBundleShortVersionString": "0.5.3", "CFBundleVersion": "15"])
        )

        let menu = ApplicationMenuController.makeMenu(target: controller)

        XCTAssertEqual(
            menu.items.filter { !$0.isSeparatorItem }.map(\.title),
            ["RehireBar 0.5.3 (15)", "Check for Updates…", "Show Touch Bar", "Agents", "Task order", "Quit RehireBar"]
        )
        XCTAssertEqual(menu.items.last?.keyEquivalent, "q")
        XCTAssertTrue(menu.items.allSatisfy { $0.isSeparatorItem || $0.submenu != nil || $0.target === controller })
        for item in menu.items where item.action != nil && item.submenu == nil {
            NSApplication.shared.sendAction(item.action!, to: item.target, from: item)
        }
        XCTAssertEqual(showCount, 1)
        XCTAssertEqual(quitCount, 1)
    }

    func testUpdateMenuTracksAvailabilityAndDoesNotDispatchWhileBusy() throws {
        let updater = MenuUpdaterSpy()
        let controller = ApplicationMenuController(onShow: {}, updater: updater)
        let menu = ApplicationMenuController.makeMenu(target: controller)
        let check = try XCTUnwrap(menu.items.first { $0.title == "Check for Updates…" })
        XCTAssertFalse(controller.validateMenuItem(check))
        NSApplication.shared.sendAction(check.action!, to: check.target, from: check)
        XCTAssertEqual(updater.checkCount, 0)

        updater.canCheckForUpdates = true
        XCTAssertTrue(controller.validateMenuItem(check))
        NSApplication.shared.sendAction(check.action!, to: check.target, from: check)
        XCTAssertEqual(updater.checkCount, 1)
        XCTAssertFalse(controller.validateMenuItem(check))
        XCTAssertFalse(controller.validateMenuItem(menu.items[0]))
    }

    func testTaskOrderMenuUpdatesPreferenceAndSelection() throws {
        var mode = SessionSortMode.runningFirst
        var changes = 0
        let controller = ApplicationMenuController(
            onShow: {}, sortMode: { mode },
            onSortModeChange: { mode = $0; changes += 1 }
        )
        let menu = ApplicationMenuController.makeMenu(target: controller)
        let submenu = try XCTUnwrap(menu.items.first { $0.title == "Task order" }?.submenu)
        XCTAssertEqual(submenu.items.map(\.state), [.on, .off])
        let waiting = try XCTUnwrap(submenu.items.last)

        NSApplication.shared.sendAction(waiting.action!, to: waiting.target, from: waiting)

        XCTAssertEqual(mode, .waitingFirst)
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(submenu.items.map(\.state), [.off, .on])
        mode = .runningFirst
        controller.menuWillOpen(submenu)
        XCTAssertEqual(submenu.items.map(\.state), [.on, .off])
    }
}

@MainActor
private final class MenuUpdaterSpy: ApplicationUpdating {
    var canCheckForUpdates = false
    var checkCount = 0
    func start() {}
    func checkForUpdates() { checkCount += 1; canCheckForUpdates = false }
}
