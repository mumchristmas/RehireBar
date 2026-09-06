import AppKit
import XCTest
@testable import RehireBar

@MainActor
final class ApplicationMenuControllerTests: XCTestCase {
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
            ["RehireBar 0.5.3 (15)", "Check for Updates…", "Show Touch Bar", "Task order", "Quit RehireBar"]
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
