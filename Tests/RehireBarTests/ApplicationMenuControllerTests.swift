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
            onQuit: { quitCount += 1 }
        )

        let menu = ApplicationMenuController.makeMenu(target: controller)

        XCTAssertEqual(
            menu.items.filter { !$0.isSeparatorItem }.map(\.title),
            ["Show Touch Bar", "Task order", "Quit RehireBar"]
        )
        XCTAssertEqual(menu.items.last?.keyEquivalent, "q")
        XCTAssertTrue(menu.items.allSatisfy { $0.isSeparatorItem || $0.submenu != nil || $0.target === controller })
        for item in menu.items where item.action != nil && item.submenu == nil {
            NSApplication.shared.sendAction(item.action!, to: item.target, from: item)
        }
        XCTAssertEqual(showCount, 1)
        XCTAssertEqual(quitCount, 1)
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
